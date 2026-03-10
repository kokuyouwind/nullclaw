const std = @import("std");
const root = @import("root.zig");

const Provider = root.Provider;
const ChatRequest = root.ChatRequest;
const ChatResponse = root.ChatResponse;
const ChatMessage = root.ChatMessage;

/// Provider that delegates to the `claude` CLI (Claude Code).
///
/// Runs `claude -p <prompt> --output-format stream-json --model <model> --verbose`
/// and parses the stream-json output for a `type: "result"` event.
pub const ClaudeCliProvider = struct {
    allocator: std.mem.Allocator,
    model: []const u8,
    mcp_enabled: bool,

    const DEFAULT_MODEL = "claude-opus-4-6";
    const CLI_NAME = "claude";
    const TIMEOUT_NS: u64 = 120 * std.time.ns_per_s;
    /// MCP config JSON that tells Claude Code to spawn nullclaw as an MCP server.
    const MCP_CONFIG =
        \\{"mcpServers":{"nullclaw-tools":{"command":"nullclaw","args":["--mcp-server"]}}}
    ;

    pub fn init(allocator: std.mem.Allocator, model: ?[]const u8) !ClaudeCliProvider {
        // Verify CLI is in PATH
        try checkCliAvailable(allocator, CLI_NAME);

        // Check if MCP tools passthrough is enabled via environment
        const platform = @import("../platform.zig");
        const mcp_env = platform.getEnvOrNull(allocator, "NULLCLAW_MCP_TOOLS");
        const mcp_on = if (mcp_env) |v| blk: {
            defer allocator.free(v);
            break :blk std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
        } else false;

        return .{
            .allocator = allocator,
            .model = model orelse DEFAULT_MODEL,
            .mcp_enabled = mcp_on,
        };
    }

    /// Create a Provider vtable interface.
    pub fn provider(self: *ClaudeCliProvider) Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = Provider.VTable{
        .chatWithSystem = chatWithSystemImpl,
        .chat = chatImpl,
        .supportsNativeTools = supportsNativeToolsImpl,
        .supports_vision = supportsVisionImpl,
        .getName = getNameImpl,
        .deinit = deinitImpl,
    };

    fn chatWithSystemImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const self: *ClaudeCliProvider = @ptrCast(@alignCast(ptr));
        const effective_model = if (model.len > 0) model else self.model;

        return runClaude(allocator, message, effective_model, system_prompt, self.mcp_enabled);
    }

    fn chatImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
        _: f64,
    ) anyerror!ChatResponse {
        const self: *ClaudeCliProvider = @ptrCast(@alignCast(ptr));
        const effective_model = if (model.len > 0) model else self.model;

        // Extract system prompt and build conversation prompt from message history
        const system_prompt = extractSystemPrompt(request.messages);
        const prompt = try buildConversationPrompt(allocator, request.messages);
        defer allocator.free(prompt);
        const content = try runClaude(allocator, prompt, effective_model, system_prompt, self.mcp_enabled);
        return ChatResponse{ .content = content, .model = try allocator.dupe(u8, effective_model) };
    }

    fn supportsNativeToolsImpl(_: *anyopaque) bool {
        return false;
    }

    fn supportsVisionImpl(_: *anyopaque) bool {
        return false;
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "claude-cli";
    }

    fn deinitImpl(_: *anyopaque) void {}

    /// Run the claude CLI and parse stream-json output.
    fn runClaude(allocator: std.mem.Allocator, prompt: []const u8, model: []const u8, system_prompt: ?[]const u8, mcp_enabled: bool) ![]const u8 {
        // Build argv dynamically with optional flags
        var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv_list.deinit(allocator);

        // Base arguments
        for ([_][]const u8{
            CLI_NAME,        "-p",                 prompt,
            "--output-format", "stream-json",
            "--model",        model,
            "--verbose",      "--dangerously-skip-permissions",
        }) |arg| {
            try argv_list.append(allocator, arg);
        }

        // Optional: system prompt
        if (system_prompt) |sp| {
            try argv_list.append(allocator, "--system-prompt");
            try argv_list.append(allocator, sp);
        }

        // Optional: MCP server config (expose nullclaw tools to Claude Code)
        if (mcp_enabled) {
            try argv_list.append(allocator, "--mcp-config");
            try argv_list.append(allocator, MCP_CONFIG);
            try argv_list.append(allocator, "--strict-mcp-config");
            // Allow MCP tools + essential Claude Code builtins for file/shell access
            try argv_list.append(allocator, "--allowedTools");
            try argv_list.append(allocator, "mcp__nullclaw-tools__* Read Write Edit Bash Glob Grep");
        }

        var child = std.process.Child.init(argv_list.items, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        // Read all stdout
        const max_output: usize = 4 * 1024 * 1024; // 4 MB
        const stdout_result = child.stdout.?.readToEndAlloc(allocator, max_output) catch |err| {
            _ = child.wait() catch {};
            return err;
        };
        defer allocator.free(stdout_result);

        const term = try child.wait();
        switch (term) {
            .Exited => |code| {
                if (code != 0) return error.CliProcessFailed;
            },
            else => return error.CliProcessFailed,
        }

        // Parse stream-json: each line is a JSON object, find type="result"
        return parseStreamJson(allocator, stdout_result);
    }

    /// Parse claude stream-json output lines for a result event.
    fn parseStreamJson(allocator: std.mem.Allocator, output: []const u8) ![]const u8 {
        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
            defer parsed.deinit();

            if (parsed.value != .object) continue;
            const obj = parsed.value.object;

            // Look for type: "result"
            if (obj.get("type")) |type_val| {
                if (type_val == .string and std.mem.eql(u8, type_val.string, "result")) {
                    if (obj.get("result")) |result_val| {
                        if (result_val == .string) {
                            return try allocator.dupe(u8, result_val.string);
                        }
                    }
                }
            }
        }
        return error.NoResultInOutput;
    }

    /// Health check: run `claude --version` and verify exit code 0.
    fn healthCheck(allocator: std.mem.Allocator) !void {
        try checkCliVersion(allocator, CLI_NAME);
    }
};

