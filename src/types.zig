const options = @import("options");

// Must match RNBO::number in rnbo_export.cpp (float when -DRNBO_USE_FLOAT32 is
// set at .so build time, double otherwise). Controlled by the same build flag
// so the BufferType struct layout stays ABI-compatible on both sides.
const Number = if (options.use_f32) f32 else f64;

pub const ParameterIndex = c_int;
pub const BufferType = extern struct {
    tag: Tag,
    channels: u32,
    samplerate: Number,

    pub const Tag = enum(c_uint) {
        float32,
        float64,
        untyped,
    };
};

pub const ExternalDataReleaseCallback = *const fn (id: [*c]const u8, address: [*c]u8, userdata: ?*anyopaque) callconv(.c) void;
