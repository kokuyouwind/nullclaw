//! Slack Send Tool — direct Slack API message posting for MCP server.
//!
//! Unlike the bus-based MessageTool, this tool calls the Slack chat.postMessage
//! API directly using a bot token. Designed for use in the MCP server process
//! where no event bus is available.
//!
//! Supports both channel IDs (e.g. "CHDBZNKNJ") and channel names (e.g. "#bot"
//! or "bot"). Channel names are resolved via the conversations.list API.

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const http_util = @import("../http_util.zig");
const json_util = @import("../json_util.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

const log = std.log.scoped(.slack_send);

const SLACK_API_BASE = "https://slack.com/api";

pub const SlackSendTool = struct {
    bot_token: []const u8,

    pub const tool_name = "slack_send";
    pub const tool_description = "Send a message to a Slack channel. Use this for proactive posting (announcements, daily reports, status updates). Accepts a channel name (e.g. '#bot' or 'general') or channel ID (e.g. 'CHDBZNKNJ'). Optionally specify thread_ts to reply in a thread.";
    pub const tool_params =
        \\{"type":"object","properties":{"channel":{"type":"string","description":"Slack channel name (e.g. '#bot', 'general') or channel ID (e.g. 'CHDBZNKNJ')"},"text":{"type":"string","description":"Message text (supports Slack mrkdwn formatting)"},"thread_ts":{"type":"string","description":"Thread timestamp to reply to (optional, for threaded replies)"}},"required":["channel","text"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *SlackSendTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *SlackSendTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const channel_raw = root.getString(args, "channel") orelse
            return ToolResult.fail("Missing required 'channel' parameter");
        const text = root.getString(args, "text") orelse
            return ToolResult.fail("Missing required 'text' parameter");
        const thread_ts = root.getString(args, "thread_ts");

        if (std.mem.trim(u8, text, " \t\n\r").len == 0)
            return ToolResult.fail("'text' must not be empty");

        const trimmed_channel = std.mem.trim(u8, channel_raw, " \t\n\r");
        if (trimmed_channel.len == 0)
            return ToolResult.fail("'channel' must not be empty");

        // Resolve channel: if it looks like a name, look up the ID
        const channel_id = if (looksLikeChannelId(trimmed_channel))
            trimmed_channel
        else blk: {
            const resolved = self.resolveChannelName(allocator, trimmed_channel);
            if (resolved.err) |err_msg| {
                const msg = std.fmt.allocPrint(allocator, "Channel name resolution failed for '{s}': {s}", .{ trimmed_channel, err_msg }) catch
                    return ToolResult.fail("Channel name resolution failed");
                return ToolResult{ .success = false, .output = msg, .error_msg = msg };
            }
            break :blk resolved.id orelse {
                const msg = std.fmt.allocPrint(allocator, "Channel '{s}' not found. Ensure the bot is a member of the channel.", .{trimmed_channel}) catch
                    return ToolResult.fail("Channel not found");
                return ToolResult{ .success = false, .output = msg, .error_msg = msg };
            };
        };

        // Build JSON body
        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(allocator);

        try body.appendSlice(allocator, "{\"channel\":");
        try json_util.appendJsonString(&body, allocator, channel_id);
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
        const url = SLACK_API_BASE ++ "/chat.postMessage";
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
            .{ channel_id, ts_str },
        );
        return ToolResult{ .success = true, .output = result };
    }

    /// Check if a string looks like a Slack channel ID (starts with C, D, or G
    /// followed by uppercase alphanumeric characters).
    fn looksLikeChannelId(s: []const u8) bool {
        if (s.len < 2) return false;
        if (s[0] != 'C' and s[0] != 'D' and s[0] != 'G') return false;
        for (s[1..]) |c| {
            if (!std.ascii.isAlphanumeric(c)) return false;
        }
        return true;
    }

    const ResolveResult = struct {
        id: ?[]const u8 = null,
        err: ?[]const u8 = null,
    };

    /// Resolve a channel name (e.g. "bot" or "#bot") to a channel ID using
    /// the Slack conversations.list API.
    fn resolveChannelName(self: *SlackSendTool, allocator: std.mem.Allocator, name_raw: []const u8) ResolveResult {
        // Strip leading '#' if present
        const name = if (name_raw.len > 0 and name_raw[0] == '#') name_raw[1..] else name_raw;
        if (name.len == 0) return .{ .err = "empty channel name" };

        if (builtin.is_test) return .{};

        const token = std.mem.trim(u8, self.bot_token, " \t\n\r\"");

        var auth_buf: [512]u8 = undefined;
        var auth_fbs = std.io.fixedBufferStream(&auth_buf);
        auth_fbs.writer().print("Authorization: Bearer {s}", .{token}) catch return .{ .err = "token too long" };
        const auth_header = auth_fbs.getWritten();

        // Paginate through conversations.list to find the channel
        var cursor_buf: [256]u8 = undefined;
        var cursor: ?[]const u8 = null;

        for (0..10) |_| { // max 10 pages (200 channels per page)
            var url_buf: [512]u8 = undefined;
            const url = if (cursor) |c|
                std.fmt.bufPrint(&url_buf, SLACK_API_BASE ++ "/conversations.list?types=public_channel,private_channel&limit=200&cursor={s}", .{c}) catch return .{ .err = "URL buffer overflow" }
            else
                SLACK_API_BASE ++ "/conversations.list?types=public_channel,private_channel&limit=200";

            const resp = http_util.curlGet(allocator, url, &.{auth_header}, "10") catch
                return .{ .err = "conversations.list API request failed (curl error)" };
            defer allocator.free(resp);

            const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch
                return .{ .err = "failed to parse conversations.list response" };
            defer parsed.deinit();

            if (parsed.value != .object) return .{ .err = "unexpected response format" };
            const obj = parsed.value.object;

            // Check ok
            const ok_val = obj.get("ok") orelse return .{ .err = "response missing 'ok' field" };
            if (ok_val != .bool or !ok_val.bool) {
                if (obj.get("error")) |e| {
                    if (e == .string) {
                        // Include the actual Slack error code in the message
                        const err_msg = std.fmt.allocPrint(allocator, "conversations.list error: {s}", .{e.string}) catch
                            return .{ .err = "conversations.list returned ok=false" };
                        return .{ .err = err_msg };
                    }
                }
                return .{ .err = "conversations.list returned ok=false" };
            }

            // Search channels array
            const channels_val = obj.get("channels") orelse return .{ .err = "response missing 'channels'" };
            if (channels_val != .array) return .{ .err = "'channels' is not an array" };

            for (channels_val.array.items) |ch| {
                if (ch != .object) continue;
                const ch_name_val = ch.object.get("name") orelse continue;
                if (ch_name_val != .string) continue;
                if (std.mem.eql(u8, ch_name_val.string, name)) {
                    const id_val = ch.object.get("id") orelse continue;
                    if (id_val != .string) continue;
                    return .{ .id = allocator.dupe(u8, id_val.string) catch return .{ .err = "alloc failed" } };
                }
            }

            // Check for next page
            const meta = obj.get("response_metadata") orelse return .{};
            if (meta != .object) return .{};
            const next = meta.object.get("next_cursor") orelse return .{};
            if (next != .string or next.string.len == 0) return .{};

            // Copy cursor for next iteration
            const copied = std.fmt.bufPrint(&cursor_buf, "{s}", .{next.string}) catch return .{ .err = "cursor buffer overflow" };
            cursor = copied;
        }

        return .{};
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

test "looksLikeChannelId recognizes valid IDs" {
    try testing.expect(SlackSendTool.looksLikeChannelId("CHDBZNKNJ"));
    try testing.expect(SlackSendTool.looksLikeChannelId("C01ABCDEF"));
    try testing.expect(SlackSendTool.looksLikeChannelId("D12345"));
    try testing.expect(SlackSendTool.looksLikeChannelId("G99XYZ"));
}

test "looksLikeChannelId rejects non-IDs" {
    try testing.expect(!SlackSendTool.looksLikeChannelId("bot"));
    try testing.expect(!SlackSendTool.looksLikeChannelId("#bot"));
    try testing.expect(!SlackSendTool.looksLikeChannelId("general"));
    try testing.expect(!SlackSendTool.looksLikeChannelId(""));
    try testing.expect(!SlackSendTool.looksLikeChannelId("C"));
    try testing.expect(!SlackSendTool.looksLikeChannelId("c123")); // lowercase
}

test "resolveChannelName returns empty in test mode" {
    var st = SlackSendTool{ .bot_token = "xoxb-test" };
    const r1 = st.resolveChannelName(testing.allocator, "bot");
    try testing.expect(r1.id == null);
    try testing.expect(r1.err == null);
    const r2 = st.resolveChannelName(testing.allocator, "#bot");
    try testing.expect(r2.id == null);
    try testing.expect(r2.err == null);
}

test "resolveChannelName rejects empty name" {
    var st = SlackSendTool{ .bot_token = "xoxb-test" };
    const r1 = st.resolveChannelName(testing.allocator, "#");
    try testing.expect(r1.err != null);
    const r2 = st.resolveChannelName(testing.allocator, "");
    try testing.expect(r2.err != null);
}
