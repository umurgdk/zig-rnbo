const std = @import("std");
const android = @import("android");
const options = @import("options");

const loader = @import("loader.zig");
const jni = android.jni;

const ErrorCode = std.meta.Int(.unsigned, @bitSizeOf(anyerror));
const OK: ErrorCode = 0;

const PACKAGE_NAME = options.java_package;
const LibraryHandle = jni.jlong;

const Number = if (options.use_f32) jni.jfloat else jni.jdouble;
const NumberArray = if (options.use_f32) jni.jfloatArray else jni.jdoubleArray;
const SampleType = if (options.use_f32) jni.jfloat else jni.jdouble;
const SampleArray = if (options.use_f32) jni.jfloatArray else jni.jdoubleArray;

pub const panic = android.panic.handler;
pub const std_options: std.Options = .{
    .logFn = android.log.StdLogger("RnboLoader").stdLogFn,
};

comptime {
    jni.exportJNI(RnboLoader.Class.name, RnboLoader);
    jni.exportJNI(options.java_package ++ ".RnboLibrary", RnboLibrary);
    jni.exportJNI(options.java_package ++ ".RnboObject", RnboObject);
    jni.exportJNI(options.java_package ++ ".RnboPresetList", RnboPresetList);
    jni.exportJNI(options.java_package ++ ".RnboEventHandler", RnboEventHandler);
}

const allocator = std.heap.smp_allocator;

const RnboLoader = struct {
    pub const Class = android.defineClass(PACKAGE_NAME ++ ".RnboLoader");
    pub fn loadLibrary(cenv: *jni.cEnv, _: jni.jclass, path_string: jni.jstring) callconv(.c) jni.jobject {
        const env = jni.JNIEnv.warp(cenv);

        var path_copied = false;

        const path_ptr = env.getStringUTFChars(path_string, &path_copied);
        defer env.releaseStringUTFChars(path_string, path_ptr);

        const path = path_ptr[0..std.mem.len(path_ptr) :0];
        std.log.debug("loading rnbo library at {s}", .{path});

        const library = allocator.create(loader.Library) catch |err| {
            _ = android.exception.throwZig(env, err, @errorReturnTrace(), "failed to allocate memory for Library", .{});
            return null;
        };

        library.* = loader.loadLibrary(path) catch |err| {
            _ = android.exception.throwZig(env, err, @errorReturnTrace(), "failed to load library at {s}", .{path});
            allocator.destroy(library);
            return null;
        };

        const library_object = RnboLibrary.construct(env, library) catch return null;
        return library_object;
    }
};

const RnboLibrary = struct {
    pub const Class = android.defineClass(PACKAGE_NAME ++ ".RnboLibrary");

    const handle_prop = android.defineInstanceProperty(Class, "handle", jni.jlong);
    const constructor_method = android.defineMethod(Class, "<init>", void, .{jni.jlong});

    fn getLibrary(env: jni.JNIEnv, this: jni.jobject) !*loader.Library {
        const handle = try handle_prop.get(env, this);
        const address: usize = @bitCast(handle);
        const library: *loader.Library = @ptrFromInt(address);
        return library;
    }

    pub fn construct(env: jni.JNIEnv, library: *loader.Library) !jni.jobject {
        const class = try Class.get(env);
        const constructor = try constructor_method.getMethodId(env);
        const lib_address: usize = @intFromPtr(library);
        const lib_handle: jni.jlong = @bitCast(lib_address);

        const instance = env.newObject(class, constructor, &jni.toJValues(lib_handle));
        return instance;
    }

    pub fn newObject(cenv: *jni.cEnv, this: jni.jobject) callconv(.c) jni.jobject {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return null;

        const object = library.functions.objectNew();
        const object_instance = RnboObject.construct(env, this, object, library) catch return null;

        return object_instance;
    }

    pub fn loadPresetListFromMemory(cenv: *jni.cEnv, this: jni.jobject, byte_buffer: jni.jobject) callconv(.c) jni.jobject {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return null;

        const buff_addr = env.getDirectBufferAddress(byte_buffer);
        const buff_ptr: [*]u8 = @ptrFromInt(buff_addr);

        const preset_list = library.functions.presetListFromMemory(buff_ptr);
        const preset_list_object = RnboPresetList.construct(env, this, preset_list) catch return null;
        return preset_list_object;
    }
};

