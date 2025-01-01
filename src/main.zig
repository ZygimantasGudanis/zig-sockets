const std = @import("std");
//const Server = @import("server.zig").ChatServer;
const ser = @import("server.zig");
const print = std.debug.print;
const chatServer = @import("chatserver.zig").ChatSever;

pub fn main() !void {
    var arenaAlloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arenaAlloc.deinit();
    const alloc = arenaAlloc.allocator();
    var server = try chatServer.init(alloc, 256);
    // var server = try ser.Server.init(alloc, 128);

    defer server.deinit();
    try server.run();
}
