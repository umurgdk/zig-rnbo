const std = @import("std");

pub const BufferType = extern struct {
    tag: Tag,
    channels: u32,
    samplerate: f64,

    pub const Tag = enum(c_uint) {
        float32,
        float64,
        untyped,
    };
};

pub const ParameterIndex = c_int;

extern fn rnbo_objectNew() callconv(.c) *Object;
extern fn rnbo_objectInitialize(obj: *Object) callconv(.c) void;
extern fn rnbo_objectDestroy(obj: *Object) callconv(.c) void;
extern fn rnbo_objectPrepareToProcess(obj: *Object, sample_rate: usize, chunk_size: usize) callconv(.c) void;
extern fn rnbo_objectSetPreset(obj: *Object, preset: *Preset) callconv(.c) void;
extern fn rnbo_objectScheduleMidiEvent(obj: *Object, time_ms: f64, port: usize, data: [*c]const u8, data_len: usize) callconv(.c) void;
extern fn rnbo_objectProcess(obj: *Object, inputs: [*c]const [*c]f64, inputs_len: usize, outputs: [*c]const [*c]f64, outputs_len: usize, num_frames: usize) callconv(.c) void;

extern fn rnbo_objectGetParameterIndexForId(obj: *Object, id: [*c]const u8) callconv(.c) ParameterIndex;
extern fn rnbo_objectGetParameterValue(obj: *Object, parameter_index: ParameterIndex) callconv(.c) f64;
extern fn rnbo_objectSetParameterValue(obj: *Object, parameter_index: ParameterIndex, value: f64) callconv(.c) void;
extern fn rnbo_objectSetParameterValueTime(obj: *Object, parameter_index: ParameterIndex, value: f64, time_ms: f64) callconv(.c) void;

extern fn rnbo_objectSetExternalData(obj: *Object, id: [*c]const u8, data: [*c]u8, data_size: usize, buffer_type: BufferType, release_cb: ?ExternalDataReleaseCallback) callconv(.c) void;

pub const ExternalDataReleaseCallback = *const fn (id: [*c]const u8, address: [*c]u8) callconv(.c) void;

pub const Object = opaque {
    pub const initialize = rnbo_objectInitialize;
    pub const destroy = rnbo_objectDestroy;
    pub const prepareToProcess = rnbo_objectPrepareToProcess;

    /// Takes the ownership of the preset, if possible do not use the preset anymore
    pub const setPreset = rnbo_objectSetPreset;

    pub const getParameterIndexForId = rnbo_objectGetParameterIndexForId;
    pub const getParameterValue = rnbo_objectGetParameterValue;
    pub const setParameterValue = rnbo_objectSetParameterValue;
    pub const setParameterValueTime = rnbo_objectSetParameterValueTime;

    pub fn scheduleMidiEvent(obj: *Object, time_ms: f64, port: usize, data: []const u8) void {
        rnbo_objectScheduleMidiEvent(obj, time_ms, port, data.ptr, data.len);
    }

    pub fn process(obj: *Object, inputs: ?[]const [*]f64, outputs: ?[]const [*]f64, num_frames: usize) void {
        const inputs_ptr: [*c]const [*c]f64 = if (inputs) |in| @ptrCast(in.ptr) else null;
        const inputs_len = if (inputs) |in| in.len else 0;

        const outputs_ptr: [*c]const [*c]f64 = if (outputs) |out| @ptrCast(out.ptr) else null;
        const outputs_len = if (outputs) |out| out.len else 0;

        rnbo_objectProcess(obj, inputs_ptr, inputs_len, outputs_ptr, outputs_len, num_frames);
    }

    pub fn setExternalData(obj: *Object, id: [:0]const u8, data: []u8, buffer_type: BufferType, release_cb: ?ExternalDataReleaseCallback) void {
        rnbo_objectSetExternalData(obj, id.ptr, data.ptr, data.len, buffer_type, release_cb);
    }
};

pub fn newObject() *Object {
    return rnbo_objectNew();
}

extern fn rnbo_presetListFromMemory(data: [*c]const u8) callconv(.c) *PresetList;
extern fn rnbo_presetListDestroy(self: *PresetList) callconv(.c) void;
extern fn rnbo_presetListPresetWithName(self: *PresetList, name: [*c]const u8) *Preset;

pub const PresetList = opaque {
    pub const destroy = rnbo_presetListDestroy;
    pub const presetWithName = rnbo_presetListPresetWithName;
};

pub fn presetListFromMemory(data: [:0]const u8) *PresetList {
    return rnbo_presetListFromMemory(data.ptr);
}

pub const Preset = opaque {};
