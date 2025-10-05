pub const ParameterIndex = c_int;
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

pub const ExternalDataReleaseCallback = *const fn (id: [*c]const u8, address: [*c]u8) callconv(.c) void;
