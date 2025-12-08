const std = @import("std");
const os = std.os;
const linux = os.linux;
const posix = std.posix;
const pool = @import("pool.zig");

const Server = @import("server.zig").Server;
const EventRing = @import("eventring.zig").EventRing;
const UpstreamsManager = @import("upstreams.zig").UpstreamsManager;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var event_ring = EventRing.init() catch |err| {
        std.debug.panic("failed to init event ring: {}", .{err});
    };
    defer event_ring.deinit();

    const port_env = std.process.getEnvVarOwned(allocator, "PORT") catch "8000";
    const port = try std.fmt.parseUnsigned(u16, port_env, 10);

    var server = Server.init(&event_ring, port) catch |err| {
        std.debug.panic("failed to init server: {}", .{err});
    };
    defer server.deinit();
    std.log.info("load balancer running at http://127.0.0.1:{}/", .{port});

    const upstreams = try UpstreamsManager.getUpstreamsFromEnv(allocator);

    var upstreams_manager = UpstreamsManager.init(allocator, &server, upstreams) catch |err| {
        std.debug.panic("failed to init upstreams manager: {}", .{err});
    };
    defer upstreams_manager.deinit(allocator);

    try server.accept(allocator);

    while (true) {
        _ = try event_ring.ring.submit_and_wait(1);

        while (event_ring.ring.cq_ready() > 0) {
            const cqe = try event_ring.ring.copy_cqe();
            upstreams_manager.handleCqe(allocator, cqe) catch |err| {
                std.log.err("failed to handle cqe: {}", .{err});
            };
        }
    }
}

test "basic load balancing" {}
