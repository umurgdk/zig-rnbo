const std = @import("std");
const types = @import("types.zig");
const options = @import("options");

const log = std.log.scoped(.rnbo);

pub const Patch = @import("patch.zig").Patch;

const Number = if (options.use_f32) f32 else f64;
const SampleType = if (options.use_f32) f32 else f64;

pub const ParameterIndex = types.ParameterIndex;
pub const BufferType = types.BufferType;
pub const ExternalDataReleaseCallback = types.ExternalDataReleaseCallback;

extern fn rnbo_objectNew() callconv(.c) *Object;
extern fn rnbo_objectInitialize(obj: *Object) callconv(.c) void;
extern fn rnbo_objectDestroy(obj: *Object) callconv(.c) void;
extern fn rnbo_objectPrepareToProcess(obj: *Object, sample_rate: usize, chunk_size: usize) callconv(.c) void;
extern fn rnbo_objectSetPreset(obj: *Object, preset: *Preset) callconv(.c) void;
extern fn rnbo_objectScheduleMidiEvent(obj: *Object, time_ms: f64, port: usize, data: [*c]const u8, data_len: usize) callconv(.c) void;
extern fn rnbo_objectProcess(obj: *Object, inputs: [*c]const [*c]SampleType, inputs_len: usize, outputs: [*c]const [*c]SampleType, outputs_len: usize, num_frames: usize) callconv(.c) void;
extern fn rnbo_objectProcessInterleaved(obj: *Object, input: [*c]SampleType, input_channels: usize, output: [*c]SampleType, output_channels: usize, num_frames: usize) callconv(.c) void;

extern fn rnbo_objectGetParameterIndexForId(obj: *Object, id: [*c]const u8) callconv(.c) ParameterIndex;
extern fn rnbo_objectGetParameterValue(obj: *Object, parameter_index: ParameterIndex) callconv(.c) Number;
extern fn rnbo_objectSetParameterValue(obj: *Object, parameter_index: ParameterIndex, value: Number) callconv(.c) void;
extern fn rnbo_objectSetParameterValueTime(obj: *Object, parameter_index: ParameterIndex, value: Number, time_ms: f64) callconv(.c) void;

extern fn rnbo_objectSetExternalData(obj: *Object, id: [*c]const u8, data: [*c]u8, data_size: usize, buffer_type: BufferType, release_cb: ?ExternalDataReleaseCallback) callconv(.c) void;

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

    pub fn process(obj: *Object, inputs: ?[]const [*]SampleType, outputs: ?[]const [*]SampleType, num_frames: usize) void {
        const inputs_ptr: [*c]const [*c]SampleType = if (inputs) |in| @ptrCast(in.ptr) else null;
        const inputs_len = if (inputs) |in| in.len else 0;

        const outputs_ptr: [*c]const [*c]SampleType = if (outputs) |out| @ptrCast(out.ptr) else null;
        const outputs_len = if (outputs) |out| out.len else 0;

        rnbo_objectProcess(obj, inputs_ptr, inputs_len, outputs_ptr, outputs_len, num_frames);
    }

    pub fn processInterleaved(obj: *Object, input: ?[*]SampleType, input_channels: usize, output: ?[*]SampleType, output_channels: usize, num_frames: usize) void {
        const input_ptr: [*c]const SampleType = if (input) |in| @ptrCast(in) else null;
        const output_ptr: [*c]SampleType = if (output) |out| @ptrCast(out) else null;

        rnbo_objectProcessInterleaved(obj, input_ptr, output_ptr, num_frames);
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
