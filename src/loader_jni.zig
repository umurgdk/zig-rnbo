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
        const object_instance = RnboObject.construct(env, this, object) catch return null;

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

const RnboObject = struct {
    pub const Class = android.defineClass(PACKAGE_NAME ++ ".RnboObject");

    const library_prop = android.defineInstanceProperty(Class, "library", RnboLibrary.Class);
    const handle_prop = android.defineInstanceProperty(Class, "handle", jni.jlong);

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

    pub fn construct(env: jni.JNIEnv, library_object: jni.jobject, rnbo_object: *loader.Object) !jni.jobject {
        const class = try Class.get(env);
        const constructor = try constructor_method.getMethodId(env);

        const object_handle: jni.jlong = @bitCast(@intFromPtr(rnbo_object));
        const object = env.newObject(class, constructor, &jni.toJValues(.{ library_object, object_handle }));
        return object;
    }

    pub fn initialize(cenv: *jni.cEnv, this: jni.jobject) callconv(.c) void {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return;
        const object = getObject(env, this) catch return;
        library.functions.objectInitialize(object);
    }

    pub fn destroy(cenv: *jni.cEnv, this: jni.jobject) callconv(.c) void {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return;
        const object = getObject(env, this) catch return;
        library.functions.objectDestroy(object);
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

        // TODO(umur): Release callback?!?!?!?!
        library.functions.objectSetExternalData(object, id_utf, data_ptr, @intCast(data_size), buffer_type, null);
        std.log.debug("AudioBuffer is set on RNBO::Object", .{});
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

        // TODO(umur): Release callback?!?!?!?!
        library.functions.objectSetExternalData(object, id_utf, data_ptr, data_len, buffer_type, null);
        std.log.debug("AudioBuffer is set on RNBO::Object", .{});
    }

    pub fn setPreset(cenv: *jni.cEnv, this: jni.jobject, preset_object: jni.jobject) callconv(.c) void {
        const env = jni.JNIEnv.warp(cenv);
        const library = getLibrary(env, this) catch return;
        const object = getObject(env, this) catch return;
        const preset = RnboPreset.getPreset(env, preset_object) catch return;
        library.functions.objectSetPreset(object, preset);
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
