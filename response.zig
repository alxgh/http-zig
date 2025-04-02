const std = @import("std");
const http = std.http;

pub const Response = struct {
    const Self = @This();

    req: http.Server.Request,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, req: http.Server.Request) Self {
        return .{
            .req = req,
            .allocator = allocator,
        };
    }

    pub fn json(self: *Self, data: anytype) !void {
        var json_data = std.ArrayList(u8).init(self.allocator);
        defer json_data.deinit();
        try std.json.stringify(data, .{}, json_data.writer());

        // TODO: Move to another method

        try self.req.respond(json_data.items, .{});
    }
};
