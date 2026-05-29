import os
import osproc
import options
import streams
import std/tempfiles

import x11/xlib, x11/x, x11/xutil
import stb_image/read as stbi

when defined(mitshm):
  import x11/xshm

  # Stolen from https://github.com/def-/nim-syscall
  when defined(amd64):
    type Number = enum
      SHMGET = 29
      SHMAT = 30
      SHMCTL = 31
      SHMDT = 67

    proc syscall*(n: Number, a1: any): clong {.inline.} =
      {.emit: """asm volatile(
        "syscall" : "=a"(`result`)
                  : "a"((long)`n`), "D"((long)`a1`)
                  : "memory", "r11", "rcx", "cc");""".}

    proc syscall*(n: Number, a1, a2, a3: any): clong {.inline.} =
      {.emit: """asm volatile(
        "syscall" : "=a"(`result`)
                  : "a"((long)`n`), "D"((long)`a1`), "S"((long)`a2`),
                     "d"((long)`a3`)
                  : "memory", "r11", "rcx", "cc");""".}
  else:
    {.error: "Supported only Linux x86_64. Feel free to submit a PR to https://github.com/tsoding/boomer to fix it.".}

  const
    IPC_PRIVATE = 0
    IPC_CREAT = 512
    IPC_RMID = 0

type 
  PixelFormat* = enum
    pfBGRA
    pfRGBA

  ImageBuffer* = object
    width*: int
    height*: int
    pixelFormat*: PixelFormat
    pixels*: seq[byte]

  CaptureBackend* = enum
    cbX11
    cbPortal

  PortalCommandKind = enum
    pckGrim
    pckGnomeScreenshot
    pckSpectacle

  PortalCommand = object
    kind: PortalCommandKind
    path: string

  Screenshot* = object
    backend*: CaptureBackend
    image*: ImageBuffer
    when defined(mitshm):
      shminfo*: PXShmSegmentInfo
    xImage*: PXImage
    portalCmd*: Option[PortalCommand]

proc dataPtr*(image: ImageBuffer): pointer =
  if image.pixels.len == 0:
    nil
  else:
    image.pixels[0].unsafeAddr

proc pixelSize*(format: PixelFormat): int =
  4 # We always request 4 channels

proc toBytes(strData: string): seq[byte] =
  result = newSeq[byte](strData.len)
  if strData.len > 0:
    copyMem(result[0].addr, strData[0].unsafeAddr, strData.len)

proc loadImageFromBytes(bytes: seq[byte]): ImageBuffer =
  var
    w, h, channels: int
    pixels = stbi.loadFromMemory(bytes, w, h, channels, stbi.RGBA)
  result = ImageBuffer(
    width: w,
    height: h,
    pixelFormat: pfRGBA,
    pixels: pixels
  )

proc execForOutput(cmd: string; args: seq[string]): tuple[code: int, output, stderr: string] =
  let process = startProcess(cmd, args = args, options = {poUsePath, poStdErrToStdOut})
  defer:
    process.close()

  let output = process.outputStream.readAll()
  let code = process.waitForExit()
  result = (code, output, "")

proc execAndWait(cmd: string; args: seq[string]): int =
  let process = startProcess(cmd, args = args, options = {poUsePath})
  defer: process.close()
  result = process.waitForExit()

proc findPortalCommand(): Option[PortalCommand] =
  let grim = findExe("grim")
  if grim.len > 0:
    return some(PortalCommand(kind: pckGrim, path: grim))

  let gnomeScreenshot = findExe("gnome-screenshot")
  if gnomeScreenshot.len > 0:
    return some(PortalCommand(kind: pckGnomeScreenshot, path: gnomeScreenshot))

  let spectacle = findExe("spectacle")
  if spectacle.len > 0:
    return some(PortalCommand(kind: pckSpectacle, path: spectacle))

  return none(PortalCommand)

proc captureWithPortal(cmd: PortalCommand, windowed: bool = false): ImageBuffer =
  case cmd.kind
  of pckGrim:
    let (code, output, _) = execForOutput(cmd.path, @["-"])
    if code != 0:
      raise newException(IOError, "grim failed to capture screenshot. Please ensure xdg-desktop-portal and a compatible compositor are running.")
    result = loadImageFromBytes(output.toBytes)

  of pckGnomeScreenshot:
    let (tempFile, tempPath) = createTempFile("boomer_wayland_", ".png")
    tempFile.close()
    defer:
      try: removeFile(tempPath)
      except CatchableError: discard

    let exitCode = execAndWait(cmd.path, @["--file", tempPath])
    if exitCode != 0 or not fileExists(tempPath):
      raise newException(IOError, "gnome-screenshot failed. The portal may have been denied.")
    result = loadImageFromBytes(readFile(tempPath).toBytes)

  of pckSpectacle:
    let (tempFile, tempPath) = createTempFile("boomer_wayland_", ".png")
    tempFile.close()
    defer:
      try: removeFile(tempPath)
      except CatchableError: discard

    var args = @["-b", "-n", "-o", tempPath]
    if windowed:
      args.add("-m")
    let exitCode = execAndWait(cmd.path, args)
    if exitCode != 0 or not fileExists(tempPath):
      raise newException(IOError, "spectacle failed to produce a screenshot.")
    result = loadImageFromBytes(readFile(tempPath).toBytes)

proc newPortalScreenshot*(windowed: bool): Screenshot =
  let cmd = findPortalCommand()
  if cmd.isNone:
    raise newException(IOError, "No Wayland-friendly screenshot tool found. Install grim (wlr), gnome-screenshot (GNOME) or spectacle (KDE).")

  let image = captureWithPortal(cmd.get(), windowed)
  result = Screenshot(
    backend: cbPortal,
    image: image,
    portalCmd: cmd
  )

