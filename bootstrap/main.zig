// bootstrap/main.zig - v0.0.4 LIVE INTERPRETER (NO LLVM)
const std = @import("std");
const print = std.debug.print;
const allocator = std.heap.page_allocator;

const Value = union(enum) {
    int: i64,
    str: []const u8,
};

fn makeInt(v: i64) Value {
    return .{ .int = v };
}

fn expectInt(v: Value) i64 {
    return switch (v) {
        .int => |i| i,
        .str => @panic("expected integer"),
    };
}

fn expectStr(v: Value) []const u8 {
    return switch (v) {
        .str => |s| s,
        .int => "",
    };
}

fn isZeroInt(v: Value) bool {
    return switch (v) {
        .int => |i| i == 0,
        .str => false,
    };
}
const env_debug = false;

// Separate runtime env used by Vex-level env_create/env_set/env_find builtins.
const KVEnv = struct {
    parent: ?*KVEnv,
    map: std.StringHashMap(Value),
};

fn builtinEnvCreate(parent_handle: ?Value) Value {
    var parent: ?*KVEnv = null;
    if (parent_handle) |h| {
        if (!isZeroInt(h)) {
            const addr = @as(usize, @intCast(expectInt(h)));
            parent = @as(*KVEnv, @ptrFromInt(addr));
        }
    }

    const env_ptr: *KVEnv = allocator.create(KVEnv) catch @panic("oom");
    env_ptr.* = .{
        .parent = parent,
        .map = std.StringHashMap(Value).init(allocator),
    };

    const addr: i64 = @intCast(@intFromPtr(env_ptr));
    return makeInt(addr);
}

fn builtinEnvSet(env_handle: Value, key: []const u8, value: Value) void {
    if (isZeroInt(env_handle)) return;
    const addr = @as(usize, @intCast(expectInt(env_handle)));
    const env_ptr = @as(*KVEnv, @ptrFromInt(addr));
    if (env_debug) {
        const vv = switch (value) {
            .int => |i| i,
            .str => |_| -1,
        };
        print("[env_set] key='{s}' len={d} value={d}\n", .{key, key.len, vv});
    }
    env_ptr.map.put(key, value) catch @panic("oom");
}

fn builtinEnvFind(env_handle: Value, key: []const u8) ?Value {
    if (isZeroInt(env_handle)) return null;
    const addr = @as(usize, @intCast(expectInt(env_handle)));
    var cur: ?*KVEnv = @as(*KVEnv, @ptrFromInt(addr));
    while (cur) |e| {
        if (env_debug) {
            print("[env_find] key='{s}' len={d} count={d}\n", .{key, key.len, e.map.count()});
        }
        if (e.map.get(key)) |v| return v;
        cur = e.parent;
    }
    return null;
}

fn builtinPrintBytes(bytes: []const u8) void {
    print("{s}", .{bytes});
}

fn builtinPrintChar(b: u8) void {
    var buf: [1]u8 = .{b};
    print("{s}", .{buf[0..1]});
}

const VexList = struct {
    items: std.ArrayList(Value),
};

fn builtinListCreate() Value {
    const list_ptr: *VexList = allocator.create(VexList) catch @panic("oom");
    list_ptr.* = .{ .items = std.ArrayList(Value).init(allocator) };
    return makeInt(@intCast(@intFromPtr(list_ptr)));
}

fn builtinListPush(list_handle: Value, value: Value) void {
    if (isZeroInt(list_handle)) return;
    const addr = @as(usize, @intCast(expectInt(list_handle)));
    const list_ptr = @as(*VexList, @ptrFromInt(addr));
    list_ptr.items.append(value) catch @panic("oom");
}

fn builtinListLen(list_handle: Value) Value {
    if (isZeroInt(list_handle)) return makeInt(0);
    const addr = @as(usize, @intCast(expectInt(list_handle)));
    const list_ptr = @as(*VexList, @ptrFromInt(addr));
    return makeInt(@intCast(list_ptr.items.items.len));
}

fn builtinListGet(list_handle: Value, idx_value: Value) Value {
    if (isZeroInt(list_handle)) return makeInt(0);
    const addr = @as(usize, @intCast(expectInt(list_handle)));
    const list_ptr = @as(*VexList, @ptrFromInt(addr));
    const idx_signed = expectInt(idx_value);
    if (idx_signed < 0) return makeInt(0);
    const idx: usize = @intCast(idx_signed);
    if (idx >= list_ptr.items.items.len) return makeInt(0);
    return list_ptr.items.items[idx];
}

fn builtinReadFile(path: []const u8) Value {
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch @panic("read_file failed");
    return .{ .str = bytes };
}

