{
  self,
  self',
  pkgs,
  ...
}: let
  pkgs' = pkgs.pkgsCross.aarch64-multiplatform;
in
  pkgs'.gcc11Stdenv.mkDerivation rec {
    name = "sel4";
    src = self;

    nativeBuildInputs = with pkgs; [
      makeWrapper
      cmake
      cpio
      ninja
      ccache
      rsync
      dtc
      qemu_full
      git
      ncurses
      cacert
      protobuf
      (python3.withPackages (_: [self'.packages.sel4Deps]))
      libxml2
    ];

    buildInputs = with pkgs; [ubootTools websocat];
    CROSS_COMPILE = "${pkgs'.stdenv.cc.targetPrefix}-";

    CCACHE_DIR = "/var/cache/ccache";
    CCACHE_UMASK = "007";
    CFLAGS = "-fPIC";

    hardeningDisable = ["all"];
    enableParallelBuilding = true;

    configurePhase = ''
      mkdir -p build
      cmake -S . -B build \
        -DAARCH64=TRUE \
        -DCMAKE_TOOLCHAIN_FILE=kernel/gcc.cmake \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        -G Ninja
    '';
    postPatch = ''
      patchShebangs kernel/tools || true
      patchShebangs tools || true
    '';

    buildPhase = ''
      ninja -C build
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -r build/* $out

      install -Dm0755 ${src}/projects/aos/reset.sh $out/reset.sh
      install -Dm0755 ${src}/projects/aos/odroid $out/odroid

      patchShebangs --build $out

      wrapProgram $out/odroid \
        --prefix PATH : ${pkgs.lib.makeBinPath [pkgs.websocat]}
      runHook postInstall
    '';
  }
