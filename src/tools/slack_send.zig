//! Slack Send Tool — direct Slack API message posting for MCP server.
//!
//! Unlike the bus-based MessageTool, this tool calls the Slack chat.postMessage
//! API directly using a bot token. Designed for use in the MCP server process
//! where no event bus is available.

const std = @import("std");
const root = @import("root.zig");
const http_util = @import("../http_util.zig");
const json_util = @import("../json_util.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

pub const SlackSendTool = struct {
    bot_token: []const u8,

    pub const tool_name = "slack_send";
    pub const tool_description = "Send a message to a Slack channel. Use this for proactive posting (announcements, daily reports, status updates). Requires a channel ID (e.g. 'CHDBZNKNJ'). Optionally specify thread_ts to reply in a thread.";
    pub const tool_params =
        \\{"type":"object","properties":{"channel":{"type":"string","description":"Slack channel ID to post to (e.g. 'CHDBZNKNJ')"},"text":{"type":"string","description":"Message text (supports Slack mrkdwn formatting)"},"thread_ts":{"type":"string","description":"Thread timestamp to reply to (optional, for threaded replies)"}},"required":["channel","text"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *SlackSendTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *SlackSendTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const channel = root.getString(args, "channel") orelse
            return ToolResult.fail("Missing required 'channel' parameter");
        const text = root.getString(args, "text") orelse
            return ToolResult.fail("Missing required 'text' parameter");
        const thread_ts = root.getString(args, "thread_ts");

        if (std.mem.trim(u8, text, " \t\n\r").len == 0)
            return ToolResult.fail("'text' must not be empty");

        if (std.mem.trim(u8, channel, " \t\n\r").len == 0)
            return ToolResult.fail("'channel' must not be empty");

        // Build JSON body
        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(allocator);

        try body.appendSlice(allocator, "{\"channel\":");
        try json_util.appendJsonString(&body, allocator, channel);
        try body.appendSlice(allocator, ",\"mrkdwn\":true,\"text\":");
        try json_util.appendJsonString(&body, allocator, text);
        if (thread_ts) |ts| {
            if (ts.len > 0) {
                try body.appendSlice(allocator, ",\"thread_ts\":");
                try json_util.appendJsonString(&body, allocator, ts);
            }
        }
        try body.append(allocator, '}');

        // Build auth header
        const token = std.mem.trim(u8, self.bot_token, " \t\n\r\"");
        var auth_buf: [512]u8 = undefined;
        var auth_fbs = std.io.fixedBufferStream(&auth_buf);
        auth_fbs.writer().print("Authorization: Bearer {s}", .{token}) catch
            return ToolResult.fail("Bot token too long for auth header");
        const auth_header = auth_fbs.getWritten();

        // Call Slack API
        const url = "https://slack.com/api/chat.postMessage";
        const resp = http_util.curlPost(allocator, url, body.items, &.{auth_header}) catch
            return ToolResult.fail("Slack API request failed");
        defer allocator.free(resp);

        // Parse response to check ok field
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch
            return ToolResult.fail("Failed to parse Slack API response");
        defer parsed.deinit();

        if (parsed.value != .object)
            return ToolResult.fail("Unexpected Slack API response format");

        const ok_val = parsed.value.object.get("ok") orelse
            return ToolResult.fail("Slack API response missing 'ok' field");

        if (ok_val != .bool or !ok_val.bool) {
            // Extract error message if available
            if (parsed.value.object.get("error")) |err_val| {
                if (err_val == .string) {
                    const msg = try std.fmt.allocPrint(allocator, "Slack API error: {s}", .{err_val.string});
                    return ToolResult{ .success = false, .output = msg, .error_msg = msg };
                }
            }
            return ToolResult.fail("Slack API returned ok=false");
        }

        // Extract ts from response for reference
        const ts_str = if (parsed.value.object.get("ts")) |ts_val|
            (if (ts_val == .string) ts_val.string else "unknown")
        else
            "unknown";

        const result = try std.fmt.allocPrint(
            allocator,
            "Message sent to {s} (ts: {s})",
            .{ channel, ts_str },
        );
        return ToolResult{ .success = true, .output = result };
    }
};

// ══════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════

const testing = std.testing;

test "SlackSendTool name and description" {
    var st = SlackSendTool{ .bot_token = "xoxb-test" };
    const t = st.tool();
    try testing.expectEqualStrings("slack_send", t.name());
    try testing.expect(t.description().len > 0);
    try testing.expect(t.parametersJson()[0] == '{');
}

test "SlackSendTool execute missing channel fails" {
    var st = SlackSendTool{ .bot_token = "xoxb-test" };
    const parsed = try root.parseTestArgs("{\"text\":\"hello\"}");
    defer parsed.deinit();
    const result = try st.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("Missing required 'channel' parameter", result.error_msg.?);
}

test "SlackSendTool execute missing text fails" {
    var st = SlackSendTool{ .bot_token = "xoxb-test" };
    const parsed = try root.parseTestArgs("{\"channel\":\"C123\"}");
    defer parsed.deinit();
    const result = try st.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("Missing required 'text' parameter", result.error_msg.?);
}

test "SlackSendTool execute empty text fails" {
    var st = SlackSendTool{ .bot_token = "xoxb-test" };
    const parsed = try root.parseTestArgs("{\"channel\":\"C123\",\"text\":\"  \"}");
    defer parsed.deinit();
    const result = try st.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("'text' must not be empty", result.error_msg.?);
}

test "SlackSendTool execute empty channel fails" {
    var st = SlackSendTool{ .bot_token = "xoxb-test" };
    const parsed = try root.parseTestArgs("{\"channel\":\"\",\"text\":\"hello\"}");
    defer parsed.deinit();
    const result = try st.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("'channel' must not be empty", result.error_msg.?);
}
