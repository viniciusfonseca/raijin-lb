const std = @import("std");
const os = std.os;
const linux = os.linux;
const posix = std.posix;
const pool = @import("pool.zig");

const Server = @import("server.zig").Server;
const EventRing = @import("eventring.zig").EventRing;
const UpstreamsManager = @import("upstreams.zig").UpstreamsManager;

pub fn main() !void {
    const fba_mem_size_str = std.process.getEnvVarOwned(std.heap.page_allocator, "BUFFER_MEM_SIZE") catch "32";
    const fba_mem_size = std.fmt.parseInt(usize, fba_mem_size_str, 10) catch |err| {
        std.debug.panic("failed to parse buffer memory size: {}", .{err});
    };

    const buffer = try std.heap.page_allocator.alloc(u8, fba_mem_size * 1024 * 1024);
    var fba = std.heap.FixedBufferAllocator.init(buffer);
    const allocator = fba.allocator();

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
