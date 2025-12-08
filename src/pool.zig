const std = @import("std");
const os = std.os;
const posix = std.posix;
const assert = std.debug.assert;

const RingUserData = @import("eventring.zig").RingUserData;

const ParseIpError = error{InvalidIp};

const StreamState = enum {
    idle,
    await_sock,
    await_conn,
    active,
};

fn parseIp(ip: []const u8) !std.net.Address {
    var stream = std.io.fixedBufferStream(ip);
    const reader = stream.reader();
    var byte: u8 = undefined;
    var parsed_ip = [4]u8{ 0, 0, 0, 0 };
    var index: usize = 0;

    while (true) {
        byte = reader.readByte() catch break;
        switch (byte) {
            '0'...'9' => parsed_ip[index] = parsed_ip[index] * 10 + (byte - '0'),
            '.' => index += 1,
            ':' => break,
            else => return ParseIpError.InvalidIp,
        }
    }
    var port: u16 = 0;
    while (true) {
        byte = reader.readByte() catch break;
        switch (byte) {
            '0'...'9' => port = port * 10 + (byte - '0'),
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

    pub fn init(allocator: std.mem.Allocator, user_data: *RingUserData, upstream: []const u8, ring: *os.linux.IoUring) !*Self {
        const socket_addr = try parseIp(upstream);

        _ = try ring.socket(@intFromPtr(user_data), posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP, 0);

        const stream = try allocator.create(Stream);
        stream.state = .await_sock;
        stream.upstream_address = socket_addr;

        return stream;
    }

    pub fn deinit(self: Self) void {
        posix.close(self.handle);
    }
};

pub const StreamPool = struct {
    streams: std.ArrayList(*Stream),
    upstream: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, host: []const u8) !*Self {
        var self = try allocator.create(StreamPool);
        self.upstream = host;
        self.streams = try std.ArrayList(*Stream).initCapacity(allocator, 50);
        return self;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.streams.items) |stream| {
            allocator.destroy(stream);
        }
        self.streams.deinit(allocator);
    }

    pub fn acquire(self: *Self, allocator: std.mem.Allocator, user_data: *RingUserData, ring: *os.linux.IoUring) !*Stream {
        for (self.streams.items) |stream| {
            if (stream.state == .idle) {
                stream.state = .active;
                return stream;
            }
        }

        const stream = try Stream.init(allocator, user_data, self.upstream, ring);
        try self.streams.append(allocator, stream);
        return stream;
    }

    pub fn findByClientId(self: *const Self, client_id: i32) ?*Stream {
        for (self.streams.items) |stream| {
            if (stream.client_fd == client_id) {
                return stream;
            }
        }
        return null;
    }

    pub fn release(self: *Self, allocator: std.mem.Allocator, stream: *Stream) !void {
        var indexOf: usize = 0;
        var i: usize = 0;
        for (self.streams.items) |s| {
            if (s == stream) {
                indexOf = i;
                break;
            }
            i += 1;
        }
        _ = self.streams.swapRemove(indexOf);
        allocator.destroy(stream);
    }
};

test "parse ip" {
    const ip = "127.0.0.1:8080";
    const parsed_ip = try parseIp(ip);
    assert(parsed_ip.eql(std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 8080)));
}
