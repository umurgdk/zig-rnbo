const std = @import("std");
const types = @import("types.zig");
const options = @import("options");

const Number = if (options.use_f32) f32 else f64;
const SampleType = if (options.use_f32) f32 else f64;

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
    objectPrepareToProcess: *const fn (obj: *Object, sample_rate: usize, buffer_frames: usize) callconv(.c) void,
    objectProcess: *const fn (obj: *Object, inputs: [*c]const [*c]SampleType, inputs_len: usize, outputs: [*c]const [*c]SampleType, outputs_len: usize, num_frames: usize) callconv(.c) void,
    objectProcessInterleaved: *const fn (obj: *Object, input: [*c]SampleType, input_channels: usize, output: [*c]SampleType, output_channels: usize, num_frames: usize) callconv(.c) void,
    objectSetPreset: *const fn (obj: *Object, preset: *Preset) callconv(.c) void,
    objectScheduleMidiEvent: *const fn (obj: *Object, time_ms: f64, port: usize, data: [*c]const u8, data_len: usize) callconv(.c) void,

    objectGetParameterIndexForId: *const fn (obj: *Object, id: [*c]const u8) callconv(.c) ParameterIndex,
    objectGetParameterValue: *const fn (obj: *Object, parameter_index: ParameterIndex) callconv(.c) Number,
    objectSetParameterValue: *const fn (obj: *Object, parameter_index: ParameterIndex, value: Number) callconv(.c) void,
    objectSetParameterValueTime: *const fn (obj: *Object, parameter_index: ParameterIndex, value: Number, time_ms: f64) callconv(.c) void,

    objectSetExternalData: *const fn (obj: *Object, id: [*c]const u8, data: [*c]u8, data_size: usize, buffer_type: BufferType, release_cb: ?ExternalDataReleaseCallback) callconv(.c) void,

    presetListFromMemory: *const fn (data: [*c]const u8) callconv(.c) *PresetList,
    presetListDestroy: *const fn (self: *PresetList) callconv(.c) void,
    presetListPresetWithName: *const fn (self: *PresetList, name: [*c]const u8) callconv(.c) *Preset,
};

pub fn loadLibrary(path: [:0]const u8) !Library {
    var handle = try std.DynLib.openZ(path);

    var functions: Functions = undefined;
    const lookup_fields = std.meta.fields(Functions);
    inline for (lookup_fields) |field| {
        @field(functions, field.name) = handle.lookup(field.type, "rnbo_" ++ field.name) orelse {
            std.log.err("library ({s}): {s}", .{ path, std.c.dlerror() orelse "" });
            return error.RnboLibraryMissingSymbol;
        };
    }

    return Library{
        .handle = handle,
        .functions = functions,
        .timestamp = 0,
    };
}

pub const Object = opaque {};
pub const Preset = opaque {};
pub const PresetList = opaque {};
