// bootstrap/main.zig — v0.0.4 LIVE INTERPRETER (NO LLVM)
const std = @import("std");
const print = std.debug.print;
const allocator = std.heap.page_allocator;

const Value = i64;

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
        keyword_accel,
        l_paren,
        r_paren,
        l_brace,
        r_brace,
        equal,
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
    body: []Token,
    is_accel: bool,
};

var tokens: []Token = &[_]Token{};
var pos: usize = 0;
var functions: std.StringHashMap(Func) = undefined;

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

    if (peek().kind == .l_paren) {
        consume(.l_paren);
        if (peek().kind != .r_paren) {
            const param_tok = advance();
            if (param_tok.kind != .identifier) @panic("expected parameter name");
            param_name = param_tok.text;
            // Skip the rest of the signature (types, etc.) until ')'
            while (peek().kind != .r_paren and peek().kind != .eof) {
                _ = advance();
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
        .body = body_slice,
        .is_accel = is_accel,
    };

    functions.put(func.name, func) catch @panic("oom");

    if (is_accel) {
        print("[@accel] registered {s} (CPU stub now, GPU later)\n", .{func.name});
    }
}

fn runFunction(name: []const u8, arg: ?Value, caller_env: *Env) Value {
    const func = functions.get(name) orelse @panic("undefined function");

    const saved_tokens = tokens;
    const saved_pos = pos;

    tokens = func.body;
    pos = 0;

    const local_env = Env.create(caller_env) catch @panic("oom");

    if (func.param_name) |param| {
        if (arg) |a| {
            local_env.set(param, a);
        } else {
            local_env.set(param, 0);
        }
    }

    var result: Value = 0;
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

    return if (has_result) result else 0;
}

fn evalPrimary(env: *Env) Value {
    const t = peek();

    // function call: name(...)
    if (t.kind == .identifier and pos + 1 < tokens.len and tokens[pos + 1].kind == .l_paren) {
        const name = t.text;
        _ = advance(); // identifier
        consume(.l_paren);

        var arg: ?Value = null;
        if (peek().kind != .r_paren) {
            arg = evalExpr(env);
        }
        if (peek().kind == .r_paren) consume(.r_paren);

        return runFunction(name, arg, env);
    }

    const token = advance();

    return switch (token.kind) {
        .integer => std.fmt.parseInt(i64, token.text, 10) catch @panic("bad integer"),
        .identifier => env.get(token.text) orelse @panic("undefined var"),
        .l_paren => blk: {
            const v = evalExpr(env);
            consume(.r_paren);
            break :blk v;
        },
        else => @panic("expected expression"),
    };
}

fn evalTerm(env: *Env) Value {
    var result = evalPrimary(env);

    while (true) {
        const t = peek();
        switch (t.kind) {
            .star => {
                _ = advance();
                const rhs = evalPrimary(env);
                result *= rhs;
            },
            .slash => {
                _ = advance();
                const rhs = evalPrimary(env);
                result = @divTrunc(result, rhs);
            },
            else => return result,
        }
    }
}

fn evalExpr(env: *Env) Value {
    var result = evalTerm(env);

    while (true) {
        const t = peek();
        switch (t.kind) {
            .plus => {
                _ = advance();
                const rhs = evalTerm(env);
                result += rhs;
            },
            .minus => {
                _ = advance();
                const rhs = evalTerm(env);
                result -= rhs;
            },
            .less => {
                _ = advance();
                const rhs = evalTerm(env);
                result = if (result < rhs) 1 else 0;
            },
            .less_equal => {
                _ = advance();
                const rhs = evalTerm(env);
                result = if (result <= rhs) 1 else 0;
            },
            else => return result,
        }
    }
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

                var arg_val: Value = 0;
                if (k < expr.len and isDigit(expr[k])) {
                    const arg_start = k;
                    while (k < expr.len and isDigit(expr[k])) : (k += 1) {}
                    arg_val = std.fmt.parseInt(i64, expr[arg_start..k], 10) catch @panic("bad int in interpolation");
                } else {
                    const arg_start = k;
                    while (k < expr.len and (isAlpha(expr[k]) or isDigit(expr[k]))) : (k += 1) {}
                    const arg_name = expr[arg_start..k];
                    arg_val = env.get(arg_name) orelse @panic("undefined var in interpolation");
                }

                // Skip until closing ')'
                while (k < expr.len and expr[k] != ')') : (k += 1) {}

                const val = runFunction(name, arg_val, env);
                print("{d}", .{val});
            } else {
                // Plain variable interpolation
                if (env.get(name)) |v| {
                    print("{d}", .{v});
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
        .keyword_print => {
            _ = advance(); // 'print'
            if (peek().kind == .l_paren) consume(.l_paren);

            if (peek().kind == .string) {
                const tok = advance();
                const raw = tok.text[1 .. tok.text.len - 1]; // strip quotes
                renderString(env, raw);
            } else {
                const val = evalExpr(env);
                print("{d}", .{val});
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
        .keyword_if => {
            _ = advance(); // 'if'
            const cond = evalExpr(env);
            if (cond != 0) {
                if (peek().kind != .l_brace) @panic("expected { after if");
                if (execBlock(env)) |ret| return ret;
            } else {
                if (peek().kind != .l_brace) @panic("expected { after if");
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
            }
        },
        .keyword_return => {
            _ = advance(); // 'return'
            if (peek().kind == .eof or peek().kind == .r_brace) {
                return 0;
            }
            const val = evalExpr(env);
            return val;
        },
        .eof => {},
        else => {
            _ = advance();
        },
    }

    return null;
}

pub fn main() !void {
    print("\nVEX v0.0.4 - LIVE INTERPRETER - NO LLVM - RUNS NOW\n\n", .{});

    const source = try std.fs.cwd().readFileAlloc(allocator, "src/vex.vex", 1024 * 1024);
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
                try list.append(.{ .kind = .equal, .text = source[i..i+1], .line = line });
                i += 1;
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
                if (peek().kind != .eof) {
                    print("\n", .{});
                }
            },
        }
    }

    if (functions.get("main")) |main_func| {
        _ = main_func; // value unused, we just check existence
        _ = runFunction("main", null, global_env);
    }

    print("\n\nVEX JUST RAN YOUR CODE - NO LLVM - NO EXCUSES\n", .{});
    print("THE FINAL LANGUAGE IS ALIVE - RIGHT NOW\n", .{});
}
