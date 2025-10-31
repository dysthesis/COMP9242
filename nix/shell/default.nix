{
  inputs,
  self',
  self,
  pkgs,
  lib,
  ...
}: let
  pkgs' = pkgs.pkgsCross.aarch64-multiplatform;
  pkgsUnstable' = pkgs.unstable.pkgsCross.aarch64-multiplatform;
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
          ${lib.getExe inputs.pwndbg.packages.${pkgsUnstable'.system}.default} -q \
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
  realZig = pkgs.unstable.zig;
  zigWrapper = pkgs.writeShellScriptBin "zig" ''
    #!${pkgs.unstable.dash}/bin/dash
    set -eu
    zig_bin="${lib.getExe realZig}"
    if [ "$#" -gt 0 ] && [ "$1" = "translate-c" ]; then
      shift
      exec "$zig_bin" translate-c -target aarch64-freestanding-gnu "$@"
    fi
    exec "$zig_bin" "$@"
  '';
  zlsWrapper = pkgs.writeShellScriptBin "zls" ''
    #!${pkgs.unstable.dash}/bin/dash
    set -eu
    if [ -n "''${ZLS_CONFIG_PATH-}" ]; then
      config_path="''${ZLS_CONFIG_PATH}"
    else
      config_path="${zlsConfig}"
    fi
    for arg in "$@"; do
      case "$arg" in
        --config-path|--config-path=*)
          exec ${lib.getExe pkgs.unstable.zls} "$@"
          ;;
      esac
    done
    exec ${lib.getExe pkgs.unstable.zls} "$@" --config-path "$config_path"
  '';
  zlsConfig = pkgs.writeTextFile {
    name = "zls.json";
    text = builtins.toJSON {
      zig_exe_path = lib.getExe zigWrapper;
      # enable_build_on_save = false;
      prefer_ast_check_as_child_process = false;
    };
  };
in {
  default = pkgs.unstable.mkShellNoCC {
    name = "COMP9242 SOS";
    inputsFrom = [self.packages.${pkgs.system}.default];
    packages = with pkgs;
      [
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
        unstable.nixd
        unstable.alejandra
        unstable.statix
        unstable.deadnix
        unstable.clang-tools
        # Typst for docs
        (unstable.typst.withPackages (ps:
          with ps; [
            algo
            algorithmic
            cetz
          ]))
        unstable.tinymist

        unstable.black
        unstable.basedpyright
        unstable.astral

        # Zig toolchain
        zigWrapper
        zlsWrapper
        unstable.zlint
        unstable.binsider
      ]
      ++ (with pkgs'.gcc11Stdenv; [
        gcc11
        cc
        binutils
      ]);
    CMAKE_EXPORT_COMPILE_COMMANDS = "ON";
    CROSS_COMPILER_PREFIX = "${pkgs'.stdenv.cc.targetPrefix}";
    CROSS_COMPILE = "$CROSS_COMPILER_PREFIX";
    DIRENV_LOG_FORMAT = "";
    CFLAGS = [
      "-fPIC"
      "-fno-stack-protector"
    ];

    shellHook =
      /*
      sh
      */
      ''
        ln -sf ${justFile} Justfile
        ln -sf ${zlsConfig} zls.json
        export ZLS_CONFIG_PATH="$PWD/zls.json"
        export GEF_RC="$PWD/.gef.rc"
        if [ -d build ]; then
          ninja -C build -t compdb > build/compile_commands.json
        else
          echo "zls note: run ../init-build.sh in a build directory to populate generated headers" >&2
        fi
      '';
  };
}
