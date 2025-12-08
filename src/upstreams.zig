const std = @import("std");
const os = std.os;
const posix = std.posix;
const pool = @import("pool.zig");
const eventring = @import("eventring.zig");
const RingUserData = eventring.RingUserData;
const Server = @import("server.zig").Server;

const UpstreamManagerInitError = error{NoUpstreams};
const ProxyError = error{ InvalidUpstream, CqeError };

const IOURING_RECV_FLAGS = os.linux.MSG.ZEROCOPY | os.linux.IORING_RECV_MULTISHOT;
const IOURING_SEND_ZC_FLAGS = os.linux.IORING_SEND_ZC_REPORT_USAGE;
const IOURING_SEND_ZC_PROGRESS = -(1 << 31);

pub const UpstreamsManager = struct {
    pools: std.StringHashMap(*pool.StreamPool),
    upstreams: std.ArrayList([]const u8),
    upstream_index: usize,
    server: *Server,

    const Self = @This();

    pub fn getUpstreamsFromEnv(allocator: std.mem.Allocator) ![]const []const u8 {
        const upstreams = std.process.getEnvVarOwned(allocator, "TCP_UPSTREAMS") catch "";

        std.log.info("TCP_UPSTREAMS: {s}", .{upstreams});

        var it = std.mem.splitScalar(u8, upstreams, ',');
        var upstreams_list = try std.ArrayList([]const u8).initCapacity(allocator, 8);
        while (it.next()) |upstream| {
            try upstreams_list.append(allocator, upstream);
        }
        return upstreams_list.items;
    }

    pub fn init(allocator: std.mem.Allocator, server: *Server, upstreams: []const []const u8) !Self {
        if (upstreams.len == 0) {
            return UpstreamManagerInitError.NoUpstreams;
        }
        var pools = std.StringHashMap(*pool.StreamPool).init(allocator);

        for (upstreams) |upstream| {
            try pools.put(upstream, try pool.StreamPool.init(allocator, upstream));
        }
        var upstreams_keys = try std.ArrayList([]const u8).initCapacity(allocator, 8);

        var key_it = pools.keyIterator();
        var n: usize = 0;
        while (key_it.next()) |key| {
            n += 1;
            try upstreams_keys.append(allocator, key.*);
        }

        std.log.debug("created {} upstream pool(s)", .{n});

        return .{
            .server = server,
            .upstreams = upstreams_keys,
            .pools = pools,
            .upstream_index = 0,
        };
    }

    fn getUpstreamRoundRobin(self: *Self) []const u8 {
        const upstream = self.upstreams.items[self.upstream_index];
        self.upstream_index = (self.upstream_index + 1) % self.upstreams.items.len;
        return upstream;
    }

    pub fn handleCqe(self: *Self, allocator: std.mem.Allocator, cqe: os.linux.io_uring_cqe) !void {
        const user_data_ptr: usize = @intCast(cqe.user_data);
        var user_data: *RingUserData = @ptrFromInt(user_data_ptr);

        errdefer self.handleError(user_data);

        if (cqe.res < 0) {
            if (cqe.res == IOURING_SEND_ZC_PROGRESS) {
                return;
            }

            const e: posix.E = @enumFromInt(-cqe.res);
            std.log.err("error from cqe ({}): {}", .{
                user_data.state,
                e,
            });
            return ProxyError.CqeError;
        }

        switch (user_data.state) {
            .accept => {
                user_data.client_fd = @intCast(cqe.res);
                const upstream = self.getUpstreamRoundRobin();
                user_data.upstream = upstream;
                var upstream_pool = self.pools.get(upstream) orelse return ProxyError.InvalidUpstream;

                var stream = try upstream_pool.acquire(allocator, user_data, &self.server.event_ring.ring);
                stream.client_fd = user_data.client_fd.?;
                if (stream.state == .await_sock) {
                    user_data.state = .await_sock;
                } else {
                    _ = try self.server.event_ring.ring.recv(@intFromPtr(user_data), user_data.client_fd.?, .{ .buffer = &user_data.buffer }, IOURING_RECV_FLAGS);
                    user_data.state = .recv_client;
                }

                try self.server.accept(allocator);
            },
            .await_sock => {
                user_data.upstream_fd = @intCast(cqe.res);
                var upstream_pool = self.pools.get(user_data.upstream) orelse return ProxyError.InvalidUpstream;
                var stream = upstream_pool.findByClientId(user_data.client_fd.?).?;

                _ = try self.server.event_ring.ring.connect(@intFromPtr(user_data), user_data.upstream_fd.?, &stream.upstream_address.any, stream.upstream_address.getOsSockLen());

                stream.state = .await_conn;
                user_data.state = .await_conn;
            },
            .await_conn => {
                var upstream_pool = self.pools.get(user_data.upstream) orelse return ProxyError.InvalidUpstream;
                var stream = upstream_pool.findByClientId(user_data.client_fd.?).?;

                _ = try self.server.event_ring.ring.recv(@intFromPtr(user_data), user_data.client_fd.?, .{ .buffer = &user_data.buffer }, IOURING_RECV_FLAGS);

                stream.state = .active;
                user_data.state = .recv_client;
            },
            .recv_client => {
                const request = user_data.buffer[0..@intCast(cqe.res)];
                _ = try self.server.event_ring.ring.send_zc(@intFromPtr(user_data), user_data.upstream_fd.?, request, 0, IOURING_SEND_ZC_FLAGS);
                user_data.state = .send_upstream;
            },
            .send_upstream => {
                _ = try self.server.event_ring.ring.recv(@intFromPtr(user_data), user_data.upstream_fd.?, .{ .buffer = &user_data.buffer }, IOURING_RECV_FLAGS);
                user_data.state = .recv_upstream;
            },
            .recv_upstream => {
                var upstream_pool = self.pools.get(user_data.upstream) orelse return ProxyError.InvalidUpstream;
                const stream = upstream_pool.findByClientId(user_data.client_fd.?).?;

                const response = user_data.buffer[0..@intCast(cqe.res)];
                _ = try self.server.event_ring.ring.send_zc(@intFromPtr(user_data), user_data.client_fd.?, response, 0, IOURING_SEND_ZC_FLAGS);
                user_data.state = .send_client;
                try upstream_pool.release(allocator, stream);
            },
            .send_client => {
                _ = try self.server.event_ring.ring.close(@intFromPtr(user_data), user_data.client_fd.?);
                user_data.state = .close;
            },
            .close => allocator.destroy(user_data),
        }
    }

    fn handleError(self: *Self, user_data: *RingUserData) void {
        if (user_data.state == .send_client) {
            return;
        }

        if (user_data.client_fd) |client_fd| {
            if (self.pools.get(user_data.upstream)) |upstream_pool| {
                if (upstream_pool.findByClientId(client_fd)) |stream| {
                    stream.client_fd = null;
                    stream.state = .idle;
                }
            }
            const response =
                \\HTTP/1.1 502 Bad Gateway
                \\Content-Length: 0
                \\
            ;

            _ = self.server.event_ring.ring.send_zc(@intFromPtr(user_data), client_fd, response, 0, IOURING_SEND_ZC_FLAGS) catch {};
            user_data.state = .send_client;
        }
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        var it = self.pools.valueIterator();
        while (it.next()) |pool_v| {
            pool_v.*.deinit(allocator);
        }
        self.pools.deinit();
        self.upstreams.deinit(allocator);
    }
};
