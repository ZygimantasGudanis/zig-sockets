const std = @import("std");

const print = std.debug.print;
const Allocator = std.mem.Allocator;
const Address = std.net.Address;
const posix = std.posix;
const Socket = std.posix.socket_t;

pub const ChatSever = struct {
    alloc: Allocator,
    connected: u32 = 0,

    conn_pool: []ChatClient,
    polls: []posix.pollfd,

    pub fn init(alloc: Allocator, conns: u32) !ChatSever {
        //var address = try Address.parseIp4("127.0.0.1", 5101);
        const connections = try alloc.alloc(ChatClient, conns + 1);
        errdefer alloc.free(connections);

        const polls = try alloc.alloc(posix.pollfd, conns + 1);
        errdefer alloc.free(polls);

        return ChatSever{
            .alloc = alloc,
            .conn_pool = connections,
            .polls = polls,
        };
    }

    pub fn deinit(self: *ChatSever) void {
        self.alloc.free(self.conn_pool);
        self.alloc.free(self.polls);
    }

    pub fn run(self: *ChatSever) !void {
        print("Server starting...\n", .{});
        const address = try Address.parseIp4("127.0.0.1", 5101);
        const tpe = posix.SOCK.CLOEXEC | posix.SOCK.STREAM | posix.SOCK.NONBLOCK;
        const protocol = posix.IPPROTO.TCP;

        // TODO: Figure put what happens in these 4 lines
        const server = try posix.socket(address.any.family, tpe, protocol);
        try posix.setsockopt(server, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(server, &address.any, address.getOsSockLen());
        try posix.listen(server, 128);

        self.polls[0] = .{
            .fd = server,
            .events = posix.POLL.IN,
            .revents = 0,
        };

        print("Server started.\n", .{});

        while (true) {
            _ = try posix.poll(self.polls[0..(self.connected + 1)], -1);
            if (self.polls[0].revents != 0) {
                self.accept(server) catch |err| switch (err) {
                    error.WouldBlock => continue,
                    else => return err,
                };
            }
            var i: u32 = 0;
            while (i < self.connected) {
                const polled = self.polls[i + 1];
                if (polled.revents == 0) {
                    i += 1;
                    continue;
                }

                if (polled.revents == posix.POLL.HUP & posix.POLL.ERR) {
                    self.removeClient(i);
                    continue;
                }

                var client = &self.conn_pool[i];
                while (true) {
                    if (polled.events & posix.POLL.IN == posix.POLL.IN) {
                        const msg = client.readMessage() catch |err| switch (err) {
                            else => {
                                print("Error , {}\n", .{err});
                                self.removeClient(i);
                                break;
                            },
                        } orelse {
                            i += 1;
                            break;
                        };
                        print("msg:{s}\n", .{msg});
                    }
                    i += 1;
                    break;
                }
            }
        }
    }

    fn accept(self: *ChatSever, server: Socket) !void {
        var address: Address = undefined;
        var address_len: posix.socklen_t = @sizeOf(Address);
        const client = posix.accept(server, &address.any, &address_len, posix.SOCK.NONBLOCK) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        print("Accepted client {any}.\n", .{address.any});
        self.conn_pool[self.connected] = ChatClient.init(self.alloc, client, address, 4096) catch |err| {
            posix.close(client);
            return err;
        };
        self.connected += 1;
        self.polls[self.connected] = posix.pollfd{ .fd = client, .revents = 0, .events = posix.POLL.IN };
    }

    fn removeClient(self: *ChatSever, at: usize) void {
        print("Disconnecting client {}.\n", .{at});
        var client = self.conn_pool[at];
        defer {
            posix.close(client.client);
            client.deinit(self.alloc);
            print("Disconnected client {}.\n", .{at});
        }
        const last_index = self.connected - 1;
        self.conn_pool[at] = self.conn_pool[last_index];
        self.polls[at + 1] = self.polls[last_index + 1];

        self.connected = last_index;
    }
};

pub const ChatClient = struct {
    client: Socket,
    reader: Reader,
    address: Address,

    write_buf: []u8,
    to_write: []u8,

    pub fn init(alloc: Allocator, socket: Socket, address: Address, bufferSize: u32) !ChatClient {
        const write_buffer = try alloc.alloc(u8, bufferSize);
        return .{
            .client = socket,
            .address = address,
            .write_buf = write_buffer,
            .to_write = &.{},
            .reader = try Reader.init(alloc, bufferSize),
        };
    }

    pub fn deinit(self: *ChatClient, alloc: Allocator) void {
        alloc.free(self.write_buf);
        self.reader.deinit(alloc);
    }

    pub fn readMessage(self: *ChatClient) !?[]u8 {
        const msg = self.reader.readMessage(self.client) catch {
            return null;
        };
        return msg;
    }
};

pub const Reader = struct {
    buffer: []u8,

    // The start of a message.
    start: usize,
    // The position in buffer that was last written to.
    pos: usize,

    pub fn init(alloc: Allocator, bufferSize: u32) !Reader {
        const buffer = try alloc.alloc(u8, bufferSize);
        return .{ .start = 0, .pos = 0, .buffer = buffer };
    }

    pub fn deinit(self: *Reader, alloc: Allocator) void {
        alloc.free(self.buffer);
    }

    pub fn readMessage(self: *Reader, client: Socket) !?[]u8 {
        // NO buffered messages.
        if (self.start >= self.pos) {
            self.start = 0;
            self.pos = self.readToBuffer(client, self.start) catch |err| switch (err) {
                error.WouldBlock => return null,
                else => return err,
            };
        }

        print("Start:{} , Pos:{}\n", .{ self.start, self.pos });

        return self.buffer[self.start + 4 .. self.pos];
    }

    pub fn bufferedMessage(self: *Reader) ServerError!?[]u8 {
        if (self.start >= self.pos) {
            return null;
        }
        var unprocessed = self.buffer[self.start..];
        const size = std.mem.readInt(u32, unprocessed[0..4], .little);
        const pos = self.start + size;

        if (pos >= self.buffer.len) {
            return ServerError.MessageTooLarge;
        }
        if (pos >= unprocessed) {
            std.mem.copyForwards(u8, self.buffer[0..unprocessed.len], unprocessed[0..]);
            self.start = 0;
            self.pos = unprocessed.len;
        }

        if (size == 0) {
            self.start += 4;
            return null;
        }
    }

    fn readToBuffer(self: *Reader, client: Socket, start: usize) !usize {
        const read = posix.read(client, self.buffer[start..]) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        return read;
    }
};

const ServerError = error{
    MessageTooLarge,
};
