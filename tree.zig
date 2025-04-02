const std = @import("std");
const Allocator = std.mem.Allocator;
pub fn Radix(comptime T: type) type {
    const Node = struct {
        const NodeSelf = @This();
        const NodeArrayList = std.ArrayList(*NodeSelf);
        children: *NodeArrayList,
        str: []const u8,
        val: ?T,
        allocator: Allocator,

        pub fn init(allocator: Allocator, str: []const u8, val: ?T) !NodeSelf {
            const children = try allocator.create(NodeArrayList);
            children.* = NodeArrayList.init(allocator);
            return .{
                .children = children,
                .str = str,
                .val = val,
                .allocator = allocator,
            };
        }

        pub fn reset_children(self: *NodeSelf) !void {
            self.children.clearAndFree();
        }

        pub fn pointer_init(allocator: Allocator, str: []const u8, val: ?T) !*NodeSelf {
            const node = try allocator.create(NodeSelf);
            node.* = try NodeSelf.init(allocator, str, val);
            return node;
        }

        pub fn deinit(self: *NodeSelf) void {
            for (self.children.items) |child| {
                child.deinit();
                self.allocator.destroy(child);
            }

            self.allocator.destroy(self.children);
            self.children.deinit();
        }
    };

    return struct {
        const Self = @This();

        head: *Node,
        allocator: Allocator,

        pub fn init(allocator: Allocator) !Self {
            return .{
                .allocator = allocator,
                .head = try Node.pointer_init(allocator, "", undefined),
            };
        }

        pub fn deinit(self: *Self) void {
            self.head.deinit();
            self.allocator.destroy(self.head);
        }

        pub fn lookup(self: *Self, needle: []const u8) ?T {
            var current = self.head;
            var remaining_needle = needle;

            while (true) {
                var selected_child: ?*Node = null;
                var m: u64 = 0;
                for (current.children.items) |child| {
                    if (remaining_needle.len < child.str.len) {
                        continue;
                    }
                    m = child.str.len;
                    if (std.mem.eql(u8, child.str[0..m], remaining_needle[0..m])) {
                        selected_child = child;
                        break;
                    }
                }

                if (selected_child == null) return null;
                current = selected_child.?;
                if (m == remaining_needle.len) {
                    return current.val;
                }
                remaining_needle = remaining_needle[m..];
            }
        }

        pub fn insert(self: *Self, str: []const u8, val: T) !void {
            var remaining_str = str;
            var current = self.head;

            while (true) {
                var most_common_prefix_len: u64 = 0;
                var selected_node: *Node = undefined;
                var found = false;

                for (current.children.items) |child| {
                    var i: u64 = 0;
                    while (i < @min(child.str.len, remaining_str.len)) : (i += 1) {
                        if (child.str[i] != remaining_str[i]) {
                            break;
                        }
                    }
                    if (i > most_common_prefix_len) {
                        found = true;
                        most_common_prefix_len = i;
                        selected_node = child;
                    }
                }

                if (!found) {
                    try current.children.append(try Node.pointer_init(self.allocator, remaining_str, val));
                    break;
                }

                current = selected_node;

                if (most_common_prefix_len == selected_node.str.len) {
                    remaining_str = remaining_str[most_common_prefix_len..];
                    continue;
                }

                const selected_node_str = selected_node.str;

                const new_node_str = selected_node_str[most_common_prefix_len..];
                const new_node = try Node.pointer_init(self.allocator, new_node_str, selected_node.val);
                try new_node.children.appendSlice(selected_node.children.items);
                selected_node.val = null;
                selected_node.str = selected_node_str[0..most_common_prefix_len];
                try selected_node.reset_children();
                try selected_node.children.append(new_node);

                if (most_common_prefix_len == remaining_str.len) {
                    selected_node.val = val;
                    break;
                }

                remaining_str = remaining_str[most_common_prefix_len..];
            }
        }
    };
}

test "Insert test" {
    var radix = try Radix(u8).init(std.testing.allocator);
    defer radix.deinit();
    try radix.insert("/", 1);
    try radix.insert("/salam", 2);
    try radix.insert("/sadam", 3);
    try radix.insert("/slax", 4);
    try radix.insert("/sla", 5);

    const assert = std.debug.assert;

    assert(radix.head.children.items.len == 1);
    assert(radix.head.children.items[0].val == 1);
    assert(std.mem.eql(u8, radix.head.children.items[0].str, "/"));
    assert(radix.head.children.items[0].children.items.len == 1);
    assert(std.mem.eql(u8, radix.head.children.items[0].children.items[0].str, "s"));
    assert(radix.head.children.items[0].children.items[0].val == null);
    assert(radix.head.children.items[0].children.items[0].children.items.len == 2);

    assert(std.mem.eql(u8, radix.head.children.items[0].children.items[0].children.items[0].str, "a"));
    assert(std.mem.eql(u8, radix.head.children.items[0].children.items[0].children.items[1].str, "la"));

    assert(radix.head.children.items[0].children.items[0].children.items[0].children.items.len == 2);
    assert(radix.head.children.items[0].children.items[0].children.items[1].children.items.len == 1);

    assert(std.mem.eql(u8, radix.head.children.items[0].children.items[0].children.items[0].children.items[0].str, "lam"));
    assert(std.mem.eql(u8, radix.head.children.items[0].children.items[0].children.items[0].children.items[1].str, "dam"));

    assert(std.mem.eql(u8, radix.head.children.items[0].children.items[0].children.items[1].children.items[0].str, "x"));

    for (radix.head.children.items) |child| {
        std.log.debug("{s}\n", .{child.str});
    }
}

test "Lookup" {
    var radix = try Radix(u8).init(std.testing.allocator);
    defer radix.deinit();

    try radix.insert("/", 1);
    try radix.insert("/salam", 2);
    try radix.insert("/sadam", 3);
    try radix.insert("/slax", 4);
    try radix.insert("/sla", 5);

    const assert = std.debug.assert;

    assert(radix.lookup("/") == 1);
    assert(radix.lookup("/s") == null);
    assert(radix.lookup("/sl") == null);
    assert(radix.lookup("/salam") == 2);
    assert(radix.lookup("/sadam") == 3);
    assert(radix.lookup("/slax") == 4);
    assert(radix.lookup("/sla") == 5);
}