// ════════════════════════════════════════════════════════════════════════════
// Shared helpers
// ════════════════════════════════════════════════════════════════════════════

/// Check if a CLI tool is available in PATH using `which`.
fn checkCliAvailable(allocator: std.mem.Allocator, cli_name: []const u8) !void {
    const argv = [_][]const u8{ "which", cli_name };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = child.stdout.?.readToEndAlloc(allocator, 4096) catch {
        _ = child.wait() catch {};
        return error.CliNotFound;
    };
    allocator.free(out);
    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.CliNotFound;
        },
        else => return error.CliNotFound,
    }
}

/// Run `<cli> --version` and verify exit code 0.
fn checkCliVersion(allocator: std.mem.Allocator, cli_name: []const u8) !void {
    const argv = [_][]const u8{ cli_name, "--version" };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = child.stdout.?.readToEndAlloc(allocator, 4096) catch {
        _ = child.wait() catch {};
        return error.CliNotFound;
    };
    allocator.free(out);
    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.CliNotFound;
        },
        else => return error.CliNotFound,
    }
}

/// Extract system prompt from the first message if it has system role.
fn extractSystemPrompt(messages: []const ChatMessage) ?[]const u8 {
    if (messages.len > 0 and messages[0].role == .system) {
        return messages[0].content;
    }
    return null;
}

/// Build a conversation prompt from message history, including all non-system messages.
/// Formats multi-turn history so the LLM understands the conversation context.
fn buildConversationPrompt(allocator: std.mem.Allocator, messages: []const ChatMessage) ![]const u8 {
    // Find the last user message for the single-message fast path
    var last_user_idx: ?usize = null;
    var non_system_count: usize = 0;
    for (messages, 0..) |msg, i| {
        if (msg.role == .system) continue;
        non_system_count += 1;
        if (msg.role == .user) last_user_idx = i;
    }

    // Fast path: single non-system message (or only one user message with no other context)
    if (non_system_count <= 1) {
        if (last_user_idx) |idx| {
            return try allocator.dupe(u8, messages[idx].content);
        }
        return error.NoUserMessage;
    }

    // Multi-turn: format as labeled conversation
    var result: std.ArrayListUnmanaged(u8) = .empty;
    const w = result.writer(allocator);
    for (messages) |msg| {
        if (msg.role == .system) continue;
        const label = switch (msg.role) {
            .user => "Human",
            .assistant => "Assistant",
            .tool => "Tool",
            else => continue,
        };
        try w.print("[{s}]\n{s}\n\n", .{ label, msg.content });
    }
    if (result.items.len == 0) {
        result.deinit(allocator);
        return error.NoUserMessage;
    }
    return result.toOwnedSlice(allocator) catch error.NoUserMessage;
}

/// Extract the content of the last user message from a message slice.
fn extractLastUserMessage(messages: []const ChatMessage) ?[]const u8 {
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        if (messages[i].role == .user) return messages[i].content;
    }
    return null;
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "ClaudeCliProvider.getNameImpl returns claude-cli" {
    const vtable = ClaudeCliProvider.vtable;
    var dummy: u8 = 0;
    try std.testing.expectEqualStrings("claude-cli", vtable.getName(@ptrCast(&dummy)));
}

