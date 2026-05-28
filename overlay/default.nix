self: super:

{
  # nim_2_0 = super.callPackage ./nim_2_0.nix {};
  boomer = super.callPackage ./boomer.nix {};
}