const ReleaseCallbackContext = struct {
    jvm: jni.JavaVM,
    this: jni.jobject,
};

const RnboObject = struct {
    pub const Instance = jni.jobject;
    pub const Class = android.defineClass(PACKAGE_NAME ++ ".RnboObject");

    const library_prop = android.defineInstanceProperty(Class, "library", RnboLibrary.Class);
    const handle_prop = android.defineInstanceProperty(Class, "handle", jni.jlong);
    const release_ctx_prop = android.defineInstanceProperty(Class, "releaseCallbackHandle", jni.jlong);

    const on_buffer_released = android.defineMethod(Class, "onBufferReleased", void, .{jni.jlong});

    const constructor_method = android.defineMethod(Class, "<init>", void, .{ RnboLibrary.Class, jni.jlong });

    pub fn getLibrary(env: jni.JNIEnv, this: jni.jobject) !*loader.Library {
        const lib_object = try library_prop.get(env, this);
        return RnboLibrary.getLibrary(env, lib_object);
    }

    pub fn getObject(env: jni.JNIEnv, this: jni.jobject) !*loader.Object {
        const obj_handle = try handle_prop.get(env, this);
        const obj_address: usize = @bitCast(obj_handle);
        const object: *loader.Object = @ptrFromInt(obj_address);
        return object;
    }

    pub fn construct(env: jni.JNIEnv, library_object: jni.jobject, rnbo_object: *loader.Object, library: *loader.Library) !jni.jobject {
        const class = try Class.get(env);
        const constructor = try constructor_method.getMethodId(env);

        const object_handle: jni.jlong = @bitCast(@intFromPtr(rnbo_object));
        const object = env.newObject(class, constructor, &jni.toJValues(.{ library_object, object_handle }));

        library.functions.objectInitialize(rnbo_object);

        const ctx = try allocator.create(ReleaseCallbackContext);
        ctx.this = env.newGlobalRef(object);
        env.getJavaVM(&ctx.jvm) catch {
            allocator.destroy(ctx);
            return object;
        };
        release_ctx_prop.set(env, object, @bitCast(@intFromPtr(ctx))) catch {
            env.deleteGlobalRef(ctx.this);
            allocator.destroy(ctx);
        };

        return object;
    }

    fn externalDataReleaseCallback(_: [*c]const u8, address: [*c]u8, userdata: ?*anyopaque) callconv(.c) void {
        const ctx: *ReleaseCallbackContext = @ptrCast(@alignCast(userdata orelse {
            std.log.err("release callback: userdata is null", .{});
            return;
        }));

        var cenv: ?*jni.cEnv = undefined;
        ctx.jvm.attachCurrentThread(&cenv, null) catch |err| {
            std.log.err("release callback: attachCurrentThread failed: {}", .{err});
            return;
        };

        const env = jni.JNIEnv.warp(cenv.?);
        const addr: jni.jlong = @bitCast(@as(usize, @intFromPtr(address)));
        on_buffer_released.call(env, ctx.this, .{addr}) catch |err| {
            std.log.err("release callback: onBufferReleased call failed: {}", .{err});
        };

        if (env.exceptionCheck()) {
            std.log.err("release callback: JNI exception in onBufferReleased", .{});
            env.exceptionDescribe();
            env.exceptionClear();
        }
    }

    pub fn destroy(cenv: *jni.cEnv, this: jni.jobject) callconv(.c) void {
        const env = jni.JNIEnv.warp(cenv);

        const library = getLibrary(env, this) catch return;
        const object = getObject(env, this) catch return;
        library.functions.objectDestroy(object);

        // Free release callback context AFTER objectDestroy, since RNBO's
        // destructor fires release callbacks for all external data refs.
        const ctx_handle = release_ctx_prop.get(env, this) catch 0;
        if (ctx_handle != 0) {
            const ctx: *ReleaseCallbackContext = @ptrFromInt(@as(usize, @bitCast(ctx_handle)));
            env.deleteGlobalRef(ctx.this);
            allocator.destroy(ctx);
        }
    }

    pub fn prepareToProcess(cenv: *jni.cEnv, this: jni.jobject, sample_rate: jni.jlong, buffer_frames: jni.jlong) callconv(.c) void {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return;
        const object = getObject(env, this) catch return;

        library.functions.objectPrepareToProcess(
            object,
            @intCast(sample_rate),
            @intCast(buffer_frames),
        );
    }

    pub fn process(cenv: *jni.cEnv, this: jni.jobject, output_chan1_arr: SampleArray, output_chan2_arr: SampleArray, num_frames: jni.jlong) callconv(.c) void {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return;
        const object = getObject(env, this) catch return;

        var output_chan1_copied = false;
        const output_chan1_ptr = env.getPrimitiveArrayElements(SampleType, output_chan1_arr, &output_chan1_copied);
        defer env.releasePrimitiveArrayElements(SampleType, output_chan1_arr, output_chan1_ptr, .JNIDefault);

        var output_chan2_copied = false;
        const output_chan2_ptr = env.getPrimitiveArrayElements(SampleType, output_chan2_arr, &output_chan2_copied);
        defer env.releasePrimitiveArrayElements(SampleType, output_chan2_arr, output_chan2_ptr, .JNIDefault);

        const outputs = [2][*]SampleType{ output_chan1_ptr, output_chan2_ptr };
        const outputs_ptr: [*c]const [*c]SampleType = @ptrCast(&outputs);

        library.functions.objectProcess(object, null, 0, outputs_ptr, outputs.len, @intCast(num_frames));
    }

    pub fn processInterleaved(
        cenv: *jni.cEnv,
        this: jni.jobject,
        input_buff: jni.jobject,
        input_channels: jni.jint,
        output_buff: jni.jobject,
        output_channels: jni.jint,
        num_frames: jni.jlong,
    ) callconv(.c) void {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return;
        const object = getObject(env, this) catch return;

        if (@intFromPtr(library) == 0 or @intFromPtr(object) == 0) {
            std.log.err("Object or Library is null", .{});
            return;
        }

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

        const result = library.functions.objectProcessInterleaved(
            object,
            input_ptr,
            @intCast(input_channels),
            output_ptr,
            @intCast(output_channels),
            @intCast(num_frames),
        );

        if (result < 0) {
            android.exception.throw(env, "processInterleaved");
        }
    }

    pub fn getParameterIndexById(cenv: *jni.cEnv, this: jni.jobject, id: jni.jstring) callconv(.c) jni.jint {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return 0;
        const object = getObject(env, this) catch return 0;

        var id_copied = false;
        const id_utf = env.getStringUTFChars(id, &id_copied);
        defer env.releaseStringUTFChars(id, id_utf);

        const index = library.functions.objectGetParameterIndexForId(object, id_utf);
        if (index < 0) {
            android.exception.throwZig(env, error.ParamterNotFound, null, "failed to get paramter index for id: {s}", .{id_utf});
            return -1;
        }

        return index;
    }

    pub fn getParameterValue(cenv: *jni.cEnv, this: jni.jobject, param_index: jni.jint) callconv(.c) Number {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return 0;
        const object = getObject(env, this) catch return 0;

        const value = library.functions.objectGetParameterValue(object, @intCast(param_index));
        return value;
    }

    pub fn setParameterValue(cenv: *jni.cEnv, this: jni.jobject, param_index: jni.jint, value: Number) callconv(.c) void {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return;
        const object = getObject(env, this) catch return;

        library.functions.objectSetParameterValue(object, param_index, value);
    }

    pub fn setParameterValueTime(cenv: *jni.cEnv, this: jni.jobject, param_index: jni.jint, value: Number, time_ms: f64) callconv(.c) void {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return;
        const object = getObject(env, this) catch return;
        library.functions.objectSetParameterValueTime(object, param_index, value, time_ms);
    }

    pub fn setExternalDataNativeMemory(cenv: *jni.cEnv, this: jni.jobject, id: jni.jstring, data_address: jni.jlong, data_size: jni.jlong, buffer_type_tag: jni.jint, buffer_type_channels: jni.jint, buffer_type_samplerate: jni.jlong) callconv(.c) void {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return;
        const object = getObject(env, this) catch return;

        const data_ptr: [*]u8 = @ptrFromInt(@as(usize, @bitCast(data_address)));

        var id_copied = false;
        const id_utf = env.getStringUTFChars(id, &id_copied);
        defer env.releaseStringUTFChars(id, id_utf);

        const buffer_type = loader.BufferType{
            .tag = @enumFromInt(buffer_type_tag),
            .channels = @intCast(buffer_type_channels),
            .samplerate = @floatFromInt(buffer_type_samplerate),
        };

        const ctx_handle = release_ctx_prop.get(env, this) catch 0;
        const ctx_ptr: ?*anyopaque = if (ctx_handle != 0)
            @ptrFromInt(@as(usize, @bitCast(ctx_handle)))
        else
            null;

        library.functions.objectSetExternalData(object, id_utf, data_ptr, @intCast(data_size), buffer_type, externalDataReleaseCallback, ctx_ptr);
        std.log.warn("setExternalData: done", .{});
    }

    pub fn setExternalData(cenv: *jni.cEnv, this: jni.jobject, id: jni.jstring, data_arr: jni.jbyteArray, buffer_type_tag: jni.jint, buffer_type_channels: jni.jint, buffer_type_samplerate: jni.jlong) callconv(.c) void {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return;
        const object = getObject(env, this) catch return;

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

        // Cannot use release callback here: JNI array elements are released by
        // defer above before RNBO's audio thread would call the callback.
        library.functions.objectSetExternalData(object, id_utf, data_ptr, data_len, buffer_type, null, null);
        std.log.debug("AudioBuffer is set on RNBO::Object", .{});
    }

    pub fn setPreset(cenv: *jni.cEnv, this: jni.jobject, preset_object: jni.jobject) callconv(.c) void {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return;
        const object = getObject(env, this) catch return;
        const preset = RnboPreset.getPreset(env, preset_object) catch return;
        library.functions.objectSetPreset(object, preset);
    }

    pub fn transportStart(cenv: *jni.cEnv, this: jni.jobject) callconv(.c) void {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return;
        const object = getObject(env, this) catch return;
        library.functions.objectTransportStart(object);
    }

    pub fn transportStop(cenv: *jni.cEnv, this: jni.jobject) callconv(.c) void {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return;
        const object = getObject(env, this) catch return;
        library.functions.objectTransportStop(object);
    }

    pub fn sendMessage(cenv: *jni.cEnv, this: jni.jobject, inport: jni.jstring) callconv(.c) void {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return;
        const object = getObject(env, this) catch return;

        var inport_bytes_copied = false;
        const inport_utf = env.getStringUTFChars(inport, &inport_bytes_copied);
        defer env.releaseStringUTFChars(inport, inport_utf);

        if (!library.functions.objectSendMessage(object, inport_utf)) {
            android.exception.throw(env, "Failed to send message");
            return;
        }
    }

    pub fn sendMessageWithNumber(cenv: *jni.cEnv, this: jni.jobject, inport: jni.jstring, value: Number) callconv(.c) void {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return;
        const object = getObject(env, this) catch return;

        var inport_bytes_copied = false;
        const inport_utf = env.getStringUTFChars(inport, &inport_bytes_copied);
        defer env.releaseStringUTFChars(inport, inport_utf);

        if (!library.functions.objectSendMessageWithNumber(object, inport_utf, value)) {
            android.exception.throw(env, "Failed to send message");
            return;
        }
    }

    pub fn sendMessageWithList(cenv: *jni.cEnv, this: jni.jobject, inport: jni.jstring, values_arr: NumberArray) callconv(.c) void {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return;
        const object = getObject(env, this) catch return;

        var inport_bytes_copied = false;
        const inport_utf = env.getStringUTFChars(inport, &inport_bytes_copied);
        defer env.releaseStringUTFChars(inport, inport_utf);

        var values_copied = false;
        const values_ptr = env.getPrimitiveArrayElements(Number, values_arr, &values_copied);
        defer env.releasePrimitiveArrayElements(Number, values_arr, values_ptr, .JNIAbort);
        const values_len: usize = @intCast(env.getArrayLength(values_arr));

        if (!library.functions.objectSendMessageWithList(object, inport_utf, values_ptr, values_len)) {
            android.exception.throw(env, "Failed to send message");
            return;
        }
    }
};

