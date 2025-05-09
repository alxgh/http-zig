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

const Request = @This();

req: http.Server.Request,
conn: std.net.Server.Connection,
res: Response,
allocator: std.mem.Allocator,
context: *Context,
n: i64,
http_server: *http.Server,
buffer: []u8,

pub fn init(allocator: std.mem.Allocator, conn: std.net.Server.Connection, context: *Context, n: i64) !Request {
    const buffer = try allocator.alloc(u8, 1028);
    var http_server = try allocator.create(http.Server);
    http_server.* = http.Server.init(conn, buffer);
    const req = try http_server.receiveHead();

    return .{
        .conn = conn,
        .req = req,
        .res = Response.init(allocator, req),
        .allocator = allocator,
        .context = context,
        .n = n,
        .http_server = http_server,
        .buffer = buffer,
    };
}

pub fn deinit(self: *Request) void {
    self.conn.stream.close();
    self.res.deinit();
    self.context.deinit();
    self.allocator.destroy(self.context);
    self.allocator.destroy(self.http_server);
    self.allocator.free(self.buffer);
}

pub fn target(self: Request) []const u8 {
    return self.req.head.target;
}

pub fn method(self: Request) http.Method {
    return self.req.head.method;
}

pub fn json_data(self: *Request, T: type) !T {
    var reader = try self.req.reader();
    const data = try reader.readAllAlloc(self.allocator, 2046);
    defer self.allocator.free(data);
    var parsed = try std.json.parseFromSlice(T, self.allocator, data, .{});
    defer parsed.deinit();

    return parsed.value;
}
