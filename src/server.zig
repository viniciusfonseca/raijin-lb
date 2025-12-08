const std = @import("std");
const os = std.os;
const posix = std.posix;
const eventring = @import("eventring.zig");

pub const Server = struct {
    fd: i32,
    addr: std.net.Address,
    addr_len: u32,
    event_ring: *eventring.EventRing,

    const Self = @This();

    pub fn init(event_ring: *eventring.EventRing, port: u16) !Self {
        const server_socket_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);

        var server_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        const addr_len: posix.socklen_t = server_addr.getOsSockLen();

        try posix.setsockopt(server_socket_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(server_socket_fd, &server_addr.any, addr_len);
        const backlog = 128;
        try posix.listen(server_socket_fd, backlog);

        return .{
            .event_ring = event_ring,
            .fd = server_socket_fd,
            .addr = server_addr,
            .addr_len = addr_len,
        };
    }

    pub fn deinit(self: Self) void {
        posix.close(self.fd);
    }

    pub fn accept(self: *Self, allocator: std.mem.Allocator) !void {
        const user_data = try allocator.create(eventring.RingUserData);
        user_data.state = .accept;

        _ = try self.event_ring.ring.accept(@intFromPtr(user_data), self.fd, &self.addr.any, &self.addr_len, 0);
    }
};
