// bootstrap/main.zig — Day 0 lexer + hello world parser
const std = @import("std");

const Token = struct {
    kind: Kind,
    text: []const u8,
    line: usize,
    col: usize,

    pub const Kind = enum {
        eof,
        identifier,
        keyword_fn,
        keyword_let,
        keyword_mut,
        keyword_comptime,
        l_brace,
        r_brace,
        l_paren,
        r_paren,
        equal,
        semicolon,
        comma,
        string,
        integer,
        float,
        plus,
        minus,
        star,
        slash,
        at,
        arrow,
    };
};

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

const Lexer = struct {
    source: []const u8,
    pos: usize = 0,
    line: usize = 1,
    col: usize = 1,

    fn next(self: *Lexer) u8 {
        if (self.pos >= self.source.len) return 0;
        const c = self.source[self.pos];
        self.pos += 1;
        self.col += 1;
        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        }
        return c;
    }

    fn peek(self: *Lexer) u8 {
        if (self.pos >= self.source.len) return 0;
        return self.source[self.pos];
    }

    fn makeToken(
        self: *Lexer,
        kind: Token.Kind,
        start: usize,
        start_line: usize,
        start_col: usize,
    ) Token {
        _ = self;
        return Token{
            .kind = kind,
            .text = self.source[start..self.pos],
            .line = start_line,
            .col = start_col,
        };
    }

    fn lex(self: *Lexer) !std.ArrayList(Token) {
        var tokens = std.ArrayList(Token).init(std.heap.page_allocator);

        while (true) {
            var c = self.peek();
            if (c == 0) break;

            // Skip whitespace
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                _ = self.next();
                continue;
            }

            const start = self.pos;
            const start_line = self.line;
            const start_col = self.col;

            c = self.next();

            switch (c) {
                '{' => try tokens.append(self.makeToken(.l_brace, start, start_line, start_col)),
                '}' => try tokens.append(self.makeToken(.r_brace, start, start_line, start_col)),
                '(' => try tokens.append(self.makeToken(.l_paren, start, start_line, start_col)),
                ')' => try tokens.append(self.makeToken(.r_paren, start, start_line, start_col)),
                '=' => try tokens.append(self.makeToken(.equal, start, start_line, start_col)),
                ';' => try tokens.append(self.makeToken(.semicolon, start, start_line, start_col)),
                ',' => try tokens.append(self.makeToken(.comma, start, start_line, start_col)),
                '@' => try tokens.append(self.makeToken(.at, start, start_line, start_col)),
                '+' => try tokens.append(self.makeToken(.plus, start, start_line, start_col)),
                '-' => {
                    if (self.peek() == '>') {
                        _ = self.next();
                        try tokens.append(self.makeToken(.arrow, start, start_line, start_col));
                    } else {
                        try tokens.append(self.makeToken(.minus, start, start_line, start_col));
                    }
                },
                '*' => try tokens.append(self.makeToken(.star, start, start_line, start_col)),
                '/' => try tokens.append(self.makeToken(.slash, start, start_line, start_col)),
                '"' => {
                    // Consume until closing quote or EOF
                    while (true) {
                        const p = self.peek();
                        if (p == 0 or p == '"') break;
                        _ = self.next();
                    }
                    if (self.peek() == '"') _ = self.next();
                    try tokens.append(self.makeToken(.string, start, start_line, start_col));
                },
                else => {
                    if (isAlpha(c)) {
                        while (true) {
                            const p = self.peek();
                            if (!(isAlpha(p) or isDigit(p))) break;
                            _ = self.next();
                        }
                        const text = self.source[start..self.pos];
                        const kind: Token.Kind =
                            if (std.mem.eql(u8, text, "fn")) .keyword_fn
                            else if (std.mem.eql(u8, text, "let")) .keyword_let
                            else if (std.mem.eql(u8, text, "mut")) .keyword_mut
                            else if (std.mem.eql(u8, text, "comptime")) .keyword_comptime
                            else .identifier;
                        try tokens.append(self.makeToken(kind, start, start_line, start_col));
                    } else if (isDigit(c)) {
                        var has_dot = false;
                        while (true) {
                            const p = self.peek();
                            if (isDigit(p)) {
                                _ = self.next();
                            } else if (p == '.' and !has_dot) {
                                has_dot = true;
                                _ = self.next();
                            } else break;
                        }
                        const kind: Token.Kind = if (has_dot) .float else .integer;
                        try tokens.append(self.makeToken(kind, start, start_line, start_col));
                    } else {
                        // Unknown character for now: skip
                    }
                },
            }
        }

        try tokens.append(Token{
            .kind = .eof,
            .text = "",
            .line = self.line,
            .col = self.col,
        });

        return tokens;
    }
};

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    try out.print("Vex bootstrap v0.0.1 — ALIVE AND BREATHING\n", .{});
    try out.print("RTX 4060 Ti 8GB ready for war.\n", .{});

    // Try to read src/vex.vex if it exists
    const file = std.fs.cwd().openFile("src/vex.vex", .{}) catch {
        try out.print("Create src/vex.vex → we will parse it live.\n", .{});
        return;
    };
    defer file.close();

    const source = try file.readToEndAlloc(std.heap.page_allocator, 1024 * 1024);
    defer std.heap.page_allocator.free(source);

    var lexer = Lexer{ .source = source };
    var tokens = try lexer.lex();
    defer tokens.deinit();

    try out.print("Successfully parsed {d} tokens from src/vex.vex\n", .{tokens.items.len - 1});
    try out.print("First 10 tokens:\n", .{});

    const count = @min(tokens.items.len, 10);
    for (tokens.items[0..count]) |tok| {
        try out.print("  {s}: \"{s}\"\n", .{ @tagName(tok.kind), tok.text });
    }

    try out.print("\nVex lives. The fire rises.\n", .{});
}