test "extractLastUserMessage finds last user" {
    const msgs = [_]ChatMessage{
        ChatMessage.system("Be helpful"),
        ChatMessage.user("first"),
        ChatMessage.assistant("ok"),
        ChatMessage.user("second"),
    };
    const result = extractLastUserMessage(&msgs);
    try std.testing.expectEqualStrings("second", result.?);
}

test "extractLastUserMessage returns null for no user" {
    const msgs = [_]ChatMessage{
        ChatMessage.system("Be helpful"),
        ChatMessage.assistant("ok"),
    };
    try std.testing.expect(extractLastUserMessage(&msgs) == null);
}

test "extractLastUserMessage empty messages" {
    const msgs = [_]ChatMessage{};
    try std.testing.expect(extractLastUserMessage(&msgs) == null);
}

test "parseStreamJson extracts result" {
    const input =
        \\{"type":"start","session_id":"abc123"}
        \\{"type":"content","content":"partial"}
        \\{"type":"result","result":"Hello from Claude CLI!"}
    ;
    const result = try ClaudeCliProvider.parseStreamJson(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello from Claude CLI!", result);
}

test "parseStreamJson no result returns error" {
    const input =
        \\{"type":"start","session_id":"abc123"}
        \\{"type":"content","content":"partial"}
    ;
    const result = ClaudeCliProvider.parseStreamJson(std.testing.allocator, input);
    try std.testing.expectError(error.NoResultInOutput, result);
}

test "parseStreamJson handles empty input" {
    const result = ClaudeCliProvider.parseStreamJson(std.testing.allocator, "");
    try std.testing.expectError(error.NoResultInOutput, result);
}

test "parseStreamJson handles invalid json lines gracefully" {
    const input =
        \\not json at all
        \\{"type":"result","result":"found it"}
    ;
    const result = try ClaudeCliProvider.parseStreamJson(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("found it", result);
}

test "parseStreamJson skips result with non-string value" {
    const input =
        \\{"type":"result","result":42}
    ;
    const result = ClaudeCliProvider.parseStreamJson(std.testing.allocator, input);
    try std.testing.expectError(error.NoResultInOutput, result);
}

test "ClaudeCliProvider vtable has correct function pointers" {
    const vtable = ClaudeCliProvider.vtable;
    var dummy: u8 = 0;
    try std.testing.expectEqualStrings("claude-cli", vtable.getName(@ptrCast(&dummy)));
    try std.testing.expect(!vtable.supportsNativeTools(@ptrCast(&dummy)));
    try std.testing.expect(vtable.supports_vision != null);
    try std.testing.expect(!vtable.supports_vision.?(@ptrCast(&dummy)));
}

test "ClaudeCliProvider.init returns CliNotFound for missing binary" {
    const result = checkCliAvailable(std.testing.allocator, "nonexistent_binary_xyzzy_12345");
    try std.testing.expectError(error.CliNotFound, result);
}

test "ClaudeCliProvider default model is claude-opus-4-6" {
    try std.testing.expectEqualStrings("claude-opus-4-6", ClaudeCliProvider.DEFAULT_MODEL);
}

test "extractSystemPrompt returns system message content" {
    const msgs = [_]ChatMessage{
        ChatMessage.system("You are Miku"),
        ChatMessage.user("hello"),
    };
    const result = extractSystemPrompt(&msgs);
    try std.testing.expectEqualStrings("You are Miku", result.?);
}

test "extractSystemPrompt returns null when no system message" {
    const msgs = [_]ChatMessage{
        ChatMessage.user("hello"),
    };
    try std.testing.expect(extractSystemPrompt(&msgs) == null);
}

test "extractSystemPrompt returns null for empty messages" {
    const msgs = [_]ChatMessage{};
    try std.testing.expect(extractSystemPrompt(&msgs) == null);
}

test "buildConversationPrompt single user message" {
    const msgs = [_]ChatMessage{
        ChatMessage.system("Be helpful"),
        ChatMessage.user("hello"),
    };
    const result = try buildConversationPrompt(std.testing.allocator, &msgs);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "buildConversationPrompt multi-turn conversation" {
    const msgs = [_]ChatMessage{
        ChatMessage.system("Be helpful"),
        ChatMessage.user("hi"),
        ChatMessage.assistant("hello"),
        ChatMessage.user("how are you"),
    };
    const result = try buildConversationPrompt(std.testing.allocator, &msgs);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("[Human]\nhi\n\n[Assistant]\nhello\n\n[Human]\nhow are you\n\n", result);
}

test "buildConversationPrompt no user message returns error" {
    const msgs = [_]ChatMessage{
        ChatMessage.system("Be helpful"),
    };
    const result = buildConversationPrompt(std.testing.allocator, &msgs);
    try std.testing.expectError(error.NoUserMessage, result);
}
