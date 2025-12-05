{
  description = "COMP9242";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    pwndbg = {
      url = "github:pwndbg/pwndbg";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
  };

  outputs = inputs @ {
    self,
    flake-parts,
    systems,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = import systems;
      imports = [
        inputs.treefmt-nix.flakeModule
      ];
      perSystem = {
        self',
        pkgs,
        lib,
        system,
        ...
      }: {
        _module.args.pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = [
            (final: _prev: {
              unstable = inputs.nixpkgs-unstable.legacyPackages.${final.system};
            })
          ];
        };
        packages = import ./nix/pkgs {inherit self' self pkgs;};
        devShells = import ./nix/shell {inherit self' self lib pkgs inputs;};
        treefmt = {
          projectRootFile = "flake.nix";
          programs.zig.enable = true;
        };
      };
    };
}
