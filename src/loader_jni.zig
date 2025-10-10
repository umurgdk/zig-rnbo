const std = @import("std");
const android = @import("android");
const options = @import("options");

const loader = @import("loader.zig");
const jni = android.jni;

const ErrorCode = std.meta.Int(.unsigned, @bitSizeOf(anyerror));
const OK: ErrorCode = 0;

const LibraryHandle = jni.jlong;

const Number = if (options.use_f32) jni.jfloat else jni.jdouble;
const SampleType = if (options.use_f32) jni.jfloat else jni.jdouble;
const SampleArray = if (options.use_f32) jni.jfloatArray else jni.jdoubleArray;

pub const panic = android.panic.handler;
pub const std_options: std.Options = .{
    .logFn = android.log.StdLogger("RnboLoader").stdLogFn,
};

comptime {
    jni.exportJNI(options.java_package ++ ".RnboLoader", RnboLoader);
    jni.exportJNI(options.java_package ++ ".RnboLibrary", RnboLibrary);
    jni.exportJNI(options.java_package ++ ".RnboObject", RnboObject);
}

const allocator = std.heap.smp_allocator;

fn toJniClassName(comptime name: []const u8) [name.len:0]u8 {
    var new_name: [name.len:0]u8 = undefined;
    for (name, 0..) |char, i| {
        if (char == '.') {
            new_name[i] = '/';
        } else {
            new_name[i] = char;
        }
    }

    return new_name;
}

const RnboLoader = struct {
    pub fn loadLibrary(cenv: *jni.cEnv, _: jni.jclass, path_jstr: jni.jstring) callconv(.c) jni.jobject {
        const jenv = jni.JNIEnv.warp(cenv);

        var path_copied = false;

        const path_ptr = jenv.getStringUTFChars(path_jstr, &path_copied);
        defer jenv.releaseStringUTFChars(path_jstr, path_ptr);

        const path = path_ptr[0..std.mem.len(path_ptr) :0];
        std.log.debug("loading rnbo library at {s}", .{path});

        const library = allocator.create(loader.Library) catch |err| {
            _ = android.fail(err, @errorReturnTrace(), "failed to allocate memory for Library", .{});
            return null;
        };

        library.* = loader.loadLibrary(path) catch |err| {
            _ = android.fail(err, @errorReturnTrace(), "failed to load library at {s}", .{path});
            allocator.destroy(library);
            return null;
        };

        const library_object = RnboLibrary.construct(jenv, library) catch |err| {
            _ = android.fail(err, @errorReturnTrace(), "failed to construct RnboLibrary java object", .{});
            library.handle.close();
            allocator.destroy(library);
            return null;
        };

        return library_object;
    }
};

const RnboLibrary = struct {
    pub const class_name = toJniClassName(options.java_package ++ ".RnboLibrary");

    threadlocal var cached_class: jni.jclass = null;
    threadlocal var cached_constructor: jni.jmethodID = null;
    threadlocal var cached_handle_fieldid: jni.jfieldID = null;

    pub const ObjectHandle = jni.jlong;
    pub const PresetListPtr = jni.jlong;
    pub const PresetPtr = jni.jlong;

    pub fn getClass(env: jni.JNIEnv) !jni.jclass {
        if (cached_class) |class| return class;
        const class = env.findClass(&class_name) orelse return error.JavaClassNotFound;
        cached_class = env.newGlobalRef(class);
        return class;
    }

    pub fn getConstructor(env: jni.JNIEnv, class: jni.jclass) !jni.jmethodID {
        if (cached_constructor) |cons| return cons;
        const constructor = env.getMethodID(class, "<init>", "(J)V") orelse return error.JavaMethodNotFound;
        cached_constructor = constructor;
        return constructor;
    }

    pub fn getHandleField(env: jni.JNIEnv) !jni.jfieldID {
        if (cached_handle_fieldid) |fid| return fid;
        const field_id = env.getFieldID(try getClass(env), "handle", "J") orelse return error.JavaFieldNotFound;
        cached_handle_fieldid = field_id;
        return field_id;
    }

    pub fn handleToPtr(comptime T: type, handle: jni.jlong) *T {
        const address: usize = @bitCast(handle);
        return @ptrFromInt(address);
    }

    fn getLibrary(env: jni.JNIEnv, this: jni.jobject) !*loader.Library {
        const field_id = try getHandleField(env);
        const address: usize = @bitCast(env.getField(this, jni.jlong, field_id));
        return @ptrFromInt(address);
    }

    pub fn construct(env: jni.JNIEnv, library: *loader.Library) !jni.jobject {
        const handle: jni.jlong = @bitCast(@intFromPtr(library));
        const class = try getClass(env);
        const constructor = try getConstructor(env, class);
        const object = env.newObject(class, constructor, &jni.toJValues(handle));
        return object;
    }

    pub fn newObject(cenv: *jni.cEnv, this: jni.jobject) callconv(.c) jni.jobject {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch |err| {
            _ = android.fail(err, @errorReturnTrace(), "couldn't get library", .{});
            return null;
        };

        const object = library.functions.objectNew();
        const object_instance = RnboObject.construct(env, this, object) catch |err| {
            _ = android.fail(err, @errorReturnTrace(), "failed to construct RnboLibrary java object", .{});
            return null;
        };

        return object_instance;
    }
};

