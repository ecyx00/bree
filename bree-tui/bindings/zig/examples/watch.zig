const std = @import("std");
const bree = @import("bree_tui");

fn requirePublicDecl(
    comptime Container: type,
    comptime name: []const u8,
) void {
    if (!@hasDecl(Container, name)) {
        @compileError(std.fmt.comptimePrint(
            "{s} must expose {s}",
            .{ @typeName(Container), name },
        ));
    }
}

fn rejectPublicDecl(
    comptime Container: type,
    comptime name: []const u8,
) void {
    if (@hasDecl(Container, name)) {
        @compileError(std.fmt.comptimePrint(
            "{s} must not expose {s}",
            .{ @typeName(Container), name },
        ));
    }
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var client = try bree.Client.connect(allocator, .{});
    defer client.deinit();

    var machines = try client.machines();
    defer machines.deinit();
    for (machines.items) |machine| {
        std.debug.print(
            "{s}\t{s}\t{s}\n",
            .{
                machine.id.slice(),
                machine.name,
                machine.status.wireName(),
            },
        );
    }
}

test "package consumer imports handwritten root and generated raw module" {
    comptime {
        requirePublicDecl(bree.Machine, "listSessions");
        rejectPublicDecl(bree.Machine, "close");
        rejectPublicDecl(bree.Machine, "rename");
        requirePublicDecl(bree.Session, "createWorkspace");
        requirePublicDecl(bree.Session, "terminal");
        rejectPublicDecl(bree.Session, "navigate");
        requirePublicDecl(bree.Workspace, "run");
        rejectPublicDecl(bree.Workspace, "terminal");
        rejectPublicDecl(bree.Workspace, "sendKeys");
        requirePublicDecl(bree.Screen, "undoLayout");
        rejectPublicDecl(bree.Screen, "run");
        requirePublicDecl(bree.Pane, "splitPane");
        rejectPublicDecl(bree.Pane, "navigate");
        requirePublicDecl(bree.Tab, "moveTab");
        rejectPublicDecl(bree.Tab, "run");
        requirePublicDecl(bree.Terminal, "waitForExit");
        rejectPublicDecl(bree.Terminal, "resizeTerminalViewer");
        rejectPublicDecl(bree.Terminal, "navigate");
        requirePublicDecl(bree.Browser, "navigate");
        rejectPublicDecl(bree.Browser, "readScreen");
        rejectPublicDecl(bree.PairingRequest, "refresh");
        requirePublicDecl(
            bree.TerminalAttachmentStream,
            "resizeTerminalViewer",
        );
        rejectPublicDecl(
            bree.TerminalAttachmentStream,
            "resizeBrowserViewer",
        );
        requirePublicDecl(
            bree.BrowserAttachmentStream,
            "resizeBrowserViewer",
        );
        rejectPublicDecl(
            bree.BrowserAttachmentStream,
            "resizeTerminalViewer",
        );
        rejectPublicDecl(
            bree.SessionEventStream,
            "resizeTerminalViewer",
        );
        rejectPublicDecl(bree, "Notification");
        rejectPublicDecl(bree, "Agent");
    }

    const workspace = try bree.WorkspaceId.parse(
        "ws_0123456789abcdef0123456789abcdef",
    );
    var selector = bree.Selector(bree.WorkspaceId){ .name = "current" };
    const encoded = try selector.formatAlloc(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("name:current", encoded);
    try std.testing.expectEqualStrings(
        "ws_0123456789abcdef0123456789abcdef",
        workspace.slice(),
    );
    const pointer_frame_seq = std.math.maxInt(u64);
    const mouse = bree.BrowserMouseOptions{
        .kind = .move,
        .x_px = 12,
        .y_px = 34,
        .pointer_frame_seq = pointer_frame_seq,
    };
    const wheel = bree.BrowserWheelOptions{
        .delta_x = 0,
        .delta_y = 1,
        .pointer_frame_seq = pointer_frame_seq,
    };
    try std.testing.expectEqual(
        pointer_frame_seq,
        mouse.pointer_frame_seq,
    );
    try std.testing.expectEqual(
        pointer_frame_seq,
        wheel.pointer_frame_seq,
    );
    try std.testing.expectEqual(
        @as(usize, 118),
        bree.raw.protocol.command_count,
    );
    try std.testing.expectEqual(
        @as(usize, 50),
        bree.raw.protocol.event_count,
    );
    try std.testing.expect(
        @hasDecl(bree.Client, "listMachines"),
    );
    try std.testing.expect(
        @hasDecl(bree.Machine, "listSessions"),
    );
    try std.testing.expect(
        @hasDecl(bree.Session, "listWorkspaces"),
    );
    try std.testing.expect(@hasDecl(bree.Terminal, "readScreen"));
    try std.testing.expect(@hasDecl(bree.Terminal, "readState"));
    try std.testing.expect(@hasDecl(bree.Terminal, "readHistory"));
    try std.testing.expect(@hasDecl(bree.Terminal, "processInfo"));
    try std.testing.expect(@hasDecl(bree, "TerminalScreenResult"));
    try std.testing.expect(@hasDecl(bree, "UndoLayoutOptions"));
    try std.testing.expect(
        @hasDecl(bree, "MutationTransportUncertain"),
    );
    try std.testing.expect(
        @hasDecl(bree.Client, "takeMutationTransportUncertain"),
    );
    try std.testing.expect(!@hasDecl(bree, "MutationResult"));
    try std.testing.expect(!@hasDecl(bree, "OwnedResult"));

    // Handle construction stores selectors and routes without touching the
    // client, so an external consumer can compose a route before connecting.
    var offline_client: bree.Client = undefined;
    const terminal = offline_client
        .machine(.current)
        .session(.{ .name = "main" })
        .workspace(.{ .name = "sdk" })
        .screen(.current)
        .pane(.current)
        .tab(.current)
        .terminal(.{ .name = "shell" });
    try std.testing.expect(terminal.id() == null);

    const terminal_id = try bree.TerminalId.parse(
        "term_0123456789abcdef0123456789abcdef",
    );
    const grant = try bree.RendererGrant.init(std.testing.allocator, .{
        .endpoint = "/tmp/bree-renderer.sock",
        .terminal_id = terminal_id,
        .token = .{ .bytes = "secret" },
        .rights = &.{ "read", "input" },
        .ttl_ms = 5_000,
    });
    defer grant.deinit();
    try std.testing.expectEqualStrings(
        "/tmp/bree-renderer.sock",
        grant.endpoint(),
    );
}
