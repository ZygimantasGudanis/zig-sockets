const std = @import("std");
const net = std.net;
const posix = std.posix;
const Connection = net.Server.Connection;
const print = std.debug.print;

const socket_t = posix.socket_t;
const Allocator = std.mem.Allocator;

pub const ChatServer = struct {
    allocator: std.mem.Allocator,
    socket: posix.socket_t,

    connections: std.ArrayList(socket_t),
    maxConns: u8,
    new_connections: std.ArrayList(socket_t),
    buffer: u32,

    worker_thread: std.Thread = undefined,
    acceptConn_thread: std.Thread = undefined,
    isWorking: bool = false,
    pub fn init(allocator: std.mem.Allocator, buffer: u32, maxConns: u8) !*ChatServer {
        const server = try allocator.create(ChatServer);
        server.*.connections = std.ArrayList(socket_t).init(allocator);
        server.*.new_connections = std.ArrayList(socket_t).init(allocator);
        server.*.maxConns = maxConns;
        server.*.buffer = buffer;

        const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 5101);
        const socket = try std.posix.socket(
            address.any.family,
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
            std.posix.IPPROTO.TCP,
        );
        try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try std.posix.bind(socket, &address.any, address.getOsSockLen());
        try std.posix.listen(socket, 128);

        server.*.socket = socket;
        return server;
    }

    pub fn deinit(self: *ChatServer) void {
        //self.allocator.free(self.connections[0..]);
        try self.stopServer();

        posix.close(self.*.socket);

        for (self.*.connections.items) |sock| {
            posix.close(sock);
        }

        for (self.*.new_connections.items) |sock| {
            posix.close(sock);
        }
        self.*.connections.deinit();
        self.*.new_connections.deinit();
        self.* = undefined;
    }

    pub fn startServer(self: *ChatServer) !void {
        self.*.isWorking = true;

        self.*.worker_thread = try std.Thread.spawn(.{}, workerLoop, .{self});
    }

    pub fn stopServer(self: *ChatServer) !void {
        if (self.*.isWorking) {
            self.*.isWorking = false;
            self.*.worker_thread.join();
            self.*.acceptConn_thread.join();
        }
    }

    fn workerLoop(self: *ChatServer) !void {
        var arenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        //const alloc = arenaAllocator.allocator();
        defer arenaAllocator.deinit();

        while (self.*.isWorking) {}
    }

    fn writeMessageVec(socket: *socket_t, msg: []const u8) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u8, &buf, @intCast(msg.len), .little);

        var vec = [2]posix.iovec_const{
            .{ .len = buf.len, .base = &buf },
            .{ .len = msg.len, .base = msg.ptr },
        };
        try writeAllVec(socket, &vec);
    }

    fn writeAllVec(socket: *socket_t, vec: []posix.iovec_const) !void {
        var i: usize = 0;
        while (true) {
            var n = try posix.writev(socket.*, vec[i..]);
            while (n >= vec[i].len) {
                n -= vec[i].len;
                i += 1;
                if (i >= vec.len) return;
            }
            vec[i].base += n;
            vec[i].len -= n;
        }
    }
};

const Reader = struct {
    buf: []u8,

    //Position in the buffer
    pos: usize = 0,

    //Message starts at
    start: usize = 0,

    // Read from
    socket: socket_t,

    pub fn readMessage(self: *Reader) ![]u8 {
        var buf = self.buf;
        while (true) {
            if (try self.bufferedMessage()) |msg| {
                return msg;
            }

            const pos = self.pos;
            const n = try posix.read(self.socket, buf[pos..]);
            if (n == 0) return error.Closed;

            self.pos = pos + n;
        }
    }

    fn bufferedMessage(self: *Reader) !?[]u8 {
        const buf = self.buf;
        const pos = self.pos;

        const start = self.start;

        std.debug.assert(pos >= start);
        const unprocessed = buf[start..pos];
        if (unprocessed.len < 4) {
            self.ensureSpace(4 - unprocessed.len) catch unreachable;
            return null;
        }
        const message_len = std.mem.readInt(u32, unprocessed[0..4], .little);
        const total_len = message_len + 4;

        if (unprocessed.len < total_len) {
            try self.ensureSpace(total_len);
            return null;
        }

        self.start += total_len;
        return unprocessed[4..total_len];
    }

    fn ensureSpace(self: *Reader, space: usize) error{BufferTooSmall}!void {
        const buf = self.buf;
        if (buf.len < space) return error.BufferTooSmall;

        const start = self.start;
        const spare = buf.len - start;
        if (spare >= space) return;

        const unproccesed = buf[start..self.pos];
        std.mem.copyForwards(u8, buf[0..unproccesed.len], unproccesed);
        self.start = 0;
        self.pos = unproccesed.len;
    }
};

