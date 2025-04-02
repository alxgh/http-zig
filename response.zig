const std = @import("std");
const http = std.http;

pub const Response = struct {
    const Self = @This();

    req: http.Server.Request,
    allocator: std.mem.Allocator,
    headers: std.ArrayList(http.Header),
    status: http.Status,

    pub fn init(allocator: std.mem.Allocator, req: http.Server.Request) Self {
        return .{
            .req = req,
            .headers = std.ArrayList(http.Header).init(allocator),
            .allocator = allocator,
            .status = .ok,
        };
    }

    pub fn deinit(self: *Self) void {
        self.headers.deinit();
    }

    pub fn add_header(self: *Self, name: []const u8, value: []const u8) !void {
        try self.headers.append(.{
            .name = name,
            .value = value,
        });
    }

    pub fn set_status(self: *Self, s: http.Status) void {
        self.status = s;
    }

    pub fn json(self: *Self, data: anytype) !void {
        var json_data = std.ArrayList(u8).init(self.allocator);
        defer json_data.deinit();
        try self.add_header("Content-Type", "application/json");
        try std.json.stringify(
            data,
            .{},
            json_data.writer(),
        );

        try self.respond(json_data.items);
    }

    pub fn respond(self: *Self, content: []const u8) !void {
        try self.req.respond(
            content,
            .{
                .extra_headers = self.headers.items,
                .status = self.status,
            },
        );
    }
};