fn builtinWriteFile(path: []const u8, data: []const u8) void {
    var file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch @panic("write_file: create failed");
    defer file.close();
    file.writeAll(data) catch @panic("write_file: write failed");
}

var script_args: [][]u8 = &[_][]u8{};
var verbose: bool = false;

fn builtinArgLen() Value {
    return makeInt(@intCast(script_args.len));
}

fn builtinArgGet(idx_value: Value) Value {
    const idx_signed = expectInt(idx_value);
    if (idx_signed < 0) return .{ .str = "" };
    const idx: usize = @intCast(idx_signed);
    if (idx >= script_args.len) return .{ .str = "" };
    return .{ .str = script_args[idx] };
}

const Env = struct {
    parent: ?*Env,
    map: std.StringHashMap(Value),

    fn create(parent: ?*Env) !*Env {
        const env = try allocator.create(Env);
        env.* = .{
            .parent = parent,
            .map = std.StringHashMap(Value).init(allocator),
        };
        return env;
    }

    fn get(self: *Env, name: []const u8) ?Value {
        if (self.map.get(name)) |v| return v;
        if (self.parent) |p| return p.get(name);
        return null;
    }

    fn set(self: *Env, name: []const u8, val: Value) void {
        self.map.put(name, val) catch @panic("oom");
    }
};

const Token = struct {
    kind: Kind,
    text: []const u8,
    line: usize,

    const Kind = enum {
        identifier,
        string,
        integer,
        keyword_let,
        keyword_print,
        keyword_fn,
        keyword_return,
        keyword_if,
        keyword_while,
        keyword_and,
        keyword_or,
        keyword_accel,
        l_paren,
        r_paren,
        l_brace,
        r_brace,
        equal,
        equal_equal,
        bang_equal,
        plus,
        minus,
        star,
        slash,
        less,
        less_equal,
        eof,
    };
};

const Func = struct {
    name: []const u8,
    param_name: ?[]const u8,
    param_name2: ?[]const u8,
    param_name3: ?[]const u8,
    body: []Token,
    is_accel: bool,
};

var tokens: []Token = &[_]Token{};
var pos: usize = 0;
var functions: std.StringHashMap(Func) = undefined;

fn tokenKindLabel(k: Token.Kind) []const u8 {
    return switch (k) {
        .keyword_let => "Let",
        .keyword_print => "Print",
        .identifier => "Ident",
        .integer => "Int",
        .plus => "Plus",
        .l_paren => "LParen",
        .r_paren => "RParen",
        .eof => "Eof",
        else => "Other",
    };
}

fn debugTokenizeZig() void {
    const source: []const u8 = "let x = 42; print(x + 3)\n";

    var list = std.ArrayList(Token).init(allocator);
    defer list.deinit();

    var i: usize = 0;
    var line: usize = 1;
    while (i < source.len) {
        const c = source[i];

        // whitespace/newline/semicolon
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == ';') {
            if (c == '\n') line += 1;
            i += 1;
            continue;
        }

        // identifiers / keywords
        if (isAlpha(c)) {
            const start = i;
            i += 1;
            while (i < source.len and (isAlpha(source[i]) or isDigit(source[i]) or source[i] == '_')) : (i += 1) {}
            const word = source[start..i];
            const kind: Token.Kind =
                if (std.mem.eql(u8, word, "let")) .keyword_let
                else if (std.mem.eql(u8, word, "print")) .keyword_print
                else .identifier;
            list.append(.{ .kind = kind, .text = word, .line = line }) catch @panic("oom");
            continue;
        }

        // numbers
        if (isDigit(c)) {
            const start = i;
            i += 1;
            while (i < source.len and isDigit(source[i])) : (i += 1) {}
            list.append(.{ .kind = .integer, .text = source[start..i], .line = line }) catch @panic("oom");
            continue;
        }

        // symbols we care about
        if (c == '+') {
            list.append(.{ .kind = .plus, .text = source[i..i+1], .line = line }) catch @panic("oom");
            i += 1;
            continue;
        }
        if (c == '(') {
            list.append(.{ .kind = .l_paren, .text = source[i..i+1], .line = line }) catch @panic("oom");
            i += 1;
            continue;
        }
        if (c == ')') {
            list.append(.{ .kind = .r_paren, .text = source[i..i+1], .line = line }) catch @panic("oom");
            i += 1;
            continue;
        }

        // ignore anything else (like '=')
        i += 1;
    }

    list.append(.{ .kind = .eof, .text = "", .line = line }) catch @panic("oom");

    print("demo_tokenize (zig):\n", .{});
    for (list.items) |t| {
        print("tok:{s}:{s}\n", .{ tokenKindLabel(t.kind), t.text });
    }
}