pub fn loop() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //defer gpa.deinit();
    const allocator = gpa.allocator();

    var pool: std.Thread.Pool = undefined;
    try std.Thread.Pool.init(&pool, .{ .allocator = allocator, .n_jobs = 64 });
    defer pool.deinit();

    const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 5101);
    const socket = try std.posix.socket(
        address.any.family,
        std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
        std.posix.IPPROTO.TCP,
    );
    defer posix.close(socket);
    try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try std.posix.bind(socket, &address.any, address.getOsSockLen());
    try std.posix.listen(socket, 128);

    var buf: [128]u8 = undefined;
    while (true) {
        const clientSocket = posix.accept(socket, null, null, posix.SOCK.NONBLOCK) catch |err| {
            if (err == error.WouldBlock) {
                std.Thread.sleep(1_000_000);
                continue;
            }
            print("Error accept {}\n", .{err});
            continue;
        };
        defer posix.close(clientSocket);
        // const client = Client{ .socket = clientSocket, .address = client_address };
        // try pool.spawn(Client.handle, .{client});

        const stream = net.Stream{ .handle = clientSocket };
        const read = try stream.read(&buf);
        if (read == 0) {
            continue;
        }
        try stream.writeAll(buf[0..read]);
    }
}

pub fn loop2() !void {
    const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 5101);
    const socket = try std.posix.socket(
        address.any.family,
        std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
        std.posix.IPPROTO.TCP,
    );
    defer posix.close(socket);
    try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try std.posix.bind(socket, &address.any, address.getOsSockLen());
    try std.posix.listen(socket, 128);

    // Our server can support 4095 clients. Wait, shouldn't that be 4096? No
    // One of the polling slots (the first one) is reserved for our listening
    // socket.
    var polls: [4096]posix.pollfd = undefined;
    polls[0] = .{
        .fd = socket,
        .events = posix.POLL.IN,
        .revents = 0,
    };
    var poll_count: usize = 1;
    print("Starting server...\n", .{});
    while (true) {
        var active = polls[0..poll_count];
        // 2nd argument is the timeout, -1 is infinity
        _ = try posix.poll(active, -1);

        if (active[0].revents != 0) {
            const clientSocket = posix.accept(socket, null, null, posix.SOCK.NONBLOCK) catch |err| switch (err) {
                error.WouldBlock => {
                    continue;
                },
                else => {
                    unreachable;
                },
            };
            polls[poll_count] = .{
                .fd = clientSocket,
                .revents = 0,
                .events = posix.POLL.IN,
            };

            poll_count += 1;
        }

        var i: usize = 1;
        while (i < active.len) {
            const polled = active[i];
            const revents = polled.revents;
            if (revents == 0) {
                i += 1;
                continue;
            }

            var closed = false;
            // print("New COnnection...{}, {}, {}\n", .{revents, polled.events, posix.POLL.IN});
            if (polled.events & posix.POLL.IN == posix.POLL.IN) {
                var buf: [4096]u8 = undefined;
                const read = posix.read(polled.fd, &buf) catch 0;
                if (read == 0) {
                    closed = true;
                } else {
                    print("[{d}] got: {any}\n", .{ polled.fd, buf[0..read] });
                }
            }

            if (closed or (revents & posix.POLL.HUP == posix.POLL.HUP)) {
                const last_index = active.len - 1;
                active[i] = active[last_index];
                active = active[0..last_index];
                poll_count -= 1;
            } else {
                i += 1;
            }
        }
    }
}

const Client = struct {
    socket: socket_t,
    address: net.Address,

    pub fn handle(self: Client) void {
        self._handle() catch |err| switch (err) {
            error.Closed => {},
            error.WouldBlock => {},
            else => print("[{any}] client unhandled error: {}\n", .{ self.address, err }),
        };
    }

    fn _handle(self: Client) !void {
        const socket = self.socket;
        defer posix.close(socket);
        const timeout = posix.timeval{ .sec = 2, .usec = 500_00 };
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(timeout));
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(timeout));

        var buf: [1024]u8 = undefined;
        var reader = Reader{ .pos = 0, .buf = &buf, .socket = socket };

        while (true) {
            const msg = try reader.readMessage();
            print("Got: {s}\n", .{msg});
        }
    }
};
