const std = @import("std");
const types = @import("types.zig");

pub const ParameterIndex = types.ParameterIndex;
pub const BufferType = types.BufferType;
pub const ExternalDataReleaseCallback = types.ExternalDataReleaseCallback;

pub const Library = struct {
    handle: std.DynLib,
    functions: Functions,
    timestamp: i128,
};

pub const Functions = extern struct {
    objectNew: *const fn () callconv(.c) *Object,
    objectInitialize: *const fn (obj: *Object) callconv(.c) void,
    objectDestroy: *const fn (obj: *Object) callconv(.c) void,
    objectPrepareToProcess: *const fn (obj: *Object) callconv(.c) void,
    objectSetPreset: *const fn (obj: *Object, preset: *Preset) callconv(.c) void,
    objectScheduleMidiEvent: *const fn (obj: *Object, time_ms: f64, port: usize, data: [*c]const u8, data_len: usize) callconv(.c) void,
    objectProcess: *const fn (obj: *Object, inputs: [*c]const [*c]f64, inputs_len: usize, outputs: [*c]const [*c]f64, outputs_len: usize, num_frames: usize) callconv(.c) void,

    objectGetParameterIndexForId: *const fn (obj: *Object, id: [*c]const u8) callconv(.c) ParameterIndex,
    objectGetParameterValue: *const fn (obj: *Object, parameter_index: ParameterIndex) callconv(.c) f64,
    objectSetParameterValue: *const fn (obj: *Object, parameter_index: ParameterIndex, value: f64) callconv(.c) void,
    objectSetParameterValueTime: *const fn (obj: *Object, parameter_index: ParameterIndex, value: f64, time_ms: f64) callconv(.c) void,

    objectSetExternalData: *const fn (obj: *Object, id: [*c]const u8, data: [*c]u8, data_size: usize, buffer_type: BufferType, release_cb: ?ExternalDataReleaseCallback) callconv(.c) void,

    presetListFromMemory: *const fn (data: [*c]const u8) callconv(.c) *PresetList,
    presetListDestroy: *const fn (self: *PresetList) callconv(.c) void,
    presetListPresetWithName: *const fn (self: *PresetList, name: [*c]const u8) *Preset,
};

pub fn loadLibrary(path: [:0]const u8) !Library {
    _ = path;
    @panic("TODO");
}

pub const Object = opaque {};
pub const Preset = opaque {};
pub const PresetList = opaque {};