fn peek() Token {
    return tokens[pos];
}

fn advance() Token {
    const t = tokens[pos];
    pos += 1;
    return t;
}

fn consume(kind: Token.Kind) void {
    if (peek().kind != kind) {
        @panic("parse error");
    }
    _ = advance();
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn parseFunction(is_accel: bool) void {
    if (is_accel) {
        _ = advance(); // 'accel'
    }

    // expect 'fn'
    if (peek().kind != .keyword_fn) @panic("expected fn after accel");
    _ = advance();

    const name_tok = advance();
    if (name_tok.kind != .identifier) @panic("expected function name");

    var param_name: ?[]const u8 = null;
    var param_name2: ?[]const u8 = null;
    var param_name3: ?[]const u8 = null;

    if (peek().kind == .l_paren) {
        consume(.l_paren);
        while (peek().kind != .r_paren and peek().kind != .eof) {
            const param_tok = advance();
            if (param_tok.kind == .identifier) {
                if (param_name == null) {
                    param_name = param_tok.text;
                } else if (param_name2 == null) {
                    param_name2 = param_tok.text;
                } else if (param_name3 == null) {
                    param_name3 = param_tok.text;
                }
            }
        }
        consume(.r_paren);
    }

    // Skip until function body '{'
    while (peek().kind != .l_brace and peek().kind != .eof) {
        _ = advance();
    }
    if (peek().kind != .l_brace) @panic("expected { for function body");

    // Enter body
    consume(.l_brace);
    const body_start = pos;
    var depth: usize = 1;

    while (depth > 0 and peek().kind != .eof) {
        const t = advance();
        switch (t.kind) {
            .l_brace => depth += 1,
            .r_brace => depth -= 1,
            else => {},
        }
    }

    const body_end = pos - 1;
    const body_len = if (body_end >= body_start) body_end - body_start + 1 else 0;

    var body_slice = allocator.alloc(Token, body_len + 1) catch @panic("oom");
    if (body_len > 0) {
        std.mem.copyForwards(Token, body_slice[0..body_len], tokens[body_start .. body_start + body_len]);
    }
    body_slice[body_len] = Token{
        .kind = .eof,
        .text = "",
        .line = if (body_len > 0) body_slice[body_len - 1].line else 0,
    };

    const func = Func{
        .name = name_tok.text,
        .param_name = param_name,
        .param_name2 = param_name2,
        .param_name3 = param_name3,
        .body = body_slice,
        .is_accel = is_accel,
    };

    functions.put(func.name, func) catch @panic("oom");

    if (is_accel) {
        if (verbose) {
            print("[@accel] registered {s} (CPU stub now, GPU later)\n", .{func.name});
        }
    }
}

fn runFunction(name: []const u8, arg1: ?Value, arg2: ?Value, arg3: ?Value, caller_env: *Env) Value {
    const func = functions.get(name) orelse {
        print("[undefined function] {s}\n", .{name});
        @panic("undefined function");
    };

    const saved_tokens = tokens;
    const saved_pos = pos;

    tokens = func.body;
    pos = 0;

    const local_env = Env.create(caller_env) catch @panic("oom");
    defer {
        local_env.map.deinit();
        allocator.destroy(local_env);
    }

    if (func.param_name) |param| {
        if (arg1) |a| {
            local_env.set(param, a);
        } else {
            local_env.set(param, makeInt(0));
        }
    }
    if (func.param_name2) |param| {
        if (arg2) |a| {
            local_env.set(param, a);
        } else {
            local_env.set(param, makeInt(0));
        }
    }
    if (func.param_name3) |param| {
        if (arg3) |a| {
            local_env.set(param, a);
        } else {
            local_env.set(param, makeInt(0));
        }
    }

    var result: Value = makeInt(0);
    var has_result = false;

    while (peek().kind != .eof) {
        if (evalStmt(local_env)) |ret| {
            result = ret;
            has_result = true;
            break;
        }
    }

    tokens = saved_tokens;
    pos = saved_pos;

    return if (has_result) result else makeInt(0);
}

fn evalPrimary(env: *Env) Value {
    const t = peek();

    // function call: name(...)
    if (t.kind == .identifier and pos + 1 < tokens.len and tokens[pos + 1].kind == .l_paren) {
        const name = t.text;

        // Built-ins live here for now.
        if (std.mem.eql(u8, name, "env_create") or
            std.mem.eql(u8, name, "env_set") or
            std.mem.eql(u8, name, "env_find") or
            std.mem.eql(u8, name, "str_len") or
            std.mem.eql(u8, name, "str_char") or
            std.mem.eql(u8, name, "str_slice") or
            std.mem.eql(u8, name, "print_bytes") or
            std.mem.eql(u8, name, "print_char") or
            std.mem.eql(u8, name, "list_create") or
            std.mem.eql(u8, name, "list_push") or
            std.mem.eql(u8, name, "list_len") or
            std.mem.eql(u8, name, "list_get") or
            std.mem.eql(u8, name, "read_file") or
            std.mem.eql(u8, name, "write_file") or
            std.mem.eql(u8, name, "arg_len") or
            std.mem.eql(u8, name, "arg_get"))
        {
            _ = advance(); // identifier
            consume(.l_paren);

            if (std.mem.eql(u8, name, "env_create")) {
                var parent_handle: ?Value = null;
                if (peek().kind != .r_paren) {
                    parent_handle = evalExpr(env);
                }
                if (peek().kind == .r_paren) consume(.r_paren);
                return builtinEnvCreate(parent_handle);
            } else if (std.mem.eql(u8, name, "env_set")) {
                // env_set(env_handle, key, value)
                const env_handle = evalExpr(env);
                const key_val = evalExpr(env);
                const key = expectStr(key_val);
                const val = evalExpr(env);
                if (peek().kind == .r_paren) consume(.r_paren);

                builtinEnvSet(env_handle, key, val);
                return makeInt(0);
            } else if (std.mem.eql(u8, name, "env_find")) {
                // env_find(env_handle, key)
                const env_handle = evalExpr(env);
                const key_val = evalExpr(env);
                const key = expectStr(key_val);

                if (peek().kind == .r_paren) consume(.r_paren);

                if (builtinEnvFind(env_handle, key)) |v| return v;
                return makeInt(0);
            } else if (std.mem.eql(u8, name, "str_len")) {
                const s_val = if (peek().kind != .r_paren) evalExpr(env) else Value{ .str = "" };
                if (peek().kind == .r_paren) consume(.r_paren);
                const s = expectStr(s_val);
                return makeInt(@as(i64, @intCast(s.len)));
            } else if (std.mem.eql(u8, name, "str_char")) {
                const s_val = evalExpr(env);
                const idx_val = evalExpr(env);
                if (peek().kind == .r_paren) consume(.r_paren);
                const s = expectStr(s_val);
                const idx = expectInt(idx_val);
                if (idx < 0 or @as(usize, @intCast(idx)) >= s.len) return makeInt(0);
                return makeInt(@as(i64, s[@as(usize, @intCast(idx))]));
            } else if (std.mem.eql(u8, name, "str_slice")) {
                const s_val = evalExpr(env);
                const start_val = evalExpr(env);
                const end_val = evalExpr(env);
                if (peek().kind == .r_paren) consume(.r_paren);
                const s = expectStr(s_val);
                var start = expectInt(start_val);
                var end = expectInt(end_val);
                if (start < 0) start = 0;
                if (end < start) end = start;
                const len = @as(i64, @intCast(s.len));
                if (start > len) start = len;
                if (end > len) end = len;
                const ustart: usize = @intCast(start);
                const uend: usize = @intCast(end);
                return .{ .str = s[ustart..uend] };
            } else if (std.mem.eql(u8, name, "print_bytes")) {
                const s_val = evalExpr(env);
                if (peek().kind == .r_paren) consume(.r_paren);
                const s = expectStr(s_val);
                builtinPrintBytes(s);
                return makeInt(0);
            } else if (std.mem.eql(u8, name, "print_char")) {
                const v = evalExpr(env);
                if (peek().kind == .r_paren) consume(.r_paren);
                const b: u8 = @intCast(expectInt(v));
                builtinPrintChar(b);
                return makeInt(0);
            } else if (std.mem.eql(u8, name, "list_create")) {
                if (peek().kind == .r_paren) consume(.r_paren);
                return builtinListCreate();
            } else if (std.mem.eql(u8, name, "list_push")) {
                const list_handle = evalExpr(env);
                const v = evalExpr(env);
                if (peek().kind == .r_paren) consume(.r_paren);
                builtinListPush(list_handle, v);
                return makeInt(0);
            } else if (std.mem.eql(u8, name, "list_len")) {
                const list_handle = evalExpr(env);
                if (peek().kind == .r_paren) consume(.r_paren);
                return builtinListLen(list_handle);
            } else if (std.mem.eql(u8, name, "list_get")) {
                const list_handle = evalExpr(env);
                const idx_val = evalExpr(env);
                if (peek().kind == .r_paren) consume(.r_paren);
                return builtinListGet(list_handle, idx_val);
            } else if (std.mem.eql(u8, name, "read_file")) {
                const path_val = if (peek().kind != .r_paren) evalExpr(env) else Value{ .str = "" };
                if (peek().kind == .r_paren) consume(.r_paren);
                const path = expectStr(path_val);
                return builtinReadFile(path);
            } else if (std.mem.eql(u8, name, "write_file")) {
                const path_val = evalExpr(env);
                const data_val = evalExpr(env);
                if (peek().kind == .r_paren) consume(.r_paren);
                const path = expectStr(path_val);
                const data = expectStr(data_val);
                builtinWriteFile(path, data);
                return makeInt(0);
            } else if (std.mem.eql(u8, name, "arg_len")) {
                if (peek().kind == .r_paren) consume(.r_paren);
                return builtinArgLen();
            } else if (std.mem.eql(u8, name, "arg_get")) {
                const idx_val = evalExpr(env);
                if (peek().kind == .r_paren) consume(.r_paren);
                return builtinArgGet(idx_val);
            }
        }

        // User-defined function call (one optional argument)
        _ = advance(); // identifier
        consume(.l_paren);

        var arg1: ?Value = null;
        var arg2: ?Value = null;
        var arg3: ?Value = null;
        if (peek().kind != .r_paren) {
            arg1 = evalExpr(env);
        }
        if (peek().kind != .r_paren) {
            arg2 = evalExpr(env);
        }
        if (peek().kind != .r_paren) {
            arg3 = evalExpr(env);
        }
        if (peek().kind == .r_paren) consume(.r_paren);

        return runFunction(name, arg1, arg2, arg3, env);
    }

    const token = advance();

    return switch (token.kind) {
        .integer => makeInt(std.fmt.parseInt(i64, token.text, 10) catch @panic("bad integer")),
        .string => .{ .str = token.text[1 .. token.text.len - 1] },
        .identifier => env.get(token.text) orelse makeInt(0),
        .l_paren => blk: {
            const v = evalExpr(env);
            consume(.r_paren);
            break :blk v;
        },
        else => makeInt(0),
    };
}

fn evalTerm(env: *Env) Value {
    var result = evalPrimary(env);

    while (true) {
        const t = peek();
        switch (t.kind) {
            .star => {
                _ = advance();
                const lhs = expectInt(result);
                const rhs = expectInt(evalPrimary(env));
                result = makeInt(lhs * rhs);
            },
            .slash => {
                _ = advance();
                const lhs = expectInt(result);
                const rhs = expectInt(evalPrimary(env));
                result = makeInt(@divTrunc(lhs, rhs));
            },
            else => return result,
        }
    }
}

fn evalAdd(env: *Env) Value {
    var result = evalTerm(env);

    while (true) {
        const t = peek();
        switch (t.kind) {
            .plus => {
                _ = advance();
                const lhs = expectInt(result);
                const rhs = expectInt(evalTerm(env));
                result = makeInt(lhs + rhs);
            },
            .minus => {
                _ = advance();
                const lhs = expectInt(result);
                const rhs = expectInt(evalTerm(env));
                result = makeInt(lhs - rhs);
            },
            else => return result,
        }
    }
}

fn evalCompare(env: *Env) Value {
    var result = evalAdd(env);

    while (true) {
        const t = peek();
        switch (t.kind) {
            .less => {
                _ = advance();
                const lhs = expectInt(result);
                const rhs = expectInt(evalAdd(env));
                result = makeInt(if (lhs < rhs) 1 else 0);
            },
            .less_equal => {
                _ = advance();
                const lhs = expectInt(result);
                const rhs = expectInt(evalAdd(env));
                result = makeInt(if (lhs <= rhs) 1 else 0);
            },
            else => return result,
        }
    }
}

fn evalEquality(env: *Env) Value {
    var result = evalCompare(env);

    while (true) {
        const t = peek();
        switch (t.kind) {
            .equal_equal => {
                _ = advance();
                const lhs = expectInt(result);
                const rhs = expectInt(evalCompare(env));
                result = makeInt(if (lhs == rhs) 1 else 0);
            },
            .bang_equal => {
                _ = advance();
                const lhs = expectInt(result);
                const rhs = expectInt(evalCompare(env));
                result = makeInt(if (lhs != rhs) 1 else 0);
            },
            else => return result,
        }
    }
}

fn evalAnd(env: *Env) Value {
    var result = evalEquality(env);

    while (true) {
        const t = peek();
        switch (t.kind) {
            .keyword_and => {
                _ = advance();
                const lhs = expectInt(result);
                const rhs = expectInt(evalEquality(env));
                result = makeInt(if (lhs != 0 and rhs != 0) 1 else 0);
            },
            else => return result,
        }
    }
}

fn evalOr(env: *Env) Value {
    var result = evalAnd(env);

    while (true) {
        const t = peek();
        switch (t.kind) {
            .keyword_or => {
                _ = advance();
                const lhs = expectInt(result);
                const rhs = expectInt(evalAnd(env));
                result = makeInt(if (lhs != 0 or rhs != 0) 1 else 0);
            },
            else => return result,
        }
    }
}

fn evalExpr(env: *Env) Value {
    return evalOr(env);
}

fn renderString(env: *Env, raw: []const u8) void {
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '{') {
            var j = i + 1;
            while (j < raw.len and raw[j] != '}') : (j += 1) {}
            if (j >= raw.len) {
                print("{{", .{});
                i += 1;
                continue;
            }
            const expr = raw[i + 1 .. j];

            // Trim spaces
            var k: usize = 0;
            while (k < expr.len and (expr[k] == ' ' or expr[k] == '\t')) : (k += 1) {}
            const start_name = k;
            while (k < expr.len and (isAlpha(expr[k]) or isDigit(expr[k]))) : (k += 1) {}
            const name = expr[start_name..k];
            while (k < expr.len and (expr[k] == ' ' or expr[k] == '\t')) : (k += 1) {}

            if (k < expr.len and expr[k] == '(') {
                // Simple function call in interpolation, e.g. {fib(16)} or {fib(x)}
                k += 1;
                while (k < expr.len and (expr[k] == ' ' or expr[k] == '\t')) : (k += 1) {}

                var arg_val: Value = makeInt(0);
                if (k < expr.len and isDigit(expr[k])) {
                    const arg_start = k;
                    while (k < expr.len and isDigit(expr[k])) : (k += 1) {}
                    arg_val = makeInt(std.fmt.parseInt(i64, expr[arg_start..k], 10) catch @panic("bad int in interpolation"));
                } else {
                    const arg_start = k;
                    while (k < expr.len and (isAlpha(expr[k]) or isDigit(expr[k]))) : (k += 1) {}
                    const arg_name = expr[arg_start..k];
                    arg_val = env.get(arg_name) orelse @panic("undefined var in interpolation");
                }

                // Skip until closing ')'
                while (k < expr.len and expr[k] != ')') : (k += 1) {}

                const val = runFunction(name, arg_val, null, null, env);
                switch (val) {
                    .int => |n| print("{d}", .{n}),
                    .str => |s| print("{s}", .{s}),
                }
            } else {
                // Plain variable interpolation
                if (env.get(name)) |v| {
                    switch (v) {
                        .int => |n| print("{d}", .{n}),
                        .str => |s| print("{s}", .{s}),
                    }
                } else {
                    print("{{{s}}}", .{name});
                }
            }
            i = j + 1;
        } else {
            // Basic escape handling: \n → newline
            if (c == '\\' and i + 1 < raw.len and raw[i + 1] == 'n') {
                print("\n", .{});
                i += 2;
            } else {
                var buf: [1]u8 = .{c};
                print("{s}", .{buf[0..]});
                i += 1;
            }
        }
    }
}

