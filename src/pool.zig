const std = @import("std");
const os = std.os;
const posix = std.posix;
const assert = std.debug.assert;

const RingUserData = @import("eventring.zig").RingUserData;

const ParseIpError = error{InvalidIp};
const StreamAcquireError = error{NoStreams};

const StreamState = enum {
    idle,
    await_sock,
    await_conn,
    active,
};

fn parseIp(ip: []const u8) !std.net.Address {
    var parsed_ip: [4]u8 = .{ 0, 0, 0, 0 };
    var port: u16 = undefined;

    var it = std.mem.tokenizeAny(u8, ip, ".:");
    var i: usize = 0;
    while (it.next()) |token| {
        switch (i) {
            0, 1, 2, 3 => {
                parsed_ip[i] = try std.fmt.parseInt(u8, token, 10);
                i += 1;
            },
            4 => {
                port = try std.fmt.parseInt(u16, token, 10);
                break;
            },
            else => return ParseIpError.InvalidIp,
        }
    }

    return std.net.Address.initIp4(parsed_ip, port);
}

pub const Stream = struct {
    state: StreamState,
    client_fd: ?i32 = 0,
    upstream_fd: ?i32 = 0,
    upstream_address: std.net.Address,

    const Self = @This();

    pub fn request_socket(self: *Self, user_data: *RingUserData, upstream: []const u8, ring: *os.linux.IoUring) !void {
        const socket_addr = try parseIp(upstream);

        _ = try ring.socket(@intFromPtr(user_data), posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP, 0);

        self.state = .await_sock;
        self.upstream_address = socket_addr;
    }

    pub fn deinit(self: Self) void {
        posix.close(self.handle);
    }
};

pub const StreamPool = struct {
    streams: []Stream,
    upstream: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, host: []const u8) !*Self {
        var self = try allocator.create(StreamPool);
        self.streams = try allocator.alloc(Stream, 128);
        for (self.streams) |*stream| {
            stream.state = .idle;
        }
        self.upstream = host;
        return self;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.streams);
        allocator.destroy(self);
    }

    pub fn acquire(self: *Self, user_data: *RingUserData, ring: *os.linux.IoUring) !*Stream {
        for (self.streams) |*stream| {
            if (stream.state == .idle) {
                try stream.request_socket(user_data, self.upstream, ring);
                return stream;
            }
        }

        return StreamAcquireError.NoStreams;
    }

    pub fn findByClientId(self: *const Self, client_id: i32) ?*Stream {
        for (self.streams) |*stream| {
            if (stream.client_fd == client_id) {
                return stream;
            }
        }
        return null;
    }

    pub fn release(_: *Self, stream: *Stream) !void {
        stream.state = .idle;
    }
};

test "parse ip" {
    const ip = "127.0.0.1:8080";
    const parsed_ip = try parseIp(ip);
    assert(parsed_ip.eql(std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 8080)));
}
