const std = @import("std");
const Router = @import("./Router.zig");

var sig_broadcast = std.Thread.Condition{};

pub fn graceful_shutdown(router: *Router) !void {
    const handler_struct = struct {
        fn handler_posix(sig: c_int) callconv(.C) void {
            std.debug.assert(sig == std.posix.SIG.INT);
            sig_broadcast.broadcast();
        }

        fn broadcast(r: *Router) void {
            var mu = std.Thread.Mutex{};
            mu.lock();
            defer mu.unlock();
            sig_broadcast.wait(&mu);
            r.stop();
        }
    };
    const act = std.posix.Sigaction{
        .handler = .{
            .handler = handler_struct.handler_posix,
        },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    _ = try std.Thread.spawn(.{}, handler_struct.broadcast, .{router});
}
