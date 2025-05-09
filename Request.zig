const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;
const Response = @import("./Response.zig");

pub const Context = struct {
    const ContextSelf = @This();
    params: std.StringHashMap([]const u8),

    pub fn init(allocator: Allocator) ContextSelf {
        return .{
            .params = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn add(self: *ContextSelf, key: []const u8, val: []const u8) !void {
        try self.params.put(key, val);
    }

    pub fn deinit(self: *ContextSelf) void {
        self.params.deinit();
    }
};

const Self = @This();

req: http.Server.Request,
conn: std.net.Server.Connection,
res: Response,
allocator: std.mem.Allocator,
context: *Context,
n: i64,
http_server: *http.Server,
buffer: []u8,
headers: std.StringHashMap([]const u8),

pub fn init(allocator: std.mem.Allocator, conn: std.net.Server.Connection, context: *Context, n: i64) !Self {
    const buffer = try allocator.alloc(u8, 1028);
    var http_server = try allocator.create(http.Server);
    http_server.* = http.Server.init(conn, buffer);
    var req = try http_server.receiveHead();

    var headers = std.StringHashMap([]const u8).init(allocator);
    var it = req.iterateHeaders();

    while (it.next()) |header| {
        try headers.put(header.name, header.value);
    }

    return .{
        .conn = conn,
        .req = req,
        .res = Response.init(allocator, req),
        .allocator = allocator,
        .context = context,
        .n = n,
        .http_server = http_server,
        .buffer = buffer,
        .headers = headers,
    };
}

pub fn deinit(self: *Self) void {
    self.conn.stream.close();
    self.res.deinit();
    self.context.deinit();
    self.allocator.destroy(self.context);
    self.allocator.destroy(self.http_server);
    self.allocator.free(self.buffer);
    self.headers.deinit();
}

pub fn target(self: Self) []const u8 {
    return self.req.head.target;
}

pub fn method(self: Self) http.Method {
    return self.req.head.method;
}

pub fn json_data(self: *Self, T: type) !T {
    var reader = try self.req.reader();
    const data = try reader.readAllAlloc(self.allocator, 2046);
    defer self.allocator.free(data);
    var parsed = try std.json.parseFromSlice(T, self.allocator, data, .{});
    defer parsed.deinit();

    return parsed.value;
}

pub fn get_header(self: *Self, name: []const u8) ?[]const u8 {
    return self.headers.get(name);
}
