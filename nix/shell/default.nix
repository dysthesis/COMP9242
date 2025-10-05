{
  inputs,
  self',
  self,
  pkgs,
  lib,
  ...
}: let
  pkgs' = pkgs.unstable.pkgsCross.aarch64-multiplatform;
  gdb = pkgs'.writeShellScriptBin "gdb" ''
    exec ${pkgs'.buildPackages.gdb}/bin/aarch64-unknown-linux-gnu-gdb "$@"
  '';
  gef' = pkgs'.buildPackages.gef.override {
    inherit gdb;
  };
  justFile = pkgs.writeTextFile {
    name = "Justfile";
    text =
      # Just
      ''
        set shell := ["${lib.getExe pkgs.unstable.dash}", "-c"]
        build:
          nix build

        [working-directory: 'result']
        debug:
          ${lib.getExe inputs.pwndbg.packages.${pkgs'.system}.default} -q \
            -ex 'set substitute-path /build/source ${self}' \
            -ex 'set remote swbreak-feature on' \
            -ex 'set remote hwbreak-feature on' \
            -ex "file ./projects/aos/sos/sos" \
            -ex "target remote | ./odroid serial_raw"

        [working-directory: 'result']
        reset: build
          ./reset.sh

        [working-directory: 'result']
        run: build
          tmux splitw -h ./odroid serial
          tmux splitw -v ./odroid netcon

        reload: build run reset debug
      '';
  };
in {
  default = pkgs.unstable.mkShell {
    name = "COMP9242 SOS";
    inputsFrom = [self.packages.${pkgs.system}.default];
    packages =
      (with pkgs; [
        cmake
        ninja
        qemu_full
        ccache
        dtc
        libxml2.bin
        unstable.just

        (python3.withPackages (_: [self'.packages.sel4Deps]))

        # odroid
        unstable.websocat

        # nix stuff
        unstable.nil
        unstable.alejandra
        unstable.statix
        unstable.deadnix
        unstable.clang-tools
        gef'
        (unstable.typst.withPackages (ps:
          with ps; [
            algo
            algorithmic
            cetz
          ]))
        unstable.tinymist
        (pkgs.writeShellScriptBin "gdb"
          # sh
          ''
            exec ${lib.getExe gef'} "$@"
          '')
      ])
      ++ (with pkgs'.stdenv; [
        cc
        cc.bintools
      ]);
    CMAKE_EXPORT_COMPILE_COMMANDS = "ON";
    shellHook =
      /*
      sh
      */
      ''
        ln -sf ${justFile} Justfile
        export GEF_RC="$PWD/.gef.rc"
      '';
  };
}
