const print = @import("std").debug.print;
const std = @import("std");
const http = std.http;
const Router = @import("./router.zig");
const tree = @import("./tree.zig");
const response = @import("response.zig");

const Random = struct {
    random: u64,
};

var allocator: std.mem.Allocator = undefined;

pub fn main() !void {
    print("hi\n", .{});
    // var server = try socket.create(.ipv4, .tcp);
    // defer server.close();

    // try server.bind(try socket.Endpoint.parse("0.0.0.0:8890"));

    // try server.listen();

    // std.time.sleep(10000000000);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    allocator = gpa.allocator();

    const addr = try std.net.Address.parseIp4("0.0.0.0", 8890);
    var server = try addr.listen(std.net.Address.ListenOptions{ .reuse_address = true });
    defer server.deinit();

    var router = try Router.init(allocator, server);
    defer router.deinit();
    try router.get("/salam", salamHandler);
    try router.get("/salam/:text", salamHandler);

    try router.run();
}

fn salamHandler(req: *Router.Request) !void {
    const data = try req.json_data(Random);

    try req.res.json(Random{ .random = data.random });
}