proc validateXImage(ximage: PXImage) =
  if ximage == nil:
    raise newException(IOError, "XGetImage failed.")
  if ximage.bits_per_pixel != 32:
    raise newException(IOError, "Unsupported bits_per_pixel: " & $ximage.bits_per_pixel)

proc copyXImage(ximage: PXImage): ImageBuffer =
  validateXImage(ximage)
  let width = ximage.width.int
  let height = ximage.height.int
  let rowBytes = ximage.bytes_per_line.int
  let expectedRow = width * 4

  result = ImageBuffer(
    width: width,
    height: height,
    pixelFormat: pfBGRA,
    pixels: newSeq[byte](width * height * 4)
  )

  for y in 0 ..< height:
    let src = cast[pointer](cast[int](ximage.data) + y * rowBytes)
    let dst = result.pixels[(y * expectedRow)].addr
    copyMem(dst, src, min(rowBytes, expectedRow))

proc newX11Screenshot*(display: PDisplay, window: Window): Screenshot =
  var attributes: XWindowAttributes
  discard XGetWindowAttributes(display, window, addr attributes)

  when defined(mitshm):
    var shminfo = cast[PXShmSegmentInfo](allocShared(sizeof(PXShmSegmentInfo)))
    let screen = DefaultScreen(display)
    var ximage = XShmCreateImage(
      display,
      DefaultVisual(display, screen),
      DefaultDepthOfScreen(ScreenOfDisplay(display, screen)).cuint,
      ZPixmap,
      nil,
      shminfo,
      attributes.width.cuint,
      attributes.height.cuint)

    shminfo.shmid = syscall(
      SHMGET,
      IPC_PRIVATE,
      ximage.bytes_per_line * ximage.height,
      IPC_CREAT or 0o777).cint

    shminfo.shmaddr = cast[cstring](syscall(
      SHMAT,
      shminfo.shmid,
      0, 0))
    ximage.data = shminfo.shmaddr
    shminfo.readOnly = 0

    discard XShmAttach(display, shminfo)
    discard XShmGetImage(display, window, ximage, 0.cint, 0.cint, AllPlanes)

    result = Screenshot(
      backend: cbX11,
      image: copyXImage(ximage),
      shminfo: shminfo,
      xImage: ximage)
  else:
    let ximage = XGetImage(
      display, window,
      0, 0,
      attributes.width.cuint,
      attributes.height.cuint,
      AllPlanes,
      ZPixmap)

    result = Screenshot(
      backend: cbX11,
      image: copyXImage(ximage),
      xImage: ximage)

proc destroy*(screenshot: var Screenshot, display: PDisplay) =
  case screenshot.backend
  of cbX11:
    when defined(mitshm):
      discard XSync(display, 0)
      discard XShmDetach(display, screenshot.shminfo)
      discard XDestroyImage(screenshot.xImage)
      discard syscall(SHMDT, screenshot.shminfo.shmaddr)
      discard syscall(SHMCTL, screenshot.shminfo.shmid, IPC_RMID, 0)
      deallocShared(screenshot.shminfo)
    else:
      discard XDestroyImage(screenshot.xImage)
  of cbPortal:
    discard

proc refresh*(screenshot: var Screenshot, display: PDisplay, window: Window) =
  case screenshot.backend
  of cbPortal:
    if screenshot.portalCmd.isSome:
      screenshot.image = captureWithPortal(screenshot.portalCmd.get())
  of cbX11:
    var attributes: XWindowAttributes
    discard XGetWindowAttributes(display, window, addr attributes)

    when defined(mitshm):
      if XShmGetImage(display,
                      window, screenshot.xImage,
                      0.cint, 0.cint,
                      AllPlanes) == 0 or
         attributes.width != screenshot.xImage.width or
         attributes.height != screenshot.xImage.height:
        screenshot.destroy(display)
        screenshot = newX11Screenshot(display, window)
        return
    else:
      let refreshedImage = XGetSubImage(
        display, window,
        0, 0,
        screenshot.xImage.width.cuint,
        screenshot.xImage.height.cuint,
        AllPlanes,
        ZPixmap,
        screenshot.xImage,
        0, 0)
      if refreshedImage == nil or
         refreshedImage.width != attributes.width or
         refreshedImage.height != attributes.height:
        let newImage = XGetImage(
          display, window,
          0, 0,
          attributes.width.cuint,
          attributes.height.cuint,
          AllPlanes,
          ZPixmap)

        if newImage != nil:
          discard XDestroyImage(screenshot.xImage)
          screenshot.xImage = newImage
      else:
        screenshot.xImage = refreshedImage

    screenshot.image = copyXImage(screenshot.xImage)

proc saveToPPM*(image: ImageBuffer, filePath: string) =
  var f = open(filePath, fmWrite)
  defer: f.close
  writeLine(f, "P6")
  writeLine(f, image.width, " ", image.height)
  writeLine(f, 255)

  case image.pixelFormat
  of pfBGRA:
    for i in 0 ..< (image.width * image.height):
      f.write(image.pixels[i * 4 + 2])
      f.write(image.pixels[i * 4 + 1])
      f.write(image.pixels[i * 4 + 0])
  of pfRGBA:
    for i in 0 ..< (image.width * image.height):
      f.write(image.pixels[i * 4 + 0])
      f.write(image.pixels[i * 4 + 1])
      f.write(image.pixels[i * 4 + 2])
