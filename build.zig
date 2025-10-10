const std = @import("std");

const LazyPath = std.Build.LazyPath;
const ResolvedTarget = std.Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;
const Build = std.Build;

const USE_FLOAT32_FLAG = "-DRNBO_USE_FLOAT32";

pub const Artifact = enum {
    rnbo_lib,
    loader_jni,
    loader,
    zig_module,
};

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const artifact = b.option(Artifact, "artifact", "Build dynamic library loader") orelse .zig_module;
    const use_f32 = b.option(bool, "use_float32", "Use 32bit floating numbers instead of 64bit (default: true)") orelse true;

    switch (artifact) {
        .loader_jni => buildLoaderJni(b, target, optimize, use_f32),
        .zig_module => buildZigLibrary(b, target, optimize, use_f32),
        .rnbo_lib => buildRnboLibrary(b, target, optimize, use_f32),
        .loader => buildLoader(b, target, optimize, use_f32),
    }
}

fn buildRnboLibrary(b: *Build, target: ResolvedTarget, optimize: OptimizeMode, use_f32: bool) void {
    const ndk_sysroot_option = b.option([]const u8, "ndk_sysroot", "Android NDK sysroot");
    const rnbo_export = b.option(LazyPath, "rnbo_export", "RNBO export path (default: export)") orelse b.path("export");

    const rnbo_class_name = b.option([]const u8, "rnbo_class_name", "RNBO export class name (default: rnbo_source.cpp)") orelse "rnbo_source.cpp";
    const rnbo_library_name = b.option([]const u8, "library_name", "name of the rnbo library to be built (default: rnbo)") orelse "rnbo";

    const rnbo_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .sanitize_c = false,
        .strip = true,
    });

    const c_files = [_]LazyPath{
        b.path("src/rnbo_export.cpp"),
        rnbo_export.path(b, rnbo_class_name),
        rnbo_export.path(b, "rnbo/RNBO.cpp"),
    };

    for (&c_files) |path| {
        rnbo_module.addCSourceFile(.{
            .file = path,
            .flags = &.{ "-std=c++11", "-DANDROID", if (use_f32) USE_FLOAT32_FLAG else "" },
            .language = .cpp,
        });
    }

    rnbo_module.addIncludePath(rnbo_export.path(b, "rnbo"));
    rnbo_module.addIncludePath(rnbo_export.path(b, "rnbo/common"));

    if (target.result.abi.isAndroid()) {
        const android = @import("android");
        const ndk_sysroot = ndk_sysroot_option orelse {
            return b.default_step.dependOn(&b.addFail("-Dndk_sysroot parameter missing").step);
        };

        const libc_conf = android.createLibCConf(b, target, ndk_sysroot) catch {
            b.default_step.dependOn(&b.addFail("failed to create libc.conf file").step);
            return;
        };

        const arch_name = switch (target.result.cpu.arch) {
            .aarch64 => "aarch64",
            else => @tagName(target.result.cpu.arch),
        };

        const rnbo_library = b.addLibrary(.{
            .name = b.fmt("{s}.{s}", .{ rnbo_library_name, arch_name }),
            .linkage = .dynamic,
            .root_module = rnbo_module,
        });

        rnbo_module.link_libc = true;
        rnbo_module.link_libcpp = true;
        rnbo_library.step.dependOn(libc_conf.step);
        rnbo_library.libc_file = libc_conf.path;
        // rnbo_library.link_emit_relocs = true;
        // rnbo_library.link_eh_frame_hdr = true;
        // rnbo_library.link_function_sections = true;
        // rnbo_library.bundle_compiler_rt = true;
        // rnbo_library.export_table = true;

        android.addNdkSysrootPaths(b, target, ndk_sysroot, rnbo_module);

        b.installArtifact(rnbo_library);
    } else {
        const rnbo_library = b.addLibrary(.{
            .name = rnbo_library_name,
            .linkage = .dynamic,
            .root_module = rnbo_module,
        });

        b.installArtifact(rnbo_library);
    }
}

fn buildLoaderJni(b: *Build, target: ResolvedTarget, optimize: OptimizeMode, use_f32: bool) void {
    const ndk_sysroot = b.option([]const u8, "ndk_sysroot", "Android NDK sysroot") orelse {
        return b.default_step.dependOn(&b.addFail("-Dndk_sysroot parameter missing").step);
    };

    const java_package_name = b.option([]const u8, "java_package", "JNI export java package name") orelse {
        return b.default_step.dependOn(&b.addFail("-Djava_package missing").step);
    };

    const android_dep = b.lazyDependency("android", .{
        .target = target,
        .optimize = optimize,
        .ndk_sysroot = ndk_sysroot,
    }) orelse return;

    const android = @import("android");

    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/loader_jni.zig"),
        .link_libc = true,
        .strip = true,
        .imports = &.{
            .{ .name = "android", .module = android_dep.module("android") },
        },
    });

    const options = b.addOptions();
    options.addOption([]const u8, "java_package", java_package_name);
    options.addOption(bool, "use_f32", use_f32);
    module.addOptions("options", options);

    const libc_conf = android.createLibCConf(b, target, ndk_sysroot) catch @panic("libc.conf creation failed");

    const library = b.addLibrary(.{
        .name = "rnbo_loader",
        .root_module = module,
        .linkage = .dynamic,
    });

    library.step.dependOn(libc_conf.step);
    library.libc_file = libc_conf.path;

    const arch_name = switch (target.result.cpu.arch) {
        .aarch64 => "arm64-v8a",
        else => @tagName(target.result.cpu.arch),
    };

    const install_lib = b.addInstallArtifact(library, .{
        .dest_dir = .{
            .override = .{ .custom = b.fmt("jniLibs/{s}", .{arch_name}) },
        },
    });

    b.getInstallStep().dependOn(&install_lib.step);
}

fn buildZigLibrary(b: *Build, target: ResolvedTarget, optimize: OptimizeMode, use_f32: bool) void {
    const source_dir = b.option(LazyPath, "source_dir", "Path to RNBO C++ exported directory") orelse @panic("-Dsource_dir to RNBO C++ export directory is missing");
    const export_class_name = b.option([]const u8, "export_class_name", "Exported C++ class name, default: rnbo_source.cpp") orelse "rnbo_source.cpp";

    const rnbo_mod = b.addModule("rnbo", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/rnbo.zig"),
        .sanitize_c = false,
    });

    const options = b.addOptions();
    options.addOption(bool, "use_f32", use_f32);
    rnbo_mod.addOptions("options", options);

    const c_files = [_]LazyPath{
        b.path("src/rnbo_export.cpp"),
        source_dir.path(b, export_class_name),
        source_dir.path(b, "rnbo/RNBO.cpp"),
    };

    for (&c_files) |path| {
        rnbo_mod.addCSourceFile(.{
            .file = path,
            .flags = &.{ "-std=c++11", if (use_f32) USE_FLOAT32_FLAG else "" },
            .language = .cpp,
        });
    }

    rnbo_mod.addIncludePath(source_dir.path(b, "rnbo"));
    rnbo_mod.addIncludePath(source_dir.path(b, "rnbo/common"));
}

fn buildLoader(b: *Build, target: ResolvedTarget, optimize: OptimizeMode, use_f32: bool) void {
    const module = b.addModule("rnbo_loader", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/loader.zig"),
    });

    const options = b.addOptions();
    options.addOption(bool, "use_f32", use_f32);
    module.addOptions("options", options);
}
