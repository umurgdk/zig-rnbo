const std = @import("std");
const types = @import("types.zig");
const root = @import("root");

const Object = root.Object;
const ParameterIndex = types.ParameterIndex;
const BufferType = types.BufferType;
const ExternalDataReleaseCallback = root.ExternalDataReleaseCallback;

const log = std.log.scoped(.rnbo);

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
