const std = @import("std");
const tree = @import("tree.zig");
const response = @import("response.zig");
const http = std.http;

const Allocator = std.mem.Allocator;
const RoutesTree = tree.Radix(Route);
const Handler = fn (req: *Request) anyerror!void;

const Context = struct {
    const ContextSelf = @This();
    params: std.StringHashMap([]const u8),

    fn init(allocator: Allocator) ContextSelf {
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

pub const Request = struct {
    const RequestSelf = @This();

    req: http.Server.Request,
    conn: std.net.Server.Connection,
    res: response.Response,
    allocator: std.mem.Allocator,
    context: *Context,
    n: i64,
    http_server: *http.Server,
    buffer: []u8,

    pub fn init(allocator: std.mem.Allocator, conn: std.net.Server.Connection, context: *Context, n: i64) !RequestSelf {
        const buffer = try allocator.alloc(u8, 1028);
        var http_server = try allocator.create(http.Server);
        http_server.* = http.Server.init(conn, buffer);
        const req = try http_server.receiveHead();

        return .{
            .conn = conn,
            .req = req,
            .res = response.Response.init(allocator, req),
            .allocator = allocator,
            .context = context,
            .n = n,
            .http_server = http_server,
            .buffer = buffer,
        };
    }

    pub fn deinit(self: *RequestSelf) void {
        self.conn.stream.close();
        self.res.deinit();
        self.context.deinit();
        self.allocator.destroy(self.req);
        self.allocator.destroy(self.http_server);
        self.allocator.free(self.buffer);
    }

    pub fn target(self: RequestSelf) []const u8 {
        return self.req.head.target;
    }

    pub fn method(self: RequestSelf) http.Method {
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
    method: http.Method,
};

const Self = @This();
const RequestTuple = std.meta.Tuple(&.{ *Request, Route });

const ThreadArgs = struct {
    cond: *std.Thread.Condition,
    mu: *std.Thread.Mutex,
    queue: *std.ArrayList(RequestTuple),
    running: *bool,
    n: usize,
};

get_routes: RoutesTree,
post_routes: RoutesTree,
put_routes: RoutesTree,
patch_routes: RoutesTree,
delete_routes: RoutesTree,
server: std.net.Server,
allocator: std.mem.Allocator,
running: bool,
n: i64,

queue: *std.ArrayList(RequestTuple),
mu: *std.Thread.Mutex,
cond: *std.Thread.Condition,

fn enqueue(self: *Self, tuple: RequestTuple) !void {
    self.mu.lock();
    defer self.mu.unlock();
    try self.queue.append(tuple);
    self.cond.signal();
}

fn exec_thread(args: ThreadArgs) void {
    while (true) {
        args.mu.lock();

        if (args.queue.items.len < 1) {
            args.cond.wait(args.mu);
        }

        const r = args.queue.pop().?;

        const req = r[0];
        const route = r[1];

        args.mu.unlock();

        std.debug.print("{} Handled by {}\n", .{ req.n, args.n });

        route.handler(req) catch |e| std.debug.print("{any}", .{e});
    }
}

pub fn init(allocator: std.mem.Allocator, server: std.net.Server) !Self {
    const mu = try allocator.create(std.Thread.Mutex);
    mu.* = std.Thread.Mutex{};

    const queue = try allocator.create(std.ArrayList(RequestTuple));
    queue.* = std.ArrayList(RequestTuple).init(allocator);

    const cond = try allocator.create(std.Thread.Condition);
    cond.* = std.Thread.Condition{};

    return .{
        .get_routes = try RoutesTree.init(allocator),
        .post_routes = try RoutesTree.init(allocator),
        .put_routes = try RoutesTree.init(allocator),
        .patch_routes = try RoutesTree.init(allocator),
        .delete_routes = try RoutesTree.init(allocator),
        .server = server,
        .allocator = allocator,
        .running = true,
        .queue = queue,
        .mu = mu,
        .cond = cond,
        .n = 0,
    };
}

pub fn deinit(self: *Self) void {
    self.get_routes.deinit();
    self.post_routes.deinit();
    self.patch_routes.deinit();
    self.put_routes.deinit();
    self.delete_routes.deinit();
    self.queue.deinit();
    self.allocator.destroy(self.queue);
    self.allocator.destroy(self.mu);
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

fn routes_tree(self: *Self, method: http.Method) RoutesTree {
    return switch (method) {
        .GET => self.get_routes,
        .POST => self.post_routes,
        .PATCH => self.patch_routes,
        .PUT => self.put_routes,
        .DELETE => self.delete_routes,
        else => unreachable,
    };
}

fn add_route(self: *Self, route: Route) !void {
    var rt = self.routes_tree(route.method);

    try rt.insert(route.path, route);
}

pub fn run(self: *Self) !void {
    // run workers
    const t_cnt = 4;
    var threads: [t_cnt]std.Thread = undefined;

    for (0..t_cnt) |i| {
        threads[i] = try std.Thread.spawn(.{}, exec_thread, .{ThreadArgs{
            .cond = self.cond,
            .mu = self.mu,
            .queue = self.queue,
            .running = &self.running,
            .n = i,
        }});
    }
    while (self.running) {
        // if server accpet fails everything fails else we are fine!
        // How to stop the server?
        self.handleConnection(try self.server.accept()) catch |e| {
            // TODO: ???
            std.debug.print("{any}", .{e});
        };
    }

    for (0..t_cnt) |i| {
        threads[i].join();
    }
}

fn handleConnection(self: *Self, conn: std.net.Server.Connection) !void {
    const context = try self.allocator.create(Context);
    context.* = Context.init(self.allocator);
    const request = try self.allocator.create(Request);
    self.n += 1;
    request.* = try Request.init(self.allocator, conn, context, self.n);

    std.debug.print("{s}|||{}\n", .{ request.target(), request.method() });

    const route = self.resolve(request);

    if (route) |r| {
        try self.enqueue(.{ request, r });
        // try r.handler(request);
    } else {
        try request.req.respond("Not found", http.Server.Request.RespondOptions{ .status = .not_found });
    }
}

fn resolve(self: *Self, request: *Request) ?Route {
    var rt = self.routes_tree(request.method());
    const route = rt.lookup(request.target());
    return route;
}
