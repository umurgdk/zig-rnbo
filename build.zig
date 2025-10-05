const std = @import("std");
const LazyPath = std.Build.LazyPath;

const ResolvedTarget = std.Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;
const Build = std.Build;

pub const Artifact = enum {
    loader_jni,
    zig_module,
};

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const artifact = b.option(Artifact, "artifact", "Build dynamic library loader") orelse .zig_module;

    switch (artifact) {
        .loader_jni => buildLoaderJni(b, target, optimize),
        .zig_module => buildZigLibrary(b, target, optimize),
    }
}

fn buildLoaderJni(b: *Build, target: ResolvedTarget, optimize: OptimizeMode) void {
    const ndk_sysroot = b.option([]const u8, "ndk_sysroot", "Android NDK sysroot") orelse {
        return b.default_step.dependOn(&b.addFail("-Dndk_sysroot parameter missing").step);
    };

    const android_dep = b.lazyDependency("android", .{
        .target = target,
        .optimize = optimize,
        .ndk_sysroot = ndk_sysroot,
    }) orelse return;

    const options = b.addOptions();
    options.addOption([]const u8, "java_package", ".JAVA_PACKAGE_OPTION_MISSING.");

    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/loader_jni.zig"),
        .imports = &.{
            .{ .name = "android", .module = android_dep.module("android") },
        },
    });

    module.addOptions("options", options);

    const library = b.addLibrary(.{
        .name = "rnbo_loader",
        .root_module = module,
        .linkage = .dynamic,
    });

    b.installArtifact(library);
}

fn buildZigLibrary(b: *Build, target: ResolvedTarget, optimize: OptimizeMode) void {
    const source_dir = b.option(LazyPath, "source_dir", "Path to RNBO C++ exported directory") orelse @panic("-Dsource_dir to RNBO C++ export directory is missing");
    const export_class_name = b.option([]const u8, "export_class_name", "Exported C++ class name, default: rnbo_source.cpp") orelse "rnbo_source.cpp";

    const rnbo_mod = b.addModule("rnbo", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/rnbo.zig"),
        .sanitize_c = false,
    });

    const c_files = [_]LazyPath{
        b.path("src/rnbo_export.cpp"),
        source_dir.path(b, export_class_name),
        source_dir.path(b, "rnbo/RNBO.cpp"),
    };

    for (&c_files) |path| {
        rnbo_mod.addCSourceFile(.{
            .file = path,
            .flags = &.{"-std=c++11"},
            .language = .cpp,
        });
    }

    rnbo_mod.addIncludePath(source_dir.path(b, "rnbo"));
    rnbo_mod.addIncludePath(source_dir.path(b, "rnbo/common"));
}
