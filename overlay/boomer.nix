{ stdenv, lib, fetchFromGitHub, nim-2_0, libX11, libXrandr, libGL }:

let
  x11-nim = fetchFromGitHub {
    owner = "nim-lang";
    repo = "x11";
    rev = "29aca5e519ebf5d833f63a6a2769e62ec7bfb83a";
    sha256 = "sha256-jBNsv8meDvF2ySKewbA+rF2XS+gqydZUl1xhEevD15o=";
  };
  opengl-nim = fetchFromGitHub {
    owner = "nim-lang";
    repo = "opengl";
    rev = "8e2e098f82dc5eefd874488c37b5830233cd18f4";
    sha256 = "sha256-v3bMDobYQZqX0anBFIUfZx5q5/vxTHO6PDtKQlf5mgU=";
  };
  stb_image-nim = fetchFromGitHub {
    owner = "define-private-public";
    repo = "stb_image-Nim";
    rev = "ba5f45286bfa9bed93d8d6b941949cd6218ec888";
    sha256 = "sha256-3xeqUumBOxuXsikgcETp5oe1GAw8jyhP3ZSpm0+Imo0=";
  };
in stdenv.mkDerivation rec {
  pname = "boomer";
  version = "unstable-2026-05-28";
  # src = fetchFromGitHub {
  #   owner = "tsoding";
  #   repo = "boomer";
  #   rev = "cdf951b50ecd9f9652d37f8e1288c2c7589464d8";
  #   sha256 = "1g0y93wqm5j41fp5938z831zcnx9958l1crqyc1w0ygg8hahfb5q";
  # };
  src = ../.;
  buildInputs = [ nim-2_0 libX11 libXrandr libGL ];
  buildPhase = ''
    HOME=$TMPDIR
    nim -p:${x11-nim}/ -p:${opengl-nim}/src -p:${stb_image-nim}/ c -d:release src/boomer.nim
  '';
  installPhase = "install -Dt $out/bin src/boomer";
  fixupPhase = ''
  patchelf --set-rpath ${
    lib.makeLibraryPath [
      stdenv.cc.cc
      libX11
      libXrandr
      libGL
    ]
  } $out/bin/boomer
'';
}