fn execBlock(env: *Env) ?Value {
    consume(.l_brace);
    while (peek().kind != .r_brace and peek().kind != .eof) {
        if (evalStmt(env)) |ret| return ret;
    }
    if (peek().kind == .r_brace) consume(.r_brace);
    return null;
}

fn evalStmt(env: *Env) ?Value {
    const t = peek();

    switch (t.kind) {
        .keyword_if => {
            _ = advance(); // 'if'
            const cond = expectInt(evalExpr(env));

            if (cond != 0) {
                if (peek().kind == .l_brace) {
                    if (execBlock(env)) |ret| return ret;
                } else {
                    if (evalStmt(env)) |ret| return ret;
                }
            } else {
                if (peek().kind == .l_brace) {
                    consume(.l_brace);
                    var depth: usize = 1;
                    while (depth > 0 and peek().kind != .eof) {
                        const t2 = advance();
                        switch (t2.kind) {
                            .l_brace => depth += 1,
                            .r_brace => depth -= 1,
                            else => {},
                        }
                    }
                } else {
                    // skip one statement
                    _ = evalStmt(env);
                }
            }
        },
        .keyword_while => {
            _ = advance(); // 'while'

            const cond_start = pos;
            var cond = expectInt(evalExpr(env));

            const body_start = pos;
            if (peek().kind != .l_brace) @panic("while: expected {");

            var scan_pos: usize = body_start;
            var depth: usize = 0;
            while (scan_pos < tokens.len) : (scan_pos += 1) {
                switch (tokens[scan_pos].kind) {
                    .l_brace => depth += 1,
                    .r_brace => {
                        depth -= 1;
                        if (depth == 0) {
                            scan_pos += 1;
                            break;
                        }
                    },
                    else => {},
                }
            }

            const body_end = scan_pos;
            if (body_end <= body_start or tokens[body_end - 1].kind != .r_brace) {
                @panic("while: unterminated block");
            }

            while (cond != 0) {
                pos = body_start;
                if (execBlock(env)) |ret| {
                    pos = body_end;
                    return ret;
                }

                pos = cond_start;
                cond = expectInt(evalExpr(env));
            }

            pos = body_end;
        },
        .l_brace => {
            // Skip stray brace tokens inside function bodies.
            _ = advance();
        },
        .r_brace => {
            _ = advance();
        },
        .keyword_print => {
            _ = advance(); // 'print'
            if (peek().kind == .l_paren) consume(.l_paren);

            if (peek().kind == .string) {
                const tok = advance();
                const raw = tok.text[1 .. tok.text.len - 1]; // strip quotes
                renderString(env, raw);
            } else {
                const val = evalExpr(env);
                switch (val) {
                    .int => |n| print("{d}", .{n}),
                    .str => |s| print("{s}", .{s}),
                }
            }

            if (peek().kind == .r_paren) consume(.r_paren);
        },
        .keyword_let => {
            _ = advance(); // 'let'
            const name_tok = advance();
            if (name_tok.kind != .identifier) @panic("expected identifier after let");
            consume(.equal);
            const val = evalExpr(env);
            env.set(name_tok.text, val);
        },
        .keyword_return => {
            _ = advance(); // 'return'
            if (peek().kind == .eof or peek().kind == .r_brace) {
                return makeInt(0);
            }
            const val = evalExpr(env);
            return val;
        },
        .eof => {},
        else => {
            // Expression statement: evaluate and ignore the result.
            _ = evalExpr(env);
        },
    }

    return null;
}

