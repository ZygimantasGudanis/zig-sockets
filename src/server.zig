const std = @import("std");
const net = std.net;
const posix = std.posix;
const Connection = net.Server.Connection;
const print = std.debug.print;

const socket_t = posix.socket_t;
const Allocator = std.mem.Allocator;

const Reader = struct {
    buf: []u8,
    pos: usize = 0,
    start: usize = 0,

    // Add to header total message size
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

    to_write: []u8,
    write_buff: []u8,

    read_timeout: i64,
    read_timeout_node: *ClientNode,

    pub fn init(allocator: Allocator, socket: socket_t, address: net.Address) !Client {
        const reader = try Reader.init(allocator, 4096);
        errdefer reader.deinit(allocator);

        const write_buf = try allocator.alloc(u8, 4096);
        errdefer allocator.free(write_buf);

        return .{
            .address = address,
            .socket = socket,
            .reader = reader,
            .to_write = &.{},
            .write_buff = write_buf,
            .read_timeout = 0,
            .read_timeout_node = undefined,
        };
    }
    pub fn deinit(self: *const Client, allocator: Allocator) void {
        self.reader.deinit(allocator);
        allocator.free(self.write_buff);
    }

    pub fn readMessage(self: *Client) !?[]const u8 {
        return self.reader.readMessage(self.socket) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
    }

    pub fn writeMessage(self: *Client, msg: []u8) !bool {
        if (self.to_write.len > 0) {
            return error.PendingMessage;
        }

        if (msg.len + 4 > self.write_buff.len) {
            return error.MessageTooLarge;
        }

        std.mem.writeInt(u32, self.write_buff[0..4], @intCast(msg.len), .little);
        const end = msg.len + 4;
        @memcpy(self.write_buff[4..end], msg);

        self.to_write = self.write_buff[0..end];
        return self.write();
    }

    pub fn write(self: *Client) !bool {
        var buf = self.to_write;
        defer self.to_write = buf;
        while (buf.len > 0) {
            const n = posix.write(self.socket, buf) catch |err| switch (err) {
                error.WouldBlock => return false,
                else => return err,
            };

            if (n == 0) {
                return error.Closed;
            }

            buf = buf[n..];
        } else {
            return true;
        }
    }
};

// 1 minute
const READ_TIMEOUT_MS = 60_000;
const ClientList = std.DoublyLinkedList(*Client);
const ClientNode = ClientList.Node;

pub const Server = struct {
    allocator: std.mem.Allocator,
    connected: usize,
    polls: []posix.pollfd,
    clients: []*Client,
    client_polls: []posix.pollfd,
    client_pool: std.heap.MemoryPool(Client),

    read_timeout_list: ClientList,
    client_node_pool: std.heap.MemoryPool(ClientList.Node),

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
            .client_pool = std.heap.MemoryPool(Client).init(allocator),
            .client_node_pool = std.heap.MemoryPool(ClientNode).init(allocator),
        };
    }

    pub fn deinit(self: *Server) void {
        self.allocator.free(self.polls);
        self.allocator.free(self.clients);

        self.client_pool.deinit(self.allocator);
        self.client_node_pool.deinit(self.allocator);
    }

    pub fn accept(self: *Server, socket: socket_t) !void {
        const space = self.client_pool.len - self.connected;
        for (0..space) |_| {
            var address: net.Address = undefined;
            var address_len: posix.socklen_t = @sizeOf(net.Address);
            const clientSocket = posix.accept(socket, &address.any, &address_len, posix.SOCK.NONBLOCK) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };

            const client = try self.client_pool.create();
            errdefer self.client_pool.destroy(client);

            client.* = Client.init(self.allocator, clientSocket, address) catch |err| {
                posix.close(clientSocket);
                print("{}\n", .{err});
                return;
            };

            client.read_timeout = std.time.milliTimestamp() + READ_TIMEOUT_MS;
            client.read_timeout_node = try self.client_node_pool.create();
            errdefer self.client_node_pool.destroy(client.read_timeout_node);
            client.read_timeout_node.* = .{
                .next = null,
                .prev = null,
                .data = client,
            };
            self.read_timeout_list.append(client.read_timeout_node);

            const connected = self.connected;
            self.clients[connected] = client;
            const poll = posix.pollfd{
                .fd = clientSocket,
                .revents = 0,
                .events = posix.POLL.IN,
            };
            self.client_polls[connected] = poll;
            print("Client , {}, {}, {}, {any}\n", .{ self.client_polls[connected].revents, self.client_polls[connected].events, posix.POLL.IN, posix.POLL.IN });
            self.connected += 1;
        }
    }

    pub fn removeClient(self: *Server, at: usize) void {
        var client = self.clients[at];
        defer {
            posix.close(client.socket);
            self.client_node_pool.destroy(client.read_timeout_node);
            client.deinit(self.allocator);
            self.client_pool(client);
        }
        const last_index = self.connected - 1;
        self.clients[at] = self.clients[last_index];
        self.client_polls[at] = self.client_polls[last_index];

        self.connected = last_index;
        self.polls[0].events = posix.POLL.IN;
        self.read_timeout_list.remove(client.read_timeout_node);
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
        var read_timeout_list = &self.read_timeout_list;
        while (true) {
            const next_timeout = self.enforeTimeout();
            // 2nd argument is the timeout, -1 is infinity
            _ = try posix.poll(self.polls[0 .. self.connected + 1], next_timeout);

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
            while (i < self.connected) {
                const polled = self.client_polls[i];
                if (polled.revents == 0) {
                    i += 1;
                    continue;
                }

                var client = self.clients[i];
                if (polled.events & posix.POLL.IN == posix.POLL.IN) {
                    while (true) {
                        const msg = client.readMessage() catch |err| {
                            print("Error , {}\n", .{err});
                            self.removeClient(i);
                            break;
                        } orelse {
                            i += 1;
                            break;
                        };

                        client.read_timeout = std.time.milliTimestamp() + READ_TIMEOUT_MS;
                        read_timeout_list.remove(client.read_timeout_node);
                        read_timeout_list.append(client.read_timeout_node);

                        const written = client.writeMessage(msg) catch {
                            self.removeClient(i);
                            break;
                        };
                        if (written == false) {
                            self.client_polls[i].events = posix.POLL.OUT;
                            break;
                        }

                        if (msg.len < 4096) i += 1;
                        print("Connected = {}, Event = {}, Revent = {},  got: {s}\n", .{ self.connected, self.polls[i].events, self.polls[i].revents, msg });
                        break;
                    }
                } else if (polled.events & posix.POLL.OUT == posix.POLL.OUT) {
                    const written = client.write() catch {
                        self.removeClient(i);
                        continue;
                    };
                    if (written) {
                        // and if the entire message was written, we revert to read-mode.
                        self.client_polls[i].events = posix.POLL.IN;
                    }
                }
            }
        }
    }

    fn enforeTimeout(self: *Server) i32 {
        const now = std.time.milliTimestamp();
        var node = self.read_timeou_list.first;
        while (node) |n| {
            const client = n.data;
            const diff = client.read_timeout - now;
            if (diff > 0) {
                return @intCast(diff);
            }

            posix.shutdown(client.Socket, .recv) catch {};
            node = n.next;
        } else {
            return -1;
        }
    }
};
