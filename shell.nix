with import <nixpkgs> {};
mkShell {
  buildInputs = [ stdenv
                  gcc
                  gdb
                  pkg-config
                  nim-2_0
                  nimble
                  xorg.libX11
                  xorg.libXrandr
                  xorg.libXext
                  libGL
                  libGLU
                  freeglut
                  SDL2
                ];
  LD_LIBRARY_PATH = lib.makeLibraryPath [
    "/run/opengl-driver"
    xorg.libX11 xorg.libXrandr xorg.libXext
    libGL libGLU freeglut 
    SDL2
  ];
}
