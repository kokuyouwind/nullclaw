//! MCP (Model Context Protocol) — stdio transport server.
//!
//! Exposes nullclaw's Tool vtable as an MCP server over newline-delimited
//! JSON-RPC 2.0 on stdin/stdout. Intended for use with Claude Code's
//! --mcp-config flag so that the Claude CLI provider can natively call
//! nullclaw tools (cron, memory, etc.) without XML tool_call hacks.

const std = @import("std");
const tools_mod = @import("tools/root.zig");
const json_util = @import("json_util.zig");
const version = @import("version.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.mcp_server);

/// Run the MCP server loop on stdin/stdout.
/// Blocks until stdin is closed or an unrecoverable error occurs.
pub fn run(allocator: Allocator, tool_list: []const tools_mod.Tool) !void {
    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    while (true) {
        const line = readLine(allocator, stdin) catch |err| switch (err) {
            error.EndOfStream => return,
            error.EmptyLine => continue,
            else => {
                log.err("stdin read error: {}", .{err});
                return err;
            },
        };
        defer allocator.free(line);

        handleMessage(allocator, stdout, line, tool_list) catch |err| {
            log.err("failed to handle message: {}", .{err});
        };
    }
}

// ── Message handler ─────────────────────────────────────────────

fn handleMessage(
    allocator: Allocator,
    stdout: std.fs.File,
    line: []const u8,
    tool_list: []const tools_mod.Tool,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        // Invalid JSON — send parse error if we can guess an id
        try writeErrorResponse(allocator, stdout, null, -32700, "Parse error");
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try writeErrorResponse(allocator, stdout, null, -32600, "Invalid Request");
        return;
    }
    const obj = parsed.value.object;

    const method_val = obj.get("method") orelse {
        try writeErrorResponse(allocator, stdout, obj.get("id"), -32600, "Invalid Request: missing method");
        return;
    };
    if (method_val != .string) {
        try writeErrorResponse(allocator, stdout, obj.get("id"), -32600, "Invalid Request: method must be string");
        return;
    }
    const method = method_val.string;

    // Notifications (no id) — just acknowledge silently
    if (obj.get("id") == null) {
        // notifications/initialized, etc. — nothing to do
        return;
    }

    const id = obj.get("id").?;

    if (std.mem.eql(u8, method, "initialize")) {
        try handleInitialize(allocator, stdout, id);
    } else if (std.mem.eql(u8, method, "tools/list")) {
        try handleToolsList(allocator, stdout, id, tool_list);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        const params = obj.get("params");
        try handleToolsCall(allocator, stdout, id, params, tool_list);
    } else {
        try writeErrorResponse(allocator, stdout, id, -32601, "Method not found");
    }
}

// ── Method handlers ─────────────────────────────────────────────

fn handleInitialize(allocator: Allocator, stdout: std.fs.File, id: std.json.Value) !void {
    const result = try std.fmt.allocPrint(allocator,
        \\{{"protocolVersion":"2024-11-05","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"nullclaw","version":"{s}"}}}}
    , .{version.string});
    defer allocator.free(result);

    try writeResponse(allocator, stdout, id, result);
}

fn handleToolsList(
    allocator: Allocator,
    stdout: std.fs.File,
    id: std.json.Value,
    tool_list: []const tools_mod.Tool,
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"tools\":[");

    for (tool_list, 0..) |t, i| {
        if (i > 0) try buf.append(allocator, ',');

        try buf.append(allocator, '{');

        // "name":"..."
        try json_util.appendJsonKey(&buf, allocator, "name");
        try json_util.appendJsonString(&buf, allocator, t.name());

        // ,"description":"..."
        try buf.append(allocator, ',');
        try json_util.appendJsonKey(&buf, allocator, "description");
        try json_util.appendJsonString(&buf, allocator, t.description());

        // ,"inputSchema":...
        try buf.appendSlice(allocator, ",\"inputSchema\":");
        const params = t.parametersJson();
        if (params.len > 0) {
            try buf.appendSlice(allocator, params);
        } else {
            try buf.appendSlice(allocator, "{\"type\":\"object\",\"properties\":{}}");
        }

        try buf.append(allocator, '}');
    }

    try buf.appendSlice(allocator, "]}");
    try writeResponse(allocator, stdout, id, buf.items);
}

fn handleToolsCall(
    allocator: Allocator,
    stdout: std.fs.File,
    id: std.json.Value,
    params: ?std.json.Value,
    tool_list: []const tools_mod.Tool,
) !void {
    const p = params orelse {
        try writeErrorResponse(allocator, stdout, id, -32602, "Invalid params: missing params");
        return;
    };
    if (p != .object) {
        try writeErrorResponse(allocator, stdout, id, -32602, "Invalid params: params must be object");
        return;
    }

    const name_val = p.object.get("name") orelse {
        try writeErrorResponse(allocator, stdout, id, -32602, "Invalid params: missing tool name");
        return;
    };
    if (name_val != .string) {
        try writeErrorResponse(allocator, stdout, id, -32602, "Invalid params: name must be string");
        return;
    }
    const tool_name = name_val.string;

    // Find the tool
    var found_tool: ?tools_mod.Tool = null;
    for (tool_list) |t| {
        if (std.mem.eql(u8, t.name(), tool_name)) {
            found_tool = t;
            break;
        }
    }

    const t = found_tool orelse {
        const msg = try std.fmt.allocPrint(allocator, "Unknown tool: {s}", .{tool_name});
        defer allocator.free(msg);
        try writeErrorResponse(allocator, stdout, id, -32602, msg);
        return;
    };

    // Extract arguments (default to empty object)
    const args_val = p.object.get("arguments");
    var empty_obj = std.json.ObjectMap.init(allocator);
    defer empty_obj.deinit();
    const args: std.json.ObjectMap = if (args_val) |av|
        (if (av == .object) av.object else empty_obj)
    else
        empty_obj;

    // Execute the tool
    const result = t.execute(allocator, args) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Tool execution error: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        try writeErrorResponse(allocator, stdout, id, -32000, msg);
        return;
    };

    // Build MCP tool result response
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"content\":[{\"type\":\"text\",\"text\":");

    // Use the output or error_msg
    const text = if (result.success)
        result.output
    else
        (result.error_msg orelse result.output);

    try json_util.appendJsonString(&buf, allocator, text);
    try buf.appendSlice(allocator, "}]");

    if (!result.success) {
        try buf.appendSlice(allocator, ",\"isError\":true");
    }

    try buf.append(allocator, '}');

    try writeResponse(allocator, stdout, id, buf.items);
}

