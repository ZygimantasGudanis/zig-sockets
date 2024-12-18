const std = @import("std");
const net = std.net;
const posix = std.posix;
const Connection = net.Server.Connection;
const print = std.debug.print;

const socket_t = posix.socket_t;
const Allocator = std.mem.Allocator;

const Reader = struct {
    buf: []u8,

    //Position in the buffer
    pos: usize = 0,

    //Message starts at
    start: usize = 0,

    pub fn init(allocator: Allocator, size: usize) !Reader {
        const buf = try allocator.alloc(u8, size);
        return .{
            .buf = buf,
            .pos = 0,
            .start = 0,
        };
    }

    pub fn deinit(self: *const Reader, allocator: Allocator) void {
        allocator.free(self.buf);
    }

    pub fn readMessage(self: *Reader, socket: socket_t) ![]u8 {
        var buf = self.buf;
        while (true) {
            if (try self.bufferedMessage()) |msg| {
                return msg;
            }

            const pos = self.pos;
            print("Reading , {}\n", .{&socket});
            const n = posix.read(socket, buf[pos..]) catch |err| {
                print("Error , {}\n", .{err});
                return err;
            };
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

const Client = struct {
    socket: socket_t,
    address: net.Address,
    reader: Reader,

    pub fn init(allocator: Allocator, socket: socket_t, address: net.Address) !Client {
        const reader = try Reader.init(allocator, 4096);
        return .{
            .address = address,
            .socket = socket,
            .reader = reader,
        };
    }
    pub fn deinit(self: *const Client, allocator: Allocator) void {
        self.reader.deinit(allocator);
    }

    pub fn readMessage(self: *Client) !?[]const u8 {
        return self.reader.readMessage(self.socket) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    connected: usize,
    polls: []posix.pollfd,
    clients: []Client,
    client_polls: []posix.pollfd,

    pub fn init(allocator: std.mem.Allocator, max: usize) !Server {
        const polls = try allocator.alloc(posix.pollfd, max + 1);
        errdefer allocator.free(polls);

        const clients = try allocator.alloc(Client, max);
        errdefer allocator.free(clients);

        return .{
            .polls = polls,
            .clients = clients,
            .client_polls = polls[1..],
            .connected = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Server) void {
        self.allocator.free(self.polls);
        self.allocator.free(self.clients);
    }

    pub fn accept(self: *Server, socket: socket_t) !void {
        while (true) {
            var address: net.Address = undefined;
            var address_len: posix.socklen_t = @sizeOf(net.Address);
            const clientSocket = posix.accept(socket, &address.any, &address_len, posix.SOCK.NONBLOCK) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            const client = Client.init(self.allocator, clientSocket, address) catch |err| {
                posix.close(clientSocket);
                print("{}\n", .{err});
                return;
            };

            const connected = self.connected;
            self.clients[connected] = client;
            const poll = posix.pollfd{
                .fd = clientSocket,
                .revents = 0,
                .events = posix.POLL.IN,
            };
            self.client_polls[connected] = poll;
            print("Cklieant , {}, {}, {}\n", .{ self.client_polls[connected].revents, self.client_polls[connected].events, posix.POLL.IN });
            self.connected += 1;
        }
    }
    pub fn removeClient(self: *Server, at: usize) void {
        var client = self.clients[at];
        posix.close(client.socket);
        client.deinit(self.allocator);

        self.clients[at] = self.clients[self.connected - 1];
        self.client_polls[at] = self.client_polls[self.connected - 1];

        self.connected -= 1;
    }

    pub fn run(self: *Server) !void {
        const address = try std.net.Address.parseIp("127.0.0.1", 5101);
        const tpe = posix.SOCK.STREAM | posix.SOCK.NONBLOCK;
        const protocol = posix.IPPROTO.TCP;
        const server = try posix.socket(address.any.family, tpe, protocol);

        try posix.setsockopt(server, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(server, &address.any, address.getOsSockLen());
        try posix.listen(server, 128);

        self.polls[0] = .{
            .fd = server,
            .events = posix.POLL.IN,
            .revents = 0,
        };
        //self.connected = 1;

        print("Starting server...\n", .{});
        while (true) {
            // 2nd argument is the timeout, -1 is infinity
            _ = try posix.poll(self.polls[0 .. self.connected + 1], 100);

            if (self.polls[0].revents != 0) {
                print("Starting server...\n", .{});
                self.accept(server) catch |err| switch (err) {
                    error.WouldBlock => {
                        continue;
                    },
                    else => return err,
                };
            }
            var i: usize = 0;
            print("Looping , {}, {}, {}\n", .{ self.polls[0].revents, self.polls[0].events, posix.POLL.IN });
            while (i < self.connected) {
                const polled = self.client_polls[i];
                if (polled.events == 0) {
                    i += 1;
                    continue;
                }

                if (polled.events & posix.POLL.IN == posix.POLL.IN) {
                    var client = &self.clients[i];
                    while (true) {
                        const msg = client.readMessage() catch |err| {
                            print("Error , {}\n", .{err});
                            self.removeClient(i);
                            break;
                        } orelse {
                            i += 1;
                            break;
                        };
                        i += 1;
                        self.polls[0].revents = 0;
                        print("got: {s}\n", .{msg});
                        break;
                    }
                }
            }
        }
    }
};
