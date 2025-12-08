const std = @import("std");
const os = std.os;

pub const RingUserDataState = enum {
    accept,
    await_sock,
    await_conn,
    recv_client,
    send_upstream,
    recv_upstream,
    send_client,
    close,
};

pub const RingUserData = struct {
    state: RingUserDataState,
    client_fd: ?i32 = 0,
    upstream_fd: ?i32 = 0,
    upstream: []const u8,
    buffer: [1024]u8,
};

pub const EventRing = struct {
    ring: os.linux.IoUring,

    const Self = @This();

    pub fn init() !Self {
        const entries = 32;
        const flags = 0;
        const ring = try os.linux.IoUring.init(entries, flags);

        return Self{ .ring = ring };
    }

    pub fn deinit(self: *Self) void {
        self.ring.deinit();
    }
};