const RnboPresetList = struct {
    const Class = android.defineClass(PACKAGE_NAME ++ ".RnboPresetList");

    const library_prop = android.defineInstanceProperty(Class, "library", RnboLibrary.Class);
    const handle_prop = android.defineInstanceProperty(Class, "handle", jni.jlong);

    const constructor_method = android.defineMethod(Class, "<init>", void, .{ RnboLibrary.Class, jni.jlong });

    pub fn getLibrary(env: jni.JNIEnv, this: jni.jobject) !*loader.Library {
        const lib_obj = try library_prop.get(env, this);
        return RnboLibrary.getLibrary(env, lib_obj);
    }

    pub fn getPresetList(env: jni.JNIEnv, this: jni.jobject) !*loader.PresetList {
        const handle = try handle_prop.get(env, this);
        const address: usize = @bitCast(handle);
        const preset_list: *loader.PresetList = @ptrFromInt(address);
        return preset_list;
    }

    pub fn construct(env: jni.JNIEnv, library_object: jni.jobject, preset_list: *loader.PresetList) !jni.jobject {
        const class = try Class.get(env);
        const constructor = try constructor_method.getMethodId(env);

        const preset_list_addr = @intFromPtr(preset_list);
        const preset_list_handle: jni.jlong = @bitCast(preset_list_addr);

        const object = env.newObject(class, constructor, &jni.toJValues(.{ library_object, preset_list_handle }));
        return object;
    }

    pub fn destroy(cenv: *jni.cEnv, this: jni.jobject) callconv(.c) void {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return;
        const preset_list = getPresetList(env, this) catch return;
        library.functions.presetListDestroy(preset_list);
    }

    pub fn presetAtIndex(cenv: *jni.cEnv, this: jni.jobject, index: jni.jint) callconv(.c) jni.jobject {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return null;
        const preset_list = getPresetList(env, this) catch return null;

        const preset = library.functions.presetListPresetAtIndex(preset_list, @intCast(index));
        const preset_object = RnboPreset.construct(env, preset) catch return null;
        return preset_object;
    }

    pub fn presetWithName(cenv: *jni.cEnv, this: jni.jobject, name_string: jni.jstring) callconv(.c) jni.jobject {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return null;
        const preset_list = getPresetList(env, this) catch return null;

        var chars_copied = false;
        const name = env.getStringUTFChars(name_string, &chars_copied);
        defer env.releaseStringUTFChars(name_string, name);

        const preset = library.functions.presetListPresetWithName(preset_list, name);
        const preset_obj = RnboPreset.construct(env, preset) catch return null;
        return preset_obj;
    }
};

