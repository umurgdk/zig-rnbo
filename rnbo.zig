const std = @import("std");

const log = std.log.scoped(.rnbo);

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

pub const Patch = struct {
    object: *Object,
    params_namemap: std.StringArrayHashMapUnmanaged(ParameterIndex),
    params_definitions: []ParameterDefinition,
    state: std.StringHashMapUnmanaged(f32),
    params_arena: std.heap.ArenaAllocator,

    pub fn init(object: *Object, allocator: std.mem.Allocator) Patch {
        return Patch{
            .object = object,
            .params_namemap = .{},
            .params_definitions = &[_]ParameterDefinition{},
            .state = .{},
            .params_arena = .init(allocator),
        };
    }

    pub fn destroy(patch: *Patch) void {
        patch.object.destroy();
        patch.params_arena.deinit();
    }

    pub fn loadDescription(patch: *Patch, params_json: []const u8) !void {
        const allocator = patch.params_arena.allocator();

        const json_opts = std.json.ParseOptions{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        };

        const description = try std.json.parseFromSliceLeaky(
            struct { parameters: []ParameterDefinition },
            allocator,
            params_json,
            json_opts,
        );

        patch.params_definitions = description.parameters;
        patch.params_namemap.clearRetainingCapacity();
        try patch.params_namemap.ensureTotalCapacity(allocator, @intCast(patch.params_definitions.len));
        try patch.state.ensureTotalCapacity(allocator, @intCast(patch.params_definitions.len));

        for (patch.params_definitions) |*param| {
            patch.params_namemap.putAssumeCapacity(param.paramId, param.index);
            patch.state.putAssumeCapacity(param.paramId, @floatCast(param.initialValue));
        }
    }

    pub fn setParam(patch: *Patch, name: []const u8, value: anytype) void {
        const param_index = patch.params_namemap.get(name) orelse {
            log.warn("setting undefined parameter: {s}", .{name});
            return;
        };

        patch.state.getPtr(name).?.* = @floatCast(value);
        patch.object.setParameterValue(param_index, @floatCast(value));
    }

    pub fn setParamTime(patch: *Patch, name: []const u8, value: anytype, time: f64) void {
        const param_index = patch.params_namemap.get(name) orelse {
            log.warn("setting undefined parameter: {s}", .{name});
            return;
        };

        patch.state.getPtr(name).?.* = @floatCast(value);
        patch.object.setParameterValueTime(param_index, @floatCast(value), time);
    }

    pub fn getParam(patch: *Patch, name: []const u8) f32 {
        const value = patch.state.get(name) orelse {
            log.warn("reading undefined parameter state: {s}", .{name});
            return 0;
        };

        return value;
    }

    pub fn getParamPtr(patch: *Patch, name: []const u8) *f32 {
        const value = patch.state.getPtr(name) orelse {
            std.debug.panic("getting pointer to undefined parameter state: {s}", .{name});
        };

        return value;
    }

    pub fn readParam(patch: *Patch, name: []const u8) void {
        const param_index = patch.params_namemap.get(name) orelse {
            log.warn("reading undefined parameter: {s}", .{name});
            return 0;
        };

        const value = patch.object.getParameterValue(param_index);
        patch.state.get(name).?.* = value;
    }

    pub fn writeParam(patch: *Patch, name: []const u8) void {
        const param_index = patch.params_namemap.get(name) orelse {
            log.warn("writing undefined parameter: {s}", .{name});
            return;
        };

        const param_value = patch.state.get(name) orelse {
            log.warn("writing undefined parameter: {s}", .{name});
            return;
        };

        patch.object.setParameterValue(param_index, @floatCast(param_value));
    }

    pub fn setExternalData(patch: *Patch, id: [:0]const u8, data: []u8, buffer_type: BufferType, release_cb: ?ExternalDataReleaseCallback) void {
        rnbo_objectSetExternalData(patch.object, id.ptr, data.ptr, data.len, buffer_type, release_cb);
    }
};

pub const ParameterDefinition = struct {
    type: []u8,
    index: ParameterIndex,
    name: []u8,
    paramId: []u8,
    minimum: f64,
    maximum: f64,
    exponent: f64,
    initialValue: f64,
    steps: f64,
};
