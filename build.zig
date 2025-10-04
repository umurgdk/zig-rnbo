const std = @import("std");
const LazyPath = std.Build.LazyPath;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const source_dir = b.option(LazyPath, "source_dir", "Path to RNBO C++ exported directory") orelse @panic("-Dsource_dir to RNBO C++ export directory is missing");
    const export_class_name = b.option([]const u8, "export_class_name", "Exported C++ class name, default: rnbo_source.cpp") orelse "rnbo_source.cpp";

    const rnbo_mod = b.addModule("rnbo", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("rnbo.zig"),
        .sanitize_c = false,
    });

    const c_files = [_]LazyPath{
        b.path("rnbo_export.cpp"),
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
