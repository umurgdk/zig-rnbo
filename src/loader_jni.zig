const std = @import("std");
const android = @import("android");
const options = @import("options");

const loader = @import("loader.zig");
const jni = android.jni;

const ErrorCode = std.meta.Int(.unsigned, @bitSizeOf(anyerror));
const OK: ErrorCode = 0;

const LibraryHandle = jni.jlong;

pub const panic = android.panic.handler;
pub const std_options: std.Options = .{
    .logFn = android.log.StdLogger("RnboLoader").stdLogFn,
};

comptime {
    jni.exportJNI(options.java_package ++ "RnboLoader", RnboLoader);
    jni.exportJNI(options.java_package ++ "RnboLibrary", RnboLibrary);
}

const allocator = std.heap.smp_allocator;

const RnboLoader = struct {
    const log = std.log.scoped(.RnboLoader);

    export fn loadLibrary(cenv: *jni.cEnv, this: jni.jobject, path_jstr: jni.jstring) callconv(.c) jni.jobject {
        _ = this;
        const jenv = jni.JNIEnv.warp(cenv);

        var path_copied = false;

        const path_ptr = jenv.getStringUTFChars(path_jstr, &path_copied);
        defer jenv.releaseStringUTFChars(path_ptr);

        const path = path_ptr[0..std.mem.len(path_ptr)];

        const library = allocator.create(loader.Library) catch |err| {
            log.err("Failed to allocate memory for the library: {!}", .{err});
            return jni.jnull;
        };

        library.* = loader.loadLibrary(path) catch |err| {
            log.err("Failed to load RNBO library: {!}", .{err});
            allocator.destroy(library);
            return jni.jnull;
        };
    }
};

const RnboLibrary = struct {};
