const std = @import("std");
const Server = @import("server.zig").ChatServer;
const ser = @import("server.zig");
const print = std.debug.print;

pub fn main() !void {
    var arenaAlloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arenaAlloc.deinit();
    const alloc = arenaAlloc.allocator();
    // var server = try Server.init(alloc, 1024, 8);
    // //std.debug.print("{}\n", .{server.*.connections});
    // defer server.deinit();
    // try server.startServer();
    // var buffer: [32]u8 = undefined;
    // const reader = std.io.getStdIn().reader();
    // var user_input: ?[]u8 = reader.readUntilDelimiterOrEof(&buffer, '\n') catch {
    //     print("Input : {s}\n", .{&buffer});
    //     return;
    // };

    // print("Input : {s}\n", .{&user_input});
    // try server.stopServer();

    var server = try ser.Server.init(alloc, 128);
    defer server.deinit();
    try server.run();
}