const RnboPreset = struct {
    const Class = android.defineClass(PACKAGE_NAME ++ ".RnboPreset");

    const handle_prop = android.defineInstanceProperty(Class, "handle", jni.jlong);
    const constructor_method = android.defineMethod(Class, "<init>", void, .{jni.jlong});

    pub fn getPreset(env: jni.JNIEnv, this: jni.jobject) !*loader.Preset {
        const preset_handle = try handle_prop.get(env, this);
        const preset_address: usize = @bitCast(preset_handle);
        const preset: *loader.Preset = @ptrFromInt(preset_address);
        return preset;
    }

    pub fn construct(env: jni.JNIEnv, preset: *loader.Preset) !jni.jobject {
        const class = try Class.get(env);
        const constructor = try constructor_method.getMethodId(env);
        const preset_address = @intFromPtr(preset);
        const preset_handle: jni.jlong = @bitCast(preset_address);
        const object = env.newObject(class, constructor, &jni.toJValues(.{preset_handle}));
        return object;
    }
};

const RnboEventHandler = struct {
    const Instance = jni.jobject;
    const Class = android.defineClass(PACKAGE_NAME ++ ".RnboEventHandler");

    const CallbackData = struct {
        jvm: jni.JavaVM,
        this: jni.jobject,
        tag_cache: std.StringArrayHashMapUnmanaged(jni.jstring),
    };

    const handle_prop = android.defineInstanceProperty(Class, "handle", jni.jlong);
    const rnbo_object_prop = android.defineInstanceProperty(Class, "rnboObject", RnboObject.Class);

    const on_bang_event = android.defineMethod(Class, "onBangEvent", void, .{android.types.string});
    const on_number_event = android.defineMethod(Class, "onNumberEvent", void, .{ android.types.string, Number });
    const on_error = android.defineMethod(Class, "onError", void, .{});

    pub fn getEventHandler(env: jni.JNIEnv, this: jni.jobject) !*loader.EventHandler {
        const handle = try handle_prop.get(env, this);
        const event_handler_address: usize = @bitCast(handle);
        const event_handler: *loader.EventHandler = @ptrFromInt(event_handler_address);
        return event_handler;
    }

    pub fn initialize(cenv: *jni.cEnv, this: jni.jobject) callconv(.c) void {
        const env = jni.JNIEnv.warp(cenv);
        const obj_instance = rnbo_object_prop.get(env, this) catch return;
        const rnbo_obj = RnboObject.getObject(env, obj_instance) catch return;
        const library = RnboObject.getLibrary(env, obj_instance) catch return;

        const callback_data = allocator.create(CallbackData) catch |err| {
            android.exception.throwZig(env, err, @errorReturnTrace(), "Failed to allocate RnboEventHandler callback data", .{});
            return;
        };

        callback_data.this = env.newGlobalRef(this);
        callback_data.tag_cache = .{};
        env.getJavaVM(&callback_data.jvm) catch |err| {
            return android.exception.throwZig(env, err, @errorReturnTrace(), "Failed to obtain jvm pointer", .{});
        };

        const event_handler = library.functions.newEventHandler(rnbo_obj, .{
            .userinfo = callback_data,
            .onBangEvent = onBangEvent,
            .onNumberEvent = onNumberEvent,
            .onError = onError,
        }) orelse {
            return android.exception.throw(env, "Failed to create RnboEventHandler");
        };

        handle_prop.set(env, this, @bitCast(@intFromPtr(event_handler))) catch return;
    }

    pub fn destroy(cenv: *jni.cEnv, this: jni.jobject) callconv(.c) void {
        const env = jni.JNIEnv.warp(cenv);
        const object_instance = rnbo_object_prop.get(env, this) catch return;
        const library = RnboObject.getLibrary(env, object_instance) catch return;
        const event_handler = getEventHandler(env, this) catch return;

        const callbacks = library.functions.eventHandlerGetCallbacks(event_handler);
        library.functions.destroyEventHandler(event_handler);

        const callback_data: *CallbackData = @ptrCast(@alignCast(callbacks.userinfo));
        allocator.destroy(callback_data);

        handle_prop.set(env, this, 0) catch return;
    }

    fn onBangEvent(userinfo: *anyopaque, object: *loader.Object, tag: u32) callconv(.c) void {
        const cb_data: *CallbackData = @ptrCast(@alignCast(userinfo));

        var cenv: ?*jni.cEnv = undefined;
        cb_data.jvm.attachCurrentThread(&cenv, null) catch @panic("failed to attach audio thread to jvm");

        const env = jni.JNIEnv.warp(cenv.?);
        const this = cb_data.this;

        const object_instance = rnbo_object_prop.get(env, this) catch return;
        const library = RnboObject.getLibrary(env, object_instance) catch return;

        const tag_cstr = library.functions.objectResolveTag(object, tag) orelse return;
        const tag_slice = std.mem.span(tag_cstr);
        if (cb_data.tag_cache.get(tag_slice)) |tag_jstr| {
            on_bang_event.call(env, cb_data.this, .{tag_jstr}) catch |err| {
                std.log.err("Failed to call instance method onBangEvent: {}", .{err});
                return;
            };
        } else {
            const tag_jstr = env.newStringUTF(tag_slice);
            const tag_jstr_global = env.newGlobalRef(tag_jstr);
            cb_data.tag_cache.put(allocator, tag_slice, tag_jstr_global) catch |err| {
                std.log.err("Failed to put tag string into cache: {}", .{err});
            };

            on_bang_event.call(env, cb_data.this, .{tag_jstr_global}) catch |err| {
                std.log.err("Failed to call instance method onBangEvent: {}", .{err});
                return;
            };
        }

        if (env.exceptionCheck()) {
            std.log.err("JVM EventHandler onBangEvent throw exception", .{});
            env.exceptionDescribe();
        }
    }

    fn onNumberEvent(userinfo: *anyopaque, object: *loader.Object, tag: u32, value: Number) callconv(.c) void {
        const cb_data: *CallbackData = @ptrCast(@alignCast(userinfo));

        var cenv: ?*jni.cEnv = undefined;
        cb_data.jvm.attachCurrentThread(&cenv, null) catch @panic("failed to attach audio thread to jvm");

        const env = jni.JNIEnv.warp(cenv.?);
        const this = cb_data.this;

        const object_instance = rnbo_object_prop.get(env, this) catch return;
        const library = RnboObject.getLibrary(env, object_instance) catch return;

        const tag_cstr = library.functions.objectResolveTag(object, tag) orelse return;
        const tag_slice = std.mem.span(tag_cstr);

        const tag_jstr = cb_data.tag_cache.get(tag_slice) orelse brk: {
            const tag_jstr = env.newStringUTF(tag_slice);
            const tag_jstr_global = env.newGlobalRef(tag_jstr);
            cb_data.tag_cache.put(allocator, tag_slice, tag_jstr_global) catch |err| {
                std.log.err("Failed to put tag string into cache: {}", .{err});
            };

            break :brk tag_jstr_global;
        };

        on_number_event.call(env, cb_data.this, .{ tag_jstr, value }) catch |err| {
            std.log.err("Failed to call instance method onNumberEvent: {}", .{err});
            return;
        };

        if (env.exceptionCheck()) {
            std.log.err("JVM EventHandler onBangEvent throw exception", .{});
            env.exceptionDescribe();
        }
    }

    fn onError(userinfo: *anyopaque, object: *loader.Object) callconv(.c) void {
        _ = object;
        const cb_data: *CallbackData = @ptrCast(@alignCast(userinfo));

        var cenv: ?*jni.cEnv = undefined;
        cb_data.jvm.attachCurrentThread(&cenv, null) catch @panic("failed to attach audio thread to jvm");

        const env = jni.JNIEnv.warp(cenv.?);
        on_error.call(env, cb_data.this, .{}) catch |err| {
            std.log.err("Failed to call instance method onError: {}", .{err});
            return;
        };

        if (env.exceptionCheck()) {
            std.log.err("JVM EventHandler onBangEvent throw exception", .{});
            env.exceptionDescribe();
        }
    }
};

/// Exported C function for direct audio processing from Oboe C++ callback.
/// Called from libnvaudio_oboe.so via dlsym — no JNI involved.
export fn rnbo_loader_process_interleaved(
    library_ptr: usize,
    object_ptr: usize,
    output: [*]SampleType,
    output_channels: usize,
    num_frames: usize,
) callconv(.c) c_int {
    const library: *loader.Library = @ptrFromInt(library_ptr);
    const object: *loader.Object = @ptrFromInt(object_ptr);
    return library.functions.objectProcessInterleaved(
        object,
        null,
        0,
        output,
        output_channels,
        num_frames,
    );
}
