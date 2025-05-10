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

            self.children.deinit();
            self.allocator.destroy(self.children);
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
                var total_len: usize = 0;
                for (current.children.items) |child| {
                    var found = true;
                    var exact_match = true;

                    var temp_total_len: usize = 0;
                    if (child.str.len == 1 and child.str[0] == '/') {
                        if (remaining_needle[0] != '/') {
                            found = false;
                        }
                    } else {
                        var it = std.mem.splitScalar(u8, child.str, '/');
                        var needle_it = std.mem.splitScalar(u8, remaining_needle, '/');
                        while (true) {
                            const part = it.next();
                            const needle_part = needle_it.next();
                            if (part == null) {
                                break;
                            }

                            if (needle_part == null) {
                                found = false;
                                break;
                            }

                            if (part.?.len == 0) {
                                if (needle_part.?.len != 0 and it.peek() != null) {
                                    found = false;
                                    break;
                                }
                                continue;
                            }

                            if (part.?[0] == ':') {
                                temp_total_len += needle_part.?.len;
                                exact_match = false;
                                continue;
                            }

                            temp_total_len += part.?.len;

                            if (part.?.len > needle_part.?.len) {
                                found = false;
                                break;
                            }

                            const m = part.?.len;

                            found = std.mem.eql(u8, part.?, needle_part.?[0..m]);
                        }
                    }

                    if (found) {
                        if (exact_match or (!exact_match and selected_child == null)) {
                            total_len = temp_total_len + std.mem.count(u8, child.str, "/");
                            selected_child = child;
                        }
                        if (exact_match) {
                            break;
                        }
                    }
                }
                if (selected_child == null) return null;
                current = selected_child.?;
                if (total_len == remaining_needle.len) {
                    return current.val;
                }
                remaining_needle = remaining_needle[total_len..];
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

    const expectEqual = std.testing.expectEqual;
    const expectEqualStrings = std.testing.expectEqualStrings;

    try expectEqual(radix.head.children.items.len, 1);
    try expectEqual(radix.head.children.items[0].val, 1);
    try expectEqualStrings(radix.head.children.items[0].str, "/");
    try expectEqual(radix.head.children.items[0].children.items.len, 1);
    try expectEqualStrings(radix.head.children.items[0].children.items[0].str, "s");
    try expectEqual(radix.head.children.items[0].children.items[0].val, null);
    try expectEqual(radix.head.children.items[0].children.items[0].children.items.len, 2);

    try expectEqualStrings(radix.head.children.items[0].children.items[0].children.items[0].str, "a");
    try expectEqualStrings(radix.head.children.items[0].children.items[0].children.items[1].str, "la");

    try expectEqual(radix.head.children.items[0].children.items[0].children.items[0].children.items.len, 2);
    try expectEqual(radix.head.children.items[0].children.items[0].children.items[1].children.items.len, 1);

    try expectEqualStrings(radix.head.children.items[0].children.items[0].children.items[0].children.items[0].str, "lam");
    try expectEqualStrings(radix.head.children.items[0].children.items[0].children.items[0].children.items[1].str, "dam");

    try expectEqualStrings(radix.head.children.items[0].children.items[0].children.items[1].children.items[0].str, "x");
}

test "Lookup" {
    var radix = try Radix(u8).init(std.testing.allocator);
    defer radix.deinit();

    try radix.insert("/", 1);
    try radix.insert("/salam", 2);
    try radix.insert("/sadam", 3);
    try radix.insert("/slax", 4);
    try radix.insert("/sla", 5);

    const expectEqual = std.testing.expectEqual;

    try expectEqual(radix.lookup("/"), 1);
    try expectEqual(radix.lookup("/s"), null);
    try expectEqual(radix.lookup("/sl"), null);
    try expectEqual(radix.lookup("/salam"), 2);
    try expectEqual(radix.lookup("/sadam"), 3);
    try expectEqual(radix.lookup("/slax"), 4);
    try expectEqual(radix.lookup("/sla"), 5);
}

test "Wildcard" {
    var radix = try Radix(u8).init(std.testing.allocator);
    defer radix.deinit();

    try radix.insert("/user/:id", 1);
    try radix.insert("/user/:id/e", 2);
    try radix.insert("/user/:id/e/:name", 3);

    const expectEqual = std.testing.expectEqual;

    try expectEqual(radix.lookup("/user/12"), 1);
    try expectEqual(radix.lookup("/user/32"), 1);
    try expectEqual(radix.lookup("/user/32/e"), 2);
    try expectEqual(radix.lookup("/user/32/e/salam"), 3);
    try expectEqual(radix.lookup("/user/32/x"), null);
}

test "Exact Overlap" {
    var radix = try Radix(u8).init(std.testing.allocator);
    defer radix.deinit();

    try radix.insert("/user/:id", 1);
    try radix.insert("/user/444", 2);

    const expectEqual = std.testing.expectEqual;

    try expectEqual(radix.lookup("/user/12"), 1);
    try expectEqual(radix.lookup("/user/32"), 1);
    try expectEqual(radix.lookup("/user/444"), 2);
}
