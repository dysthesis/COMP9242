{
  self',
  self,
  pkgs,
  ...
}: rec {
  sos = import ./sos.nix {inherit self self' pkgs;};
  sel4Deps = import ./sel4Deps.nix {inherit pkgs;};
  default = sos;
}
