const std = @import("std");
const tree = @import("tree.zig");
const response = @import("response.zig");

const RoutesTree = tree.Radix(Route);
const Handler = fn (req: *Request) anyerror!void;

pub const Request = struct {
    const RequestSelf = @This();

    req: std.http.Server.Request,
    conn: std.net.Server.Connection,
    res: response.Response,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, conn: std.net.Server.Connection) !RequestSelf {
        var buffer: [1024]u8 = undefined;
        var http_server = std.http.Server.init(conn, &buffer);
        const req = try http_server.receiveHead();

        return .{
            .conn = conn,
            .req = req,
            .res = response.Response.init(allocator, req),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RequestSelf) void {
        self.conn.stream.close();
        self.res.deinit();
    }

    pub fn target(self: RequestSelf) []const u8 {
        return self.req.head.target;
    }

    pub fn method(self: RequestSelf) std.http.Method {
        return self.req.head.method;
    }

    pub fn json_data(self: *RequestSelf, T: type) !T {
        var reader = try self.req.reader();
        const data = try reader.readAllAlloc(self.allocator, 2046);
        defer self.allocator.free(data);
        var parsed = try std.json.parseFromSlice(T, self.allocator, data, .{});
        defer parsed.deinit();

        return parsed.value;
    }
};

const Route = struct {
    path: []const u8,
    handler: *const Handler,
    method: std.http.Method,
};
const Self = @This();

get_routes: RoutesTree,
post_routes: RoutesTree,
put_routes: RoutesTree,
patch_routes: RoutesTree,
delete_routes: RoutesTree,
server: std.net.Server,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, server: std.net.Server) !Self {
    return .{
        .get_routes = try RoutesTree.init(allocator),
        .post_routes = try RoutesTree.init(allocator),
        .put_routes = try RoutesTree.init(allocator),
        .patch_routes = try RoutesTree.init(allocator),
        .delete_routes = try RoutesTree.init(allocator),
        .server = server,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    self.get_routes.deinit();
    self.post_routes.deinit();
    self.patch_routes.deinit();
    self.put_routes.deinit();
    self.delete_routes.deinit();
}

// Get route
pub fn get(self: *Self, path: []const u8, handler: *const Handler) !void {
    try self.add_route(.{
        .path = path,
        .handler = handler,
        .method = .GET,
    });
}

pub fn post(self: *Self, path: []const u8, handler: *const Handler) !void {
    try self.add_route(.{
        .path = path,
        .handler = handler,
        .method = .POST,
    });
}

pub fn put(self: *Self, path: []const u8, handler: *const Handler) !void {
    try self.add_route(.{
        .path = path,
        .handler = handler,
        .method = .PUT,
    });
}

pub fn patch(self: *Self, path: []const u8, handler: *const Handler) !void {
    try self.add_route(.{
        .path = path,
        .handler = handler,
        .method = .PATCH,
    });
}

pub fn delete(self: *Self, path: []const u8, handler: *const Handler) !void {
    try self.add_route(.{
        .path = path,
        .handler = handler,
        .method = .DELETE,
    });
}

fn add_route(self: *Self, route: Route) !void {
    var route_tree = switch (route.method) {
        .GET => self.get_routes,
        .POST => self.post_routes,
        .PATCH => self.patch_routes,
        .PUT => self.put_routes,
        .DELETE => self.delete_routes,
        else => unreachable,
    };

    try route_tree.insert(route.path, route);
}

pub fn run(self: *Self) !void {
    while (true) {
        try self.handleConnection(try self.server.accept());
    }
}

fn handleConnection(self: *Self, conn: std.net.Server.Connection) !void {
    var request = try Request.init(self.allocator, conn);
    defer request.deinit();

    // var reader = try req.reader();
    std.debug.print("{s}|||{}\n", .{ request.target(), request.method() });
    // reader.readAllAlloc(self.allocator, 0);
    if (request.method() == .GET) {
        const route = self.get_routes.lookup(request.target());
        if (route) |r| {
            try r.handler(&request);
            return;
        }
    }

    try request.req.respond("Not found", std.http.Server.Request.RespondOptions{ .status = .not_found });
}
