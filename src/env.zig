pub const thread_stack_size: u32 = switch (@import("builtin").mode) {
    .Debug => 64 * 1024,
    .ReleaseSafe => 16 * 1024,
    .ReleaseFast, .ReleaseSmall => 4 * 1024,
};

pub var arbiter: horizon.AddressArbiter = .none;
pub var codec: Codec = undefined;

pub var ctx: [6]Context = undefined;
pub var ctx_stack_tls: [6][thread_stack_size]u8 align(horizon.heap.page_size) = undefined;

const Codec = @import("Codec.zig");
const Context = @import("Context.zig");

const zitrus = @import("zitrus");
const horizon = zitrus.horizon;