// ── JSON-RPC response writers ───────────────────────────────────

fn writeResponse(allocator: Allocator, stdout: std.fs.File, id: std.json.Value, result: []const u8) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":");
    try buf.appendSlice(allocator, result);
    try buf.appendSlice(allocator, "}\n");

    var write_buf: [256]u8 = undefined;
    var bw = stdout.writer(&write_buf);
    try bw.interface.writeAll(buf.items);
    try bw.interface.flush();
}

fn writeErrorResponse(allocator: Allocator, stdout: std.fs.File, id: ?std.json.Value, code: i32, message: []const u8) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |i| {
        try appendJsonValue(&buf, allocator, i);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\"error\":{\"code\":");
    const code_str = try std.fmt.allocPrint(allocator, "{d}", .{code});
    defer allocator.free(code_str);
    try buf.appendSlice(allocator, code_str);
    try buf.appendSlice(allocator, ",\"message\":");
    try json_util.appendJsonString(&buf, allocator, message);
    try buf.appendSlice(allocator, "}}\n");

    var write_buf: [256]u8 = undefined;
    var bw = stdout.writer(&write_buf);
    try bw.interface.writeAll(buf.items);
    try bw.interface.flush();
}

// ── Helpers ─────────────────────────────────────────────────────

fn appendJsonValue(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, val: std.json.Value) !void {
    switch (val) {
        .integer => |i| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{i});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .string => |s| {
            try json_util.appendJsonString(buf, allocator, s);
        },
        .null => {
            try buf.appendSlice(allocator, "null");
        },
        else => {
            // Fallback: format as JSON
            const s = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(val, .{})});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
    }
}

fn readLine(allocator: Allocator, file: std.fs.File) ![]const u8 {
    var line_buf: std.ArrayList(u8) = .{};
    errdefer line_buf.deinit(allocator);
    var byte: [1]u8 = undefined;
    while (true) {
        const n = file.read(&byte) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        if (byte[0] == '\n') break;
        if (byte[0] != '\r') {
            try line_buf.append(allocator, byte[0]);
        }
    }
    if (line_buf.items.len == 0) {
        line_buf.deinit(allocator);
        return error.EmptyLine;
    }
    return line_buf.toOwnedSlice(allocator);
}

// ── Tests ───────────────────────────────────────────────────────

test "handleInitialize produces valid JSON response" {
    // We test by capturing what would be written to stdout
    // For now, just test the format string
    const result = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"protocolVersion":"2024-11-05","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"nullclaw","version":"{s}"}}}}
    , .{version.string});
    defer std.testing.allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const proto = parsed.value.object.get("protocolVersion").?;
    try std.testing.expectEqualStrings("2024-11-05", proto.string);
}

test "readLine returns line content" {
    // Create a pipe for testing
    const pipe = try std.posix.pipe();
    defer std.posix.close(pipe[0]);
    defer std.posix.close(pipe[1]);

    const write_file = std.fs.File{ .handle = pipe[1] };
    const read_file = std.fs.File{ .handle = pipe[0] };

    try write_file.writeAll("{\"test\":true}\n");
    const line = try readLine(std.testing.allocator, read_file);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("{\"test\":true}", line);
}

test "readLine strips CR" {
    const pipe = try std.posix.pipe();
    defer std.posix.close(pipe[0]);
    defer std.posix.close(pipe[1]);

    const write_file = std.fs.File{ .handle = pipe[1] };
    const read_file = std.fs.File{ .handle = pipe[0] };

    try write_file.writeAll("hello\r\n");
    const line = try readLine(std.testing.allocator, read_file);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("hello", line);
}

test "appendJsonValue integer" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendJsonValue(&buf, std.testing.allocator, .{ .integer = 42 });
    try std.testing.expectEqualStrings("42", buf.items);
}

test "appendJsonValue string" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendJsonValue(&buf, std.testing.allocator, .{ .string = "hello" });
    try std.testing.expectEqualStrings("\"hello\"", buf.items);
}

test "appendJsonValue null" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendJsonValue(&buf, std.testing.allocator, .null);
    try std.testing.expectEqualStrings("null", buf.items);
}