pub fn main() !void {
    const host_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, host_args);

    var argi: usize = 1;
    if (host_args.len > 1 and (std.mem.eql(u8, host_args[1], "--verbose") or std.mem.eql(u8, host_args[1], "-v"))) {
        verbose = true;
        argi = 2;
    }

    var file_path: []const u8 = "src/vex.vex";

    if (host_args.len <= argi) {
        // Default demo program.
        if (verbose) {
            print("\nVEX v0.0.4 - LIVE INTERPRETER - NO LLVM - RUNS NOW\n\n", .{});
        }

        const file_buf = try allocator.dupe(u8, file_path);
        const args_buf = try allocator.alloc([]u8, 1);
        args_buf[0] = file_buf;
        script_args = args_buf;
        file_path = file_buf;
    } else {
        const cmd = host_args[argi];

        if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
            print(
                \\vex - Vex bootstrap interpreter
                \\
                \\Usage:
                \\  vex [--verbose|-v] <file.vex> [args...]
                \\  vex [--verbose|-v] run <file.vex> [args...]
                \\  vex [--verbose|-v] lex <file.vex>
                \\
                \\Notes:
                \\  - with no args, runs `src/vex.vex`
                \\  - `arg_get(0)` is the script path
                \\  - `arg_get(1..)` are script arguments
                \\
            , .{});
            return;
        }

        if (std.mem.eql(u8, cmd, "run")) {
            if (host_args.len <= argi + 1) {
                print("error: missing file\n", .{});
                return;
            }
            file_path = host_args[argi + 1];
            script_args = host_args[(argi + 1)..];
        } else if (std.mem.eql(u8, cmd, "lex")) {
            if (host_args.len <= argi + 1) {
                print("error: missing file\n", .{});
                return;
            }

            const compiler_script = try allocator.dupe(u8, "src/compiler_core.vex");
            const args_buf = try allocator.alloc([]u8, 2);
            args_buf[0] = compiler_script;
            args_buf[1] = host_args[argi + 1];

            file_path = compiler_script;
            script_args = args_buf;
        } else {
            // Treat as a file path.
            file_path = cmd;
            script_args = host_args[argi..];
        }

        if (verbose) {
            print("\nVEX v0.0.4 - LIVE INTERPRETER - NO LLVM - RUNS NOW\n\n", .{});
        }
    }

    const source = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
    defer allocator.free(source);

    var list = std.ArrayList(Token).init(allocator);
    defer list.deinit();

    var i: usize = 0;
    var line: usize = 1;
    while (i < source.len) {
        const c = source[i];

        if (c == ' ' or c == '\t' or c == '\r') {
            i += 1;
            continue;
        }
        if (c == '\n') {
            line += 1;
            i += 1;
            continue;
        }

        // Line comments: // ...
        if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
            i += 2;
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            continue;
        }

        if (c == '"') {
            const start = i;
            i += 1;
            while (i < source.len and source[i] != '"') : (i += 1) {}
            if (i >= source.len) @panic("unterminated string");
            i += 1;
            try list.append(.{
                .kind = .string,
                .text = source[start..i],
                .line = line,
            });
            continue;
        }

        switch (c) {
            '(' => {
                try list.append(.{ .kind = .l_paren, .text = source[i..i+1], .line = line });
                i += 1;
                continue;
            },
            ')' => {
                try list.append(.{ .kind = .r_paren, .text = source[i..i+1], .line = line });
                i += 1;
                continue;
            },
            '{' => {
                try list.append(.{ .kind = .l_brace, .text = source[i..i+1], .line = line });
                i += 1;
                continue;
            },
            '}' => {
                try list.append(.{ .kind = .r_brace, .text = source[i..i+1], .line = line });
                i += 1;
                continue;
            },
            '+' => {
                try list.append(.{ .kind = .plus, .text = source[i..i+1], .line = line });
                i += 1;
                continue;
            },
            '-' => {
                try list.append(.{ .kind = .minus, .text = source[i..i+1], .line = line });
                i += 1;
                continue;
            },
            '*' => {
                try list.append(.{ .kind = .star, .text = source[i..i+1], .line = line });
                i += 1;
                continue;
            },
            '/' => {
                try list.append(.{ .kind = .slash, .text = source[i..i+1], .line = line });
                i += 1;
                continue;
            },
            '<' => {
                if (i + 1 < source.len and source[i + 1] == '=') {
                    try list.append(.{ .kind = .less_equal, .text = source[i..i+2], .line = line });
                    i += 2;
                } else {
                    try list.append(.{ .kind = .less, .text = source[i..i+1], .line = line });
                    i += 1;
                }
                continue;
            },
            '=' => {
                if (i + 1 < source.len and source[i + 1] == '=') {
                    try list.append(.{ .kind = .equal_equal, .text = source[i..i+2], .line = line });
                    i += 2;
                } else {
                    try list.append(.{ .kind = .equal, .text = source[i..i+1], .line = line });
                    i += 1;
                }
                continue;
            },
            '!' => {
                if (i + 1 < source.len and source[i + 1] == '=') {
                    try list.append(.{ .kind = .bang_equal, .text = source[i..i+2], .line = line });
                    i += 2;
                } else {
                    i += 1;
                }
                continue;
            },
            else => {},
        }

        if (isDigit(c)) {
            const start = i;
            i += 1;
            while (i < source.len and isDigit(source[i])) : (i += 1) {}
            try list.append(.{
                .kind = .integer,
                .text = source[start..i],
                .line = line,
            });
            continue;
        }

        if (isAlpha(c)) {
            const start = i;
            i += 1;
            while (i < source.len and (isAlpha(source[i]) or isDigit(source[i]))) : (i += 1) {}
            const word = source[start..i];
            const kind: Token.Kind =
                if (std.mem.eql(u8, word, "let")) .keyword_let
                else if (std.mem.eql(u8, word, "print")) .keyword_print
                else if (std.mem.eql(u8, word, "fn")) .keyword_fn
                else if (std.mem.eql(u8, word, "return")) .keyword_return
                else if (std.mem.eql(u8, word, "if")) .keyword_if
                else if (std.mem.eql(u8, word, "while")) .keyword_while
                else if (std.mem.eql(u8, word, "and")) .keyword_and
                else if (std.mem.eql(u8, word, "or")) .keyword_or
                else if (std.mem.eql(u8, word, "accel")) .keyword_accel
                else .identifier;
            try list.append(.{
                .kind = kind,
                .text = word,
                .line = line,
            });
            continue;
        }

        i += 1;
    }

    try list.append(.{
        .kind = .eof,
        .text = "",
        .line = line,
    });

    tokens = list.items;
    pos = 0;

    functions = std.StringHashMap(Func).init(allocator);

    const global_env = try Env.create(null);

    while (peek().kind != .eof) {
        const t = peek();
        switch (t.kind) {
            .keyword_accel => parseFunction(true),
            .keyword_fn => parseFunction(false),
            .eof => {},
            else => {
                _ = evalStmt(global_env);
                if (verbose and peek().kind != .eof) {
                    print("\n", .{});
                }
            },
        }
    }

    if (functions.get("main")) |main_func| {
        _ = main_func; // value unused, we just check existence
        _ = runFunction("main", null, null, null, global_env);
    }

    if (verbose) {
        print("\n\nVEX JUST RAN YOUR CODE - NO LLVM - NO EXCUSES\n", .{});
        print("THE FINAL LANGUAGE IS ALIVE - RIGHT NOW\n", .{});
    }
}