const RnboObject = struct {
    pub const class_name = toJniClassName(options.java_package ++ ".RnboObject");

    threadlocal var cached_class: jni.jclass = null;
    threadlocal var cached_constructor: jni.jmethodID = null;
    threadlocal var cached_library_fieldid: jni.jfieldID = null;
    threadlocal var cached_objhandle_fieldid: jni.jfieldID = null;

    pub fn getClass(env: jni.JNIEnv) !jni.jclass {
        if (cached_class) |class| return class;
        const class = env.findClass(&class_name) orelse return error.JavaClassNotFound;
        cached_class = env.newGlobalRef(class);
        return class;
    }

    pub fn getConstructor(env: jni.JNIEnv, class: jni.jclass) !jni.jmethodID {
        if (cached_constructor) |cons| return cons;
        const constructor = env.getMethodID(class, "<init>", "(L" ++ RnboLibrary.class_name ++ ";J)V") orelse return error.JavaMethodNotFound;
        cached_constructor = constructor;
        return constructor;
    }

    pub fn getObjectHandleField(env: jni.JNIEnv) !jni.jfieldID {
        if (cached_objhandle_fieldid) |fid| return fid;
        const field_id = env.getFieldID(try getClass(env), "handle", "J") orelse return error.JavaFieldNotFound;
        cached_objhandle_fieldid = field_id;
        return field_id;
    }

    pub fn getLibraryField(env: jni.JNIEnv) !jni.jfieldID {
        if (cached_library_fieldid) |fid| return fid;
        const field_id = env.getFieldID(try getClass(env), "library", "L" ++ RnboLibrary.class_name ++ ";") orelse return error.JavaFieldNotFound;
        cached_library_fieldid = field_id;
        return field_id;
    }

    pub fn handleToPtr(comptime T: type, handle: jni.jlong) *T {
        const address: usize = @bitCast(handle);
        return @ptrFromInt(address);
    }

    pub fn getLibrary(env: jni.JNIEnv, this: jni.jobject) !*loader.Library {
        const field_id = try getLibraryField(env);
        const library_jobject = env.getField(this, jni.jobject, field_id);
        const library = try RnboLibrary.getLibrary(env, library_jobject);
        return library;
    }

    pub fn getObject(env: jni.JNIEnv, this: jni.jobject) !*loader.Object {
        const field_id = try getObjectHandleField(env);
        const handle = env.getField(this, jni.jlong, field_id);
        const address: usize = @bitCast(handle);
        return @ptrFromInt(address);
    }

    pub fn construct(env: jni.JNIEnv, library: jni.jobject, rnbo_object: *loader.Object) !jni.jobject {
        const class = try getClass(env);
        const constructor = try getConstructor(env, class);
        const handle: jni.jlong = @bitCast(@intFromPtr(rnbo_object));
        const object = env.newObject(class, constructor, &jni.toJValues(.{ library, handle }));
        return object;
    }

    pub fn initialize(cenv: *jni.cEnv, this: jni.jobject) callconv(.c) ErrorCode {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch |err| {
            return android.fail(err, @errorReturnTrace(), "couldn't get libarary", .{});
        };
        const object = getObject(env, this) catch |err| {
            return android.fail(err, @errorReturnTrace(), "couldn't get rnbo object", .{});
        };

        library.functions.objectInitialize(object);
        return OK;
    }

    pub fn destroy(cenv: *jni.cEnv, this: jni.jobject) callconv(.c) ErrorCode {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch |err| {
            return android.fail(err, @errorReturnTrace(), "couldn't get libarary", .{});
        };
        const object = getObject(env, this) catch |err| {
            return android.fail(err, @errorReturnTrace(), "couldn't get rnbo object", .{});
        };

        library.functions.objectDestroy(object);
        return OK;
    }

    pub fn prepareToProcess(cenv: *jni.cEnv, this: jni.jobject, sample_rate: jni.jlong, buffer_frames: jni.jlong) callconv(.c) ErrorCode {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch |err| {
            return android.fail(err, @errorReturnTrace(), "couldn't get libarary", .{});
        };
        const object = getObject(env, this) catch |err| {
            return android.fail(err, @errorReturnTrace(), "couldn't get rnbo object", .{});
        };

        library.functions.objectPrepareToProcess(object, @intCast(sample_rate), @intCast(buffer_frames));
        return OK;
    }

    pub fn setPreset(cenv: *jni.cEnv, this: jni.jobject, preset: jni.jobject) callconv(.c) ErrorCode {
        _ = cenv; // autofix
        _ = this; // autofix
        _ = preset; // autofix
        std.log.err("RnboObject.setPreset is not implemented yet!", .{});
        return OK;
    }

    pub fn process(cenv: *jni.cEnv, this: jni.jobject, output_chan1_arr: SampleArray, output_chan2_arr: SampleArray, num_frames: jni.jlong) callconv(.c) ErrorCode {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch |err| {
            return android.fail(err, @errorReturnTrace(), "couldn't get libarary", .{});
        };
        const object = getObject(env, this) catch |err| {
            return android.fail(err, @errorReturnTrace(), "couldn't get rnbo object", .{});
        };

        var output_chan1_copied = false;
        const output_chan1_ptr = env.getPrimitiveArrayElements(SampleType, output_chan1_arr, &output_chan1_copied);
        defer env.releasePrimitiveArrayElements(SampleType, output_chan1_arr, output_chan1_ptr, .JNIDefault);

        var output_chan2_copied = false;
        const output_chan2_ptr = env.getPrimitiveArrayElements(SampleType, output_chan2_arr, &output_chan2_copied);
        defer env.releasePrimitiveArrayElements(SampleType, output_chan2_arr, output_chan2_ptr, .JNIDefault);

        const outputs = [2][*]SampleType{ output_chan1_ptr, output_chan2_ptr };
        const outputs_ptr: [*c]const [*c]SampleType = @ptrCast(&outputs);

        library.functions.objectProcess(object, null, 0, outputs_ptr, outputs.len, @intCast(num_frames));
        return OK;
    }

    pub fn processInterleaved(
        cenv: *jni.cEnv,
        this: jni.jobject,
        input_buff: jni.jobject,
        input_channels: jni.jint,
        output_buff: jni.jobject,
        output_channels: jni.jint,
        num_frames: jni.jlong,
    ) callconv(.c) ErrorCode {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch |err| {
            return android.fail(err, @errorReturnTrace(), "couldn't get libarary", .{});
        };
        const object = getObject(env, this) catch |err| {
            return android.fail(err, @errorReturnTrace(), "couldn't get rnbo object", .{});
        };

        var input_ptr: ?[*]SampleType = null;
        var output_ptr: ?[*]SampleType = null;

        if (input_buff) |in| {
            const input_addr = env.getDirectBufferAddress(in);
            input_ptr = @ptrFromInt(input_addr);
        }

        if (output_buff) |out| {
            const output_addr = env.getDirectBufferAddress(out);
            output_ptr = @ptrFromInt(output_addr);
        }

        library.functions.objectProcessInterleaved(
            object,
            input_ptr,
            @intCast(input_channels),
            output_ptr,
            @intCast(output_channels),
            @intCast(num_frames),
        );

        return OK;
    }

    pub fn getParameterIndexById(cenv: *jni.cEnv, this: jni.jobject, id: jni.jstring) callconv(.c) jni.jint {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch |err| {
            return android.fail(err, @errorReturnTrace(), "couldn't get libarary", .{});
        };
        const object = getObject(env, this) catch |err| {
            return android.fail(err, @errorReturnTrace(), "couldn't get rnbo object", .{});
        };

        var id_copied = false;
        const id_utf = env.getStringUTFChars(id, &id_copied);
        defer env.releaseStringUTFChars(id, id_utf);

        const index = library.functions.objectGetParameterIndexForId(object, id_utf);
        return index;
    }

    pub fn getParameterValue(cenv: *jni.cEnv, this: jni.jobject, param_index: jni.jint) callconv(.c) Number {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch |err| {
            _ = android.fail(err, @errorReturnTrace(), "couldn't get libarary", .{});
            return 0;
        };
        const object = getObject(env, this) catch |err| {
            _ = android.fail(err, @errorReturnTrace(), "couldn't get rnbo object", .{});
            return 0;
        };

        const value = library.functions.objectGetParameterValue(object, @intCast(param_index));
        return value;
    }

    pub fn setParameterValue(cenv: *jni.cEnv, this: jni.jobject, param_index: jni.jint, value: Number) callconv(.c) ErrorCode {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch |err| {
            return android.fail(err, @errorReturnTrace(), "couldn't get libarary", .{});
        };
        const object = getObject(env, this) catch |err| {
            return android.fail(err, @errorReturnTrace(), "couldn't get rnbo object", .{});
        };

        library.functions.objectSetParameterValue(object, param_index, value);
        return OK;
    }

    pub fn setParameterValueTime(cenv: *jni.cEnv, this: jni.jobject, param_index: jni.jint, value: Number, time_ms: f64) callconv(.c) ErrorCode {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch |err| {
            return android.fail(err, @errorReturnTrace(), "couldn't get libarary", .{});
        };
        const object = getObject(env, this) catch |err| {
            return android.fail(err, @errorReturnTrace(), "couldn't get rnbo object", .{});
        };

        library.functions.objectSetParameterValueTime(object, param_index, value, time_ms);
        return OK;
    }

    pub fn setExternalDataNativeMemory(cenv: *jni.cEnv, this: jni.jobject, id: jni.jstring, data_address: jni.jlong, data_size: jni.jlong, buffer_type_tag: jni.jint, buffer_type_channels: jni.jint, buffer_type_samplerate: jni.jlong) callconv(.c) ErrorCode {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch |err| {
            return android.fail(err, @errorReturnTrace(), "couldn't get libarary", .{});
        };
        const object = getObject(env, this) catch |err| {
            return android.fail(err, @errorReturnTrace(), "couldn't get rnbo object", .{});
        };

        const data_ptr: [*]u8 = @ptrFromInt(@as(usize, @bitCast(data_address)));

        var id_copied = false;
        const id_utf = env.getStringUTFChars(id, &id_copied);
        defer env.releaseStringUTFChars(id, id_utf);

        const buffer_type = loader.BufferType{
            .tag = @enumFromInt(buffer_type_tag),
            .channels = @intCast(buffer_type_channels),
            .samplerate = @floatFromInt(buffer_type_samplerate),
        };

        // TODO(umur): Release callback?!?!?!?!
        library.functions.objectSetExternalData(object, id_utf, data_ptr, @intCast(data_size), buffer_type, null);

        return OK;
    }

    pub fn setExternalData(cenv: *jni.cEnv, this: jni.jobject, id: jni.jstring, data_arr: jni.jbyteArray, buffer_type_tag: jni.jint, buffer_type_channels: jni.jint, buffer_type_samplerate: jni.jlong) callconv(.c) ErrorCode {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch |err| {
            return android.fail(err, @errorReturnTrace(), "couldn't get libarary", .{});
        };
        const object = getObject(env, this) catch |err| {
            return android.fail(err, @errorReturnTrace(), "couldn't get rnbo object", .{});
        };

        var bytes_copied = false;
        const bytes_ptr = env.getPrimitiveArrayElements(jni.jbyte, data_arr, &bytes_copied);
        const data_ptr: [*]u8 = @ptrCast(bytes_ptr);
        const data_len: usize = @intCast(env.getArrayLength(data_arr));
        defer env.releasePrimitiveArrayElements(jni.jbyte, data_arr, bytes_ptr, .JNIAbort);

        var id_copied = false;
        const id_utf = env.getStringUTFChars(id, &id_copied);
        defer env.releaseStringUTFChars(id, id_utf);

        const buffer_type = loader.BufferType{
            .tag = @enumFromInt(buffer_type_tag),
            .channels = @intCast(buffer_type_channels),
            .samplerate = @floatFromInt(buffer_type_samplerate),
        };

        // TODO(umur): Release callback?!?!?!?!
        library.functions.objectSetExternalData(object, id_utf, data_ptr, data_len, buffer_type, null);

        return OK;
    }
};

const RnboPreset = struct {};
