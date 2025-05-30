const std = @import("std");
const tree = @import("tree.zig");
const Response = @import("Response.zig");
const Request = @import("Request.zig");
const http = std.http;

const Allocator = std.mem.Allocator;
const RoutesTree = tree.Radix(Route);
const Handler = fn (req: *Request) anyerror!void;

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
    allocator: std.mem.Allocator,
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
    while (args.running.*) {
        args.mu.lock();

        if (args.queue.items.len < 1) {
            args.cond.wait(args.mu);
        }

        if (!args.running.*) {
            args.mu.unlock();
            break;
        }

        const r = args.queue.pop().?;

        var req: *Request = r[0];
        const route = r[1];

        args.mu.unlock();

        std.debug.print("{} Handled by {}\n", .{ req.n, args.n });

        defer args.allocator.destroy(req);
        defer req.deinit();

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
    self.allocator.destroy(self.cond);
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
            .allocator = self.allocator,
        }});
    }

    _ = try std.Thread.spawn(.{}, accept, .{self});

    for (0..t_cnt) |i| {
        threads[i].join();
    }
}

fn accept(self: *Self) !void {
    while (self.running) {
        self.handleConnection(try self.server.accept()) catch |e| {
            // TODO: ???
            std.debug.print("{any}", .{e});
        };
    }
}

pub fn stop(self: *Self) void {
    self.running = false;
    self.cond.broadcast();
}

fn handleConnection(self: *Self, conn: std.net.Server.Connection) !void {
    const context = try self.allocator.create(Request.Context);
    context.* = Request.Context.init(self.allocator);
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
