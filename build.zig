const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .gnu,
    });
    const optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const sanitize_c: std.zig.SanitizeC = .trap;

    // discard all these cmake imports for now
    // cannot comment this out as zig will complain about extra options
    const cmake_sel4 =
        b.option(std.Build.LazyPath, "sel4", "") orelse
        b.path("build/libsel4/libsel4.a");
    _ = cmake_sel4;
    const cmake_muslc =
        b.option(std.Build.LazyPath, "muslc", "") orelse
        b.path("build/projects/musllibc/build-temp/stage/lib/libc.a");
    _ = cmake_muslc;
    const cmake_utils =
        b.option(std.Build.LazyPath, "utils", "") orelse
        b.path("build/projects/libutils/libutils.a");
    _ = cmake_utils;
    const cmake_aos =
        b.option(std.Build.LazyPath, "aos", "") orelse
        b.path("build/projects/aos/libaos/libaos.a");
    _ = cmake_aos;

    const librbtree = b.addModule("librbtree", .{
        .root_source_file = b.path("projects/aos/librbtree/src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = sanitize_c,
    });
    addCommonIncludePaths(b, librbtree);
    addExePatch(b, librbtree, .{ .lto = false });

    const cimports = b.addModule("table-helper", .{
        .root_source_file = b.path("projects/aos/cimports.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = sanitize_c,
    });
    addCommonIncludePaths(b, cimports);
    addExePatch(b, cimports, .{ .lto = false });

    const libipc_module = b.addModule("libipc", .{
        .root_source_file = b.path("projects/aos/libipc/src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = sanitize_c,
    });

    addCommonIncludePaths(b, libipc_module);
    libipc_module.addIncludePath(b.path("projects/aos/libipc/include"));
    libipc_module.addIncludePath(b.path("projects/aos/sos/src"));
    libipc_module.addImport("cimports", cimports);
    libipc_module.addImport("rbtree", librbtree);
    addExePatch(b, libipc_module, .{ .lto = false });

    const libipc = b.addLibrary(.{
        .linkage = .static,
        .name = "ziglib_ipc",
        .root_module = libipc_module,
    });
    libipc.link_gc_sections = false;
    b.installArtifact(libipc);

    const libsosapi_module = b.addModule("libsosapi", .{
        .root_source_file = b.path("projects/aos/libsosapi/src/sos.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = sanitize_c,
    });
    addCommonIncludePaths(b, libsosapi_module);

    libsosapi_module.addImport("cimports", cimports);
    libsosapi_module.addImport("rbtree", librbtree);
    libsosapi_module.addImport("libipc", libipc_module);
    libsosapi_module.addIncludePath(b.path("projects/aos/libsosapi/include"));
    addExePatch(b, libsosapi_module, .{ .lto = false });

    const libsosapi = b.addLibrary(.{
        .linkage = .static,
        .name = "ziglib_sosapi",
        .root_module = libsosapi_module,
    });
    libsosapi.link_gc_sections = false;
    b.installArtifact(libsosapi);

    const libclock_module = b.addModule("libclock", .{
        .root_source_file = b.path("projects/aos/libclock/src/clock.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = sanitize_c,
    });
    addCommonIncludePaths(b, libclock_module);

    libclock_module.addImport("cimports", cimports);
    libclock_module.addImport("rbtree", librbtree);
    libclock_module.addIncludePath(b.path("projects/aos/libclock/include"));
    libclock_module.addIncludePath(b.path("projects/aos/libclock/src"));
    addExePatch(b, libclock_module, .{ .lto = false });

    const libclock = b.addLibrary(.{
        .linkage = .static,
        .name = "ziglib_clock",
        .root_module = libclock_module,
    });
    libclock.link_gc_sections = false;
    b.installArtifact(libclock);

    const libfile_module = b.addModule("libfile", .{
        .root_source_file = b.path("projects/aos/sos/src/file.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = sanitize_c,
    });

    libfile_module.addImport("cimports", cimports);
    addCommonIncludePaths(b, libfile_module);
    libfile_module.addIncludePath(b.path("projects/aos/sos/src"));
    addExePatch(b, libfile_module, .{ .lto = false });

    const libfile = b.addLibrary(.{
        .linkage = .static,
        .name = "ziglib_file",
        .root_module = libfile_module,
    });
    libfile.link_gc_sections = false;
    b.installArtifact(libfile);

    const libipc_check = b: {
        const m = b.createModule(.{
            .root_source_file = b.path("projects/aos/libipc/src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_c = sanitize_c,
        });
        addCommonIncludePaths(b, m);
        m.addImport("cimports", cimports);
        m.addImport("rbtree", librbtree);
        m.addIncludePath(b.path("projects/aos/libipc/include"));
        const l = b.addLibrary(.{
            .linkage = .static,
            .name = "ziglib_ipc_check",
            .root_module = m,
        });
        l.link_gc_sections = false;
        break :b l;
    };

    const sos = b: {
        const src = b.path("projects/aos/sos/src");
        const m = b.createModule(.{
            .root_source_file = src.path(b, "main.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_c = sanitize_c,
        });
        addCommonIncludePaths(b, m);
        addExePatch(b, m, .{ .lto = false });
        m.addImport("cimports", cimports);
        m.addImport("rbtree", librbtree);
        m.addImport("libipc", libipc_module);
        m.addIncludePath(src);
        const l = b.addLibrary(.{
            .linkage = .static,
            .name = "ziglib_sos",
            .root_module = m,
        });
        l.link_gc_sections = false;
        break :b l;
    };
    b.installArtifact(sos);

    const sos_check = b: {
        const src = b.path("projects/aos/sos/src");
        const m = b.createModule(.{
            .root_source_file = src.path(b, "main.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_c = sanitize_c,
        });
        addCommonIncludePaths(b, m);
        m.addImport("cimports", cimports);
        m.addImport("rbtree", librbtree);
        m.addImport("libipc", libipc_module);
        m.addIncludePath(src);
        const l = b.addLibrary(.{
            .linkage = .static,
            .name = "ziglib_sos",
            .root_module = m,
        });
        l.link_gc_sections = false;
        break :b l;
    };

    const check = b.step("check", "Check if sos compiles");
    check.dependOn(&libipc_check.step);
    check.dependOn(&sos_check.step);
    check.dependOn(&libipc.step);
}

fn addCommonIncludePaths(b: *std.Build, m: *std.Build.Module) void {
    const paths = [_][]const u8{
        "build/libsel4/autoconf",
        "build/kernel/gen_config",
        "build/libsel4/gen_config",
        "projects/sel4runtime/include",
        "projects/sel4runtime/include/mode/64",
        "projects/sel4runtime/include/sel4_arch/aarch64",
        "kernel/libsel4/include",
        "kernel/libsel4/arch_include/arm",
        "kernel/libsel4/sel4_arch_include/aarch64",
        "kernel/libsel4/sel4_plat_include/odroidc2",
        "kernel/libsel4/mode_include/64",
        "build/libsel4/include",
        "build/libsel4/arch_include/arm",
        "build/libsel4/sel4_arch_include/aarch64",
        "build/projects/musllibc/build-temp/stage/include",
        "projects/libelf/include",
        "projects/libcpio/include",
        "projects/aos/libnetworkconsole/include",
        "build/projects/libpicotcp/picotcp_external/picotcp/build/include",
        "build/projects/libpicotcp/gen_config",
        "projects/aos/libsosapi/include",
        "projects/libutils/include",
        "projects/libutils/arch_include/arm",
        "build/projects/libutils/gen_config",
        "build/projects/aos/sos/gen_config",
        "projects/aos/libdebugger/include",
        "projects/aos/libclock/include",
        "projects/aos/libsel4cspace/include",
        "projects/aos/libaos/include",
        "projects/picotcp-bsd",
        "projects/aos/sos/src",
        "libnfs/lib/.include",
        "libnfs/rquota",
        "libnfs/portmap",
        "libnfs/nsm",
        "libnfs/nlm",
        "libnfs/nfs4",
        "libnfs/nfs",
        "projects/aos/libipc/include",
        "libnfs/mount",
        "projects/aos/libethernet/include",
        "projects/libgdb/include",
        "projects/libco",
        "projects/aos/sos/src",
        "projects/aos/libclock/src",
        ".vscode/preinclude.h",
    };
    for (paths) |path| m.addIncludePath(b.path(path));
}

fn addExePatch(b: *std.Build, m: *std.Build.Module, flags: struct { lto: bool }) void {
    m.addCSourceFile(.{
        .file = b.path("zig_patch/aarch64_syscalls.c"),
        .flags = if (flags.lto) &.{"-flto"} else &.{},
    });
}
