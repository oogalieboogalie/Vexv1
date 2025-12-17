// bootstrap/main.zig - v0.0.4 LIVE INTERPRETER (NO LLVM)
const std = @import("std");
const print = std.debug.print;
const allocator = std.heap.page_allocator;

const Value = union(enum) {
    int: i64,
    str: []const u8,
};

const Control = union(enum) {
    none,
    ret: Value,
    brk,
    cont,
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

fn builtinListSet(list_handle: Value, idx_value: Value, value: Value) void {
    if (isZeroInt(list_handle)) return;
    const addr = @as(usize, @intCast(expectInt(list_handle)));
    const list_ptr = @as(*VexList, @ptrFromInt(addr));
    const idx_signed = expectInt(idx_value);
    if (idx_signed < 0) return;
    const idx: usize = @intCast(idx_signed);

    if (idx < list_ptr.items.items.len) {
        list_ptr.items.items[idx] = value;
        return;
    }

    if (idx == list_ptr.items.items.len) {
        list_ptr.items.append(value) catch @panic("oom");
    }
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

// --- Bytecode VM (Zig runtime) ---
// This executes the bytecode emitted by `src/compiler_core.vex`.
//
// Instruction format is a Vex list: [op, a?, b?]
// Ops:
//   1  PUSH_INT value
//   2  PUSH_STR value
//   3  LOAD name
//   4  STORE name
//   10 BIN op_kind
//   11 CALL name argc
//   12 POP
//   13 JMP target_ip
//   14 JMP_Z target_ip
//   15 RET
//   16 PRINT
//   17 PRINT_STR raw
//   18 DUP2
//   19 TMP_SET idx
//   20 TMP_GET idx
//   99 TRAP message

fn bcListPtr(handle: Value) ?*VexList {
    if (isZeroInt(handle)) return null;
    const addr = @as(usize, @intCast(expectInt(handle)));
    return @as(*VexList, @ptrFromInt(addr));
}

fn bcListLen(handle: Value) usize {
    if (bcListPtr(handle)) |list_ptr| {
        return list_ptr.items.items.len;
    }
    return 0;
}

fn bcListGet(handle: Value, idx: usize) Value {
    if (bcListPtr(handle)) |list_ptr| {
        if (idx < list_ptr.items.items.len) {
            return list_ptr.items.items[idx];
        }
    }
    return makeInt(0);
}

fn bcStackPop(stack: *std.ArrayList(Value)) Value {
    return stack.popOrNull() orelse makeInt(0);
}

fn bcTmpSet(tmps: *std.ArrayList(Value), idx: usize, v: Value) void {
    if (idx < tmps.items.len) {
        tmps.items[idx] = v;
        return;
    }
    while (tmps.items.len < idx) {
        tmps.append(makeInt(0)) catch @panic("oom");
    }
    if (idx == tmps.items.len) {
        tmps.append(v) catch @panic("oom");
    }
}

fn bcTmpGet(tmps: []const Value, idx: usize) Value {
    if (idx < tmps.len) return tmps[idx];
    return makeInt(0);
}

fn bcEnvFindOrZero(env_handle: Value, key: []const u8) Value {
    if (builtinEnvFind(env_handle, key)) |v| return v;
    return makeInt(0);
}

fn bcPrintValue(v: Value) void {
    switch (v) {
        .int => |n| print("{d}", .{n}),
        .str => |s| print("{s}", .{s}),
    }
}

fn bcParseIntDigits(bytes: []const u8) i64 {
    var v: i64 = 0;
    for (bytes) |c| {
        if (!isDigit(c)) break;
        v = v * 10 + @as(i64, @intCast(c - '0'));
    }
    return v;
}

fn bcRenderString(raw: []const u8, vals_env: Value, defs_env: Value, bc_funcs: Value, prog_args: Value) void {
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '{') {
            var j: usize = i + 1;
            while (j < raw.len and raw[j] != '}') : (j += 1) {}
            if (j >= raw.len) {
                print("{c}", .{'{'});
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
                // Simple function call in interpolation: {name(16)} or {name(x)}
                k += 1;
                while (k < expr.len and (expr[k] == ' ' or expr[k] == '\t')) : (k += 1) {}

                var arg_val: Value = makeInt(0);
                if (k < expr.len and isDigit(expr[k])) {
                    const arg_start = k;
                    while (k < expr.len and isDigit(expr[k])) : (k += 1) {}
                    arg_val = makeInt(bcParseIntDigits(expr[arg_start..k]));
                } else {
                    const arg_start = k;
                    while (k < expr.len and (isAlpha(expr[k]) or isDigit(expr[k]))) : (k += 1) {}
                    const arg_name = expr[arg_start..k];
                    arg_val = bcEnvFindOrZero(vals_env, arg_name);
                }

                const tmp_args = [_]Value{arg_val};
                const v = bcCallValue(name, tmp_args[0..], vals_env, defs_env, bc_funcs, prog_args);
                bcPrintValue(v);
            } else {
                // variable: {x}
                const def = bcEnvFindOrZero(defs_env, name);
                if (!isZeroInt(def)) {
                    bcPrintValue(bcEnvFindOrZero(vals_env, name));
                } else {
                    print("{c}{s}{c}", .{'{', name, '}'});
                }
            }

            i = j + 1;
            continue;
        }

        // Basic escape handling: \n
        if (c == '\\' and i + 1 < raw.len and raw[i + 1] == 'n') {
            print("\n", .{});
            i += 2;
            continue;
        }

        print("{c}", .{c});
        i += 1;
    }
}

fn bcRunProgram(bc_funcs: Value, prog_args: Value) Value {
    if (builtinEnvFind(bc_funcs, "main")) |main_rec| {
        const root_vals = builtinEnvCreate(null);
        const root_defs = builtinEnvCreate(null);
        const tmp_args = [_]Value{};
        return bcExecFunc(main_rec, tmp_args[0..], root_vals, root_defs, bc_funcs, prog_args);
    }

    print("[no main]\n", .{});
    return makeInt(0);
}

fn bcCallValue(name: []const u8, args: []const Value, caller_vals: Value, caller_defs: Value, bc_funcs: Value, prog_args: Value) Value {
    // Builtins
    if (std.mem.eql(u8, name, "env_create")) {
        const parent_handle: Value = if (args.len > 0) args[0] else makeInt(0);
        return builtinEnvCreate(parent_handle);
    } else if (std.mem.eql(u8, name, "env_set")) {
        const env_handle = if (args.len > 0) args[0] else makeInt(0);
        const key = expectStr(if (args.len > 1) args[1] else Value{ .str = "" });
        const val = if (args.len > 2) args[2] else makeInt(0);
        builtinEnvSet(env_handle, key, val);
        return makeInt(0);
    } else if (std.mem.eql(u8, name, "env_find")) {
        const env_handle = if (args.len > 0) args[0] else makeInt(0);
        const key = expectStr(if (args.len > 1) args[1] else Value{ .str = "" });
        if (builtinEnvFind(env_handle, key)) |v| return v;
        return makeInt(0);
    } else if (std.mem.eql(u8, name, "str_len")) {
        const s = expectStr(if (args.len > 0) args[0] else Value{ .str = "" });
        return makeInt(@as(i64, @intCast(s.len)));
    } else if (std.mem.eql(u8, name, "str_char")) {
        const s = expectStr(if (args.len > 0) args[0] else Value{ .str = "" });
        const idx = expectInt(if (args.len > 1) args[1] else makeInt(0));
        if (idx < 0 or @as(usize, @intCast(idx)) >= s.len) return makeInt(0);
        return makeInt(@as(i64, s[@as(usize, @intCast(idx))]));
    } else if (std.mem.eql(u8, name, "str_slice")) {
        const s = expectStr(if (args.len > 0) args[0] else Value{ .str = "" });
        var start = expectInt(if (args.len > 1) args[1] else makeInt(0));
        var end = expectInt(if (args.len > 2) args[2] else makeInt(0));
        if (start < 0) start = 0;
        if (end < start) end = start;
        const len = @as(i64, @intCast(s.len));
        if (start > len) start = len;
        if (end > len) end = len;
        const ustart: usize = @intCast(start);
        const uend: usize = @intCast(end);
        return .{ .str = s[ustart..uend] };
    } else if (std.mem.eql(u8, name, "print_bytes")) {
        builtinPrintBytes(expectStr(if (args.len > 0) args[0] else Value{ .str = "" }));
        return makeInt(0);
    } else if (std.mem.eql(u8, name, "print_char")) {
        const b: u8 = @intCast(expectInt(if (args.len > 0) args[0] else makeInt(0)));
        builtinPrintChar(b);
        return makeInt(0);
    } else if (std.mem.eql(u8, name, "list_create")) {
        return builtinListCreate();
    } else if (std.mem.eql(u8, name, "list_push")) {
        const list_handle = if (args.len > 0) args[0] else makeInt(0);
        const v = if (args.len > 1) args[1] else makeInt(0);
        builtinListPush(list_handle, v);
        return makeInt(0);
    } else if (std.mem.eql(u8, name, "list_len")) {
        const list_handle = if (args.len > 0) args[0] else makeInt(0);
        return builtinListLen(list_handle);
    } else if (std.mem.eql(u8, name, "list_get")) {
        const list_handle = if (args.len > 0) args[0] else makeInt(0);
        const idx_val = if (args.len > 1) args[1] else makeInt(0);
        return builtinListGet(list_handle, idx_val);
    } else if (std.mem.eql(u8, name, "list_set")) {
        const list_handle = if (args.len > 0) args[0] else makeInt(0);
        const idx_val = if (args.len > 1) args[1] else makeInt(0);
        const v = if (args.len > 2) args[2] else makeInt(0);
        builtinListSet(list_handle, idx_val, v);
        return makeInt(0);
    } else if (std.mem.eql(u8, name, "read_file")) {
        const path = expectStr(if (args.len > 0) args[0] else Value{ .str = "" });
        return builtinReadFile(path);
    } else if (std.mem.eql(u8, name, "write_file")) {
        const path = expectStr(if (args.len > 0) args[0] else Value{ .str = "" });
        const data = expectStr(if (args.len > 1) args[1] else Value{ .str = "" });
        builtinWriteFile(path, data);
        return makeInt(0);
    } else if (std.mem.eql(u8, name, "arg_len")) {
        return makeInt(@intCast(bcListLen(prog_args)));
    } else if (std.mem.eql(u8, name, "arg_get")) {
        const idx_signed = expectInt(if (args.len > 0) args[0] else makeInt(0));
        const n = bcListLen(prog_args);
        if (idx_signed < 0) return .{ .str = "" };
        const idx: usize = @intCast(idx_signed);
        if (idx >= n) return .{ .str = "" };
        const v = bcListGet(prog_args, idx);
        return .{ .str = expectStr(v) };
    } else if (std.mem.eql(u8, name, "bc_run")) {
        const new_bc_funcs = if (args.len > 0) args[0] else makeInt(0);
        const new_prog_args = if (args.len > 1) args[1] else makeInt(0);
        return bcRunProgram(new_bc_funcs, new_prog_args);
    }

    // User-defined
    if (builtinEnvFind(bc_funcs, name)) |func_rec| {
        return bcExecFunc(func_rec, args, caller_vals, caller_defs, bc_funcs, prog_args);
    }

    print("[undefined function] {s}\n", .{name});
    return makeInt(0);
}

fn bcExecFunc(func_rec: Value, args: []const Value, caller_vals: Value, caller_defs: Value, bc_funcs: Value, prog_args: Value) Value {
    const vals = builtinEnvCreate(caller_vals);
    const defs = builtinEnvCreate(caller_defs);

    const params = bcListGet(func_rec, 1);
    const nparams = bcListLen(params);
    for (0..nparams) |idx| {
        const p = expectStr(bcListGet(params, idx));
        if (p.len == 0) continue;
        const v: Value = if (idx < args.len) args[idx] else makeInt(0);
        builtinEnvSet(vals, p, v);
        builtinEnvSet(defs, p, makeInt(1));
    }

    const code = bcListGet(func_rec, 2);
    const ncode = bcListLen(code);

    var stack = std.ArrayList(Value).init(allocator);
    defer stack.deinit();

    var tmps = std.ArrayList(Value).init(allocator);
    defer tmps.deinit();

    var ip: usize = 0;
    while (ip < ncode) {
        const ins = bcListGet(code, ip);
        const op = expectInt(bcListGet(ins, 0));

        switch (op) {
            1 => { // PUSH_INT
                stack.append(bcListGet(ins, 1)) catch @panic("oom");
                ip += 1;
            },
            2 => { // PUSH_STR
                stack.append(bcListGet(ins, 1)) catch @panic("oom");
                ip += 1;
            },
            3 => { // LOAD
                const name = expectStr(bcListGet(ins, 1));
                const v = bcEnvFindOrZero(vals, name);
                stack.append(v) catch @panic("oom");
                ip += 1;
            },
            4 => { // STORE
                const name = expectStr(bcListGet(ins, 1));
                const v = bcStackPop(&stack);
                if (name.len != 0) {
                    builtinEnvSet(vals, name, v);
                    builtinEnvSet(defs, name, makeInt(1));
                }
                ip += 1;
            },
            10 => { // BIN
                const k = expectInt(bcListGet(ins, 1));
                const rhs = bcStackPop(&stack);
                const lhs = bcStackPop(&stack);

                var out: Value = makeInt(0);
                if (k == 18) out = makeInt(expectInt(lhs) + expectInt(rhs));
                if (k == 19) out = makeInt(expectInt(lhs) - expectInt(rhs));
                if (k == 20) out = makeInt(expectInt(lhs) * expectInt(rhs));
                if (k == 21) out = makeInt(@divTrunc(expectInt(lhs), expectInt(rhs)));

                if (k == 22) out = makeInt(if (expectInt(lhs) < expectInt(rhs)) 1 else 0);
                if (k == 23) out = makeInt(if (expectInt(lhs) <= expectInt(rhs)) 1 else 0);
                if (k == 26) out = makeInt(if (expectInt(lhs) > expectInt(rhs)) 1 else 0);
                if (k == 27) out = makeInt(if (expectInt(lhs) >= expectInt(rhs)) 1 else 0);

                if (k == 16) {
                    const eq = switch (lhs) {
                        .int => |li| switch (rhs) { .int => |ri| li == ri, .str => false },
                        .str => |ls| switch (rhs) { .str => |rs| std.mem.eql(u8, ls, rs), .int => false },
                    };
                    out = makeInt(if (eq) 1 else 0);
                }
                if (k == 17) {
                    const eq = switch (lhs) {
                        .int => |li| switch (rhs) { .int => |ri| li == ri, .str => false },
                        .str => |ls| switch (rhs) { .str => |rs| std.mem.eql(u8, ls, rs), .int => false },
                    };
                    out = makeInt(if (!eq) 1 else 0);
                }
                if (k == 24) out = makeInt(if (expectInt(lhs) != 0 and expectInt(rhs) != 0) 1 else 0);
                if (k == 25) out = makeInt(if (expectInt(lhs) != 0 or expectInt(rhs) != 0) 1 else 0);

                stack.append(out) catch @panic("oom");
                ip += 1;
            },
            11 => { // CALL
                const name = expectStr(bcListGet(ins, 1));
                const argc_signed = expectInt(bcListGet(ins, 2));
                if (argc_signed < 0) @panic("bytecode: negative argc");
                const argc: usize = @intCast(argc_signed);

                const args_buf = allocator.alloc(Value, argc) catch @panic("oom");
                defer allocator.free(args_buf);

                var j: usize = argc;
                while (j > 0) {
                    j -= 1;
                    args_buf[j] = bcStackPop(&stack);
                }

                const v = bcCallValue(name, args_buf, vals, defs, bc_funcs, prog_args);
                stack.append(v) catch @panic("oom");
                ip += 1;
            },
            12 => { // POP
                _ = bcStackPop(&stack);
                ip += 1;
            },
            13 => { // JMP
                const target = expectInt(bcListGet(ins, 1));
                if (target < 0) @panic("bytecode: negative jump");
                ip = @intCast(target);
            },
            14 => { // JMP_Z
                const target = expectInt(bcListGet(ins, 1));
                const cond = bcStackPop(&stack);
                if (expectInt(cond) == 0) {
                    if (target < 0) @panic("bytecode: negative jump");
                    ip = @intCast(target);
                } else {
                    ip += 1;
                }
            },
            15 => { // RET
                return bcStackPop(&stack);
            },
            16 => { // PRINT
                bcPrintValue(bcStackPop(&stack));
                ip += 1;
            },
            17 => { // PRINT_STR
                bcRenderString(expectStr(bcListGet(ins, 1)), vals, defs, bc_funcs, prog_args);
                ip += 1;
            },
            18 => { // DUP2
                if (stack.items.len < 2) {
                    print("dup2 underflow\n", .{});
                    return makeInt(0);
                }
                const a = stack.items[stack.items.len - 2];
                const b = stack.items[stack.items.len - 1];
                stack.append(a) catch @panic("oom");
                stack.append(b) catch @panic("oom");
                ip += 1;
            },
            19 => { // TMP_SET
                const idx_signed = expectInt(bcListGet(ins, 1));
                if (idx_signed < 0) @panic("bytecode: negative tmp idx");
                bcTmpSet(&tmps, @intCast(idx_signed), bcStackPop(&stack));
                ip += 1;
            },
            20 => { // TMP_GET
                const idx_signed = expectInt(bcListGet(ins, 1));
                if (idx_signed < 0) @panic("bytecode: negative tmp idx");
                stack.append(bcTmpGet(tmps.items, @intCast(idx_signed))) catch @panic("oom");
                ip += 1;
            },
            99 => { // TRAP
                bcPrintValue(bcListGet(ins, 1));
                return makeInt(0);
            },
            else => {
                print("bytecode: unknown op {d}\n", .{op});
                return makeInt(0);
            },
        }
    }

    return makeInt(0);
}

fn builtinBcRun(bc_funcs: Value, prog_args: Value) Value {
    return bcRunProgram(bc_funcs, prog_args);
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
        keyword_else,
        keyword_while,
        keyword_and,
        keyword_or,
        keyword_accel,
        keyword_true,
        keyword_false,
        keyword_null,
        keyword_for,
        keyword_in,
        keyword_break,
        keyword_continue,
        l_paren,
        r_paren,
        l_brace,
        r_brace,
        l_bracket,
        r_bracket,
        dot,
        dot_dot,
        equal,
        equal_equal,
        bang_equal,
        plus,
        plus_equal,
        minus,
        star,
        slash,
        less,
        less_equal,
        greater,
        greater_equal,
        eof,
    };
};

const Func = struct {
    name: []const u8,
    param_names: []const []const u8,
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
        .dot => "Dot",
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

    var params = std.ArrayList([]const u8).init(allocator);
    defer params.deinit();

    if (peek().kind == .l_paren) {
        consume(.l_paren);
        while (peek().kind != .r_paren and peek().kind != .eof) {
            const param_tok = advance();
            if (param_tok.kind == .identifier) {
                params.append(param_tok.text) catch @panic("oom");
            }
        }
        consume(.r_paren);
    }

    const param_names = allocator.dupe([]const u8, params.items) catch @panic("oom");

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
        .param_names = param_names,
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

fn runFunction(name: []const u8, args: []const Value, caller_env: *Env) Value {
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

    for (func.param_names, 0..) |param, idx| {
        const v = if (idx < args.len) args[idx] else makeInt(0);
        local_env.set(param, v);
    }

    var result: Value = makeInt(0);
    var has_result = false;

    while (peek().kind != .eof) {
        const ctrl = evalStmt(local_env);
        switch (ctrl) {
            .none => {},
            .ret => |ret| {
                result = ret;
                has_result = true;
                break;
            },
            .brk => @panic("break outside loop"),
            .cont => @panic("continue outside loop"),
        }
    }

    tokens = saved_tokens;
    pos = saved_pos;

    return if (has_result) result else makeInt(0);
}

fn evalPrimary(env: *Env) Value {
    const t = peek();

    // dot literal: .name -> "name"
    if (t.kind == .dot) {
        _ = advance(); // '.'
        const name_tok = advance();
        if (name_tok.kind != .identifier) @panic("dot literal: expected identifier");
        return .{ .str = name_tok.text };
    }

    var result: Value = undefined;

    // function call: name(...)
    if (t.kind == .identifier and pos + 1 < tokens.len and tokens[pos + 1].kind == .l_paren) {
        const name = t.text;

        _ = advance(); // identifier
        consume(.l_paren);

        var args_list = std.ArrayList(Value).init(allocator);
        defer args_list.deinit();
        while (peek().kind != .r_paren and peek().kind != .eof) {
            args_list.append(evalExpr(env)) catch @panic("oom");
        }
        if (peek().kind == .r_paren) consume(.r_paren);

        const args = args_list.items;

        // Built-ins live here for now.
        if (std.mem.eql(u8, name, "env_create")) {
            const parent_handle: ?Value = if (args.len > 0) args[0] else null;
            result = builtinEnvCreate(parent_handle);
        } else if (std.mem.eql(u8, name, "env_set")) {
            // env_set(env_handle, key, value)
            const env_handle = if (args.len > 0) args[0] else makeInt(0);
            const key = expectStr(if (args.len > 1) args[1] else Value{ .str = "" });
            const val = if (args.len > 2) args[2] else makeInt(0);
            builtinEnvSet(env_handle, key, val);
            result = makeInt(0);
        } else if (std.mem.eql(u8, name, "env_find")) {
            // env_find(env_handle, key)
            const env_handle = if (args.len > 0) args[0] else makeInt(0);
            const key = expectStr(if (args.len > 1) args[1] else Value{ .str = "" });
            if (builtinEnvFind(env_handle, key)) |v| {
                result = v;
            } else {
                result = makeInt(0);
            }
        } else if (std.mem.eql(u8, name, "str_len")) {
            const s = expectStr(if (args.len > 0) args[0] else Value{ .str = "" });
            result = makeInt(@as(i64, @intCast(s.len)));
        } else if (std.mem.eql(u8, name, "str_char")) {
            const s = expectStr(if (args.len > 0) args[0] else Value{ .str = "" });
            const idx = expectInt(if (args.len > 1) args[1] else makeInt(0));
            if (idx < 0 or @as(usize, @intCast(idx)) >= s.len) {
                result = makeInt(0);
            } else {
                result = makeInt(@as(i64, s[@as(usize, @intCast(idx))]));
            }
        } else if (std.mem.eql(u8, name, "str_slice")) {
            const s = expectStr(if (args.len > 0) args[0] else Value{ .str = "" });
            var start = expectInt(if (args.len > 1) args[1] else makeInt(0));
            var end = expectInt(if (args.len > 2) args[2] else makeInt(0));
            if (start < 0) start = 0;
            if (end < start) end = start;
            const len = @as(i64, @intCast(s.len));
            if (start > len) start = len;
            if (end > len) end = len;
            const ustart: usize = @intCast(start);
            const uend: usize = @intCast(end);
            result = .{ .str = s[ustart..uend] };
        } else if (std.mem.eql(u8, name, "print_bytes")) {
            builtinPrintBytes(expectStr(if (args.len > 0) args[0] else Value{ .str = "" }));
            result = makeInt(0);
        } else if (std.mem.eql(u8, name, "print_char")) {
            const b: u8 = @intCast(expectInt(if (args.len > 0) args[0] else makeInt(0)));
            builtinPrintChar(b);
            result = makeInt(0);
        } else if (std.mem.eql(u8, name, "list_create")) {
            result = builtinListCreate();
        } else if (std.mem.eql(u8, name, "list_push")) {
            const list_handle = if (args.len > 0) args[0] else makeInt(0);
            const v = if (args.len > 1) args[1] else makeInt(0);
            builtinListPush(list_handle, v);
            result = makeInt(0);
        } else if (std.mem.eql(u8, name, "list_len")) {
            const list_handle = if (args.len > 0) args[0] else makeInt(0);
            result = builtinListLen(list_handle);
        } else if (std.mem.eql(u8, name, "list_get")) {
            const list_handle = if (args.len > 0) args[0] else makeInt(0);
            const idx_val = if (args.len > 1) args[1] else makeInt(0);
            result = builtinListGet(list_handle, idx_val);
        } else if (std.mem.eql(u8, name, "list_set")) {
            const list_handle = if (args.len > 0) args[0] else makeInt(0);
            const idx_val = if (args.len > 1) args[1] else makeInt(0);
            const v = if (args.len > 2) args[2] else makeInt(0);
            builtinListSet(list_handle, idx_val, v);
            result = makeInt(0);
        } else if (std.mem.eql(u8, name, "read_file")) {
            const path = expectStr(if (args.len > 0) args[0] else Value{ .str = "" });
            result = builtinReadFile(path);
        } else if (std.mem.eql(u8, name, "write_file")) {
            const path = expectStr(if (args.len > 0) args[0] else Value{ .str = "" });
            const data = expectStr(if (args.len > 1) args[1] else Value{ .str = "" });
            builtinWriteFile(path, data);
            result = makeInt(0);
        } else if (std.mem.eql(u8, name, "arg_len")) {
            result = builtinArgLen();
        } else if (std.mem.eql(u8, name, "arg_get")) {
            const idx_val = if (args.len > 0) args[0] else makeInt(0);
            result = builtinArgGet(idx_val);
        } else if (std.mem.eql(u8, name, "bc_run")) {
            const bc_funcs = if (args.len > 0) args[0] else makeInt(0);
            const prog_args = if (args.len > 1) args[1] else makeInt(0);
            result = builtinBcRun(bc_funcs, prog_args);
        } else {
            // User-defined
            result = runFunction(name, args, env);
        }
    } else {
        const token = advance();
        result = switch (token.kind) {
            .integer => makeInt(std.fmt.parseInt(i64, token.text, 10) catch @panic("bad integer")),
            .string => .{ .str = token.text[1 .. token.text.len - 1] },
            .keyword_true => makeInt(1),
            .keyword_false => makeInt(0),
            .keyword_null => makeInt(0),
            .identifier => env.get(token.text) orelse makeInt(0),
            .l_paren => blk: {
                const v = evalExpr(env);
                consume(.r_paren);
                break :blk v;
            },
            else => makeInt(0),
        };
    }

    // member access: obj.field -> env_find(obj, "field")
    // indexing: xs[i] -> list_get(xs, i)
    while (true) {
        if (peek().kind == .dot) {
            _ = advance(); // '.'
            const field_tok = advance();
            if (field_tok.kind != .identifier) @panic("member access: expected identifier");
            if (builtinEnvFind(result, field_tok.text)) |v| {
                result = v;
            } else {
                result = makeInt(0);
            }
            continue;
        }

        if (peek().kind == .l_bracket) {
            _ = advance(); // '['
            const idx = evalExpr(env);
            consume(.r_bracket);
            result = builtinListGet(result, idx);
            continue;
        }

        break;
    }

    return result;
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
            .greater => {
                _ = advance();
                const lhs = expectInt(result);
                const rhs = expectInt(evalAdd(env));
                result = makeInt(if (lhs > rhs) 1 else 0);
            },
            .greater_equal => {
                _ = advance();
                const lhs = expectInt(result);
                const rhs = expectInt(evalAdd(env));
                result = makeInt(if (lhs >= rhs) 1 else 0);
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
                const rhs = evalCompare(env);
                const eq = switch (result) {
                    .int => |lhs_i| switch (rhs) {
                        .int => |rhs_i| lhs_i == rhs_i,
                        .str => false,
                    },
                    .str => |lhs_s| switch (rhs) {
                        .str => |rhs_s| std.mem.eql(u8, lhs_s, rhs_s),
                        .int => false,
                    },
                };
                result = makeInt(if (eq) 1 else 0);
            },
            .bang_equal => {
                _ = advance();
                const rhs = evalCompare(env);
                const eq = switch (result) {
                    .int => |lhs_i| switch (rhs) {
                        .int => |rhs_i| lhs_i == rhs_i,
                        .str => false,
                    },
                    .str => |lhs_s| switch (rhs) {
                        .str => |rhs_s| std.mem.eql(u8, lhs_s, rhs_s),
                        .int => false,
                    },
                };
                result = makeInt(if (!eq) 1 else 0);
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

                const tmp_args = [_]Value{arg_val};
                const val = runFunction(name, tmp_args[0..], env);
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

fn execBlock(env: *Env) Control {
    consume(.l_brace);
    while (peek().kind != .r_brace and peek().kind != .eof) {
        const ctrl = evalStmt(env);
        switch (ctrl) {
            .none => {},
            else => return ctrl,
        }
    }
    if (peek().kind == .r_brace) consume(.r_brace);
    return .none;
}

fn skipBlock() void {
    consume(.l_brace);
    var depth: usize = 1;
    while (depth > 0 and peek().kind != .eof) {
        const t = advance();
        switch (t.kind) {
            .l_brace => depth += 1,
            .r_brace => depth -= 1,
            else => {},
        }
    }
}

fn evalStmt(env: *Env) Control {
    const t = peek();

    switch (t.kind) {
        .keyword_if => {
            _ = advance(); // 'if'
            const cond = expectInt(evalExpr(env));

            if (peek().kind != .l_brace) @panic("if: expected {");

            if (cond != 0) {
                const ctrl = execBlock(env);
                switch (ctrl) {
                    .none => {},
                    else => return ctrl,
                }

                if (peek().kind == .keyword_else) {
                    _ = advance(); // 'else'
                    if (peek().kind != .l_brace) @panic("else: expected {");
                    skipBlock();
                }
            } else {
                skipBlock();

                if (peek().kind == .keyword_else) {
                    _ = advance(); // 'else'
                    if (peek().kind != .l_brace) @panic("else: expected {");
                    const ctrl = execBlock(env);
                    switch (ctrl) {
                        .none => {},
                        else => return ctrl,
                    }
                }
            }
        },
        .keyword_else => {
            @panic("else without if");
        },
        .keyword_break => {
            _ = advance(); // 'break'
            return .brk;
        },
        .keyword_continue => {
            _ = advance(); // 'continue'
            return .cont;
        },
        .keyword_for => {
            _ = advance(); // 'for'
            const name_tok = advance();
            if (name_tok.kind != .identifier) @panic("for: expected identifier");
            if (peek().kind != .keyword_in) @panic("for: expected in");
            _ = advance(); // 'in'

            var idx = expectInt(evalExpr(env));
            if (peek().kind != .dot_dot) @panic("for: expected ..");
            _ = advance(); // '..'
            const end = expectInt(evalExpr(env));

            const body_start = pos;
            if (peek().kind != .l_brace) @panic("for: expected {");

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
                @panic("for: unterminated block");
            }

            while (idx < end) : (idx += 1) {
                env.set(name_tok.text, makeInt(idx));
                pos = body_start;
                const ctrl = execBlock(env);
                switch (ctrl) {
                    .none => {},
                    .ret => |ret| {
                        pos = body_end;
                        return .{ .ret = ret };
                    },
                    .brk => {
                        pos = body_end;
                        return .none;
                    },
                    .cont => {},
                }
            }

            pos = body_end;
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
                const ctrl = execBlock(env);
                switch (ctrl) {
                    .none => {},
                    .ret => |ret| {
                        pos = body_end;
                        return .{ .ret = ret };
                    },
                    .brk => {
                        pos = body_end;
                        return .none;
                    },
                    .cont => {},
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
                return .{ .ret = makeInt(0) };
            }
            const val = evalExpr(env);
            return .{ .ret = val };
        },
        .identifier => {
            if (pos + 1 < tokens.len and tokens[pos + 1].kind == .l_bracket) {
                var scan_pos: usize = pos + 1;
                var depth: usize = 0;
                while (scan_pos < tokens.len) : (scan_pos += 1) {
                    switch (tokens[scan_pos].kind) {
                        .l_bracket => depth += 1,
                        .r_bracket => {
                            depth -= 1;
                            if (depth == 0) break;
                        },
                        else => {},
                    }
                }

                if (depth == 0 and scan_pos + 1 < tokens.len) {
                    const after_kind = tokens[scan_pos + 1].kind;
                    if (after_kind == .equal or after_kind == .plus_equal) {
                        const name_tok = advance();
                        const list_handle = env.get(name_tok.text) orelse makeInt(0);

                        consume(.l_bracket);
                        const idx_val = evalExpr(env);
                        consume(.r_bracket);

                        const op_kind = advance().kind;
                        const rhs = evalExpr(env);

                        var new_val = rhs;
                        if (op_kind == .plus_equal) {
                            const old = builtinListGet(list_handle, idx_val);
                            const lhs = expectInt(old);
                            const add = expectInt(rhs);
                            new_val = makeInt(lhs + add);
                        }

                        builtinListSet(list_handle, idx_val, new_val);
                        return .none;
                    }
                }
            }

            if (pos + 1 < tokens.len) {
                const next_kind = tokens[pos + 1].kind;
                if (next_kind == .equal or next_kind == .plus_equal) {
                    const name_tok = advance();
                    const op_kind = advance().kind;
                    const rhs = evalExpr(env);

                    var new_val = rhs;
                    if (op_kind == .plus_equal) {
                        const lhs = expectInt(env.get(name_tok.text) orelse makeInt(0));
                        const add = expectInt(rhs);
                        new_val = makeInt(lhs + add);
                    }

                    env.set(name_tok.text, new_val);
                    return .none;
                }
            }

            // Expression statement: evaluate and ignore the result.
            _ = evalExpr(env);
        },
        .eof => {},
        else => {
            // Expression statement: evaluate and ignore the result.
            _ = evalExpr(env);
        },
    }

    return .none;
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
                 \\  vex [--verbose|-v] parse <file.vex> [dump]
                 \\  vex [--verbose|-v] eval <file.vex> [args...]
                 \\  vex [--verbose|-v] bc <file.vex> [args...]
                 \\  vex [--verbose|-v] bcvex <file.vex> [args...]
                 \\  vex [--verbose|-v] bcdump <file.vex>
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
            const tail = host_args[argi..];
            const args_buf = try allocator.alloc([]u8, tail.len + 1);
            args_buf[0] = compiler_script;
            for (tail, 0..) |arg, j| args_buf[j + 1] = arg;

            file_path = compiler_script;
            script_args = args_buf;
        } else if (std.mem.eql(u8, cmd, "parse")) {
            if (host_args.len <= argi + 1) {
                print("error: missing file\n", .{});
                return;
            }

            const compiler_script = try allocator.dupe(u8, "src/compiler_core.vex");
            const tail = host_args[argi..];
            const args_buf = try allocator.alloc([]u8, tail.len + 1);
            args_buf[0] = compiler_script;
            for (tail, 0..) |arg, j| args_buf[j + 1] = arg;

            file_path = compiler_script;
            script_args = args_buf;
        } else if (std.mem.eql(u8, cmd, "eval")) {
            if (host_args.len <= argi + 1) {
                print("error: missing file\n", .{});
                return;
            }

            const compiler_script = try allocator.dupe(u8, "src/compiler_core.vex");
            const tail = host_args[argi..];
            const args_buf = try allocator.alloc([]u8, tail.len + 1);
            args_buf[0] = compiler_script;
            for (tail, 0..) |arg, j| args_buf[j + 1] = arg;

            file_path = compiler_script;
            script_args = args_buf;
        } else if (std.mem.eql(u8, cmd, "bc") or std.mem.eql(u8, cmd, "bcvex") or std.mem.eql(u8, cmd, "bcdump")) {
            if (host_args.len <= argi + 1) {
                print("error: missing file\n", .{});
                return;
            }

            const compiler_script = try allocator.dupe(u8, "src/compiler_core.vex");
            const tail = host_args[argi..];
            const args_buf = try allocator.alloc([]u8, tail.len + 1);
            args_buf[0] = compiler_script;
            for (tail, 0..) |arg, j| args_buf[j + 1] = arg;

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
            '.' => {
                if (i + 1 < source.len and source[i + 1] == '.') {
                    try list.append(.{ .kind = .dot_dot, .text = source[i..i+2], .line = line });
                    i += 2;
                } else {
                    try list.append(.{ .kind = .dot, .text = source[i..i+1], .line = line });
                    i += 1;
                }
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
            '[' => {
                try list.append(.{ .kind = .l_bracket, .text = source[i..i+1], .line = line });
                i += 1;
                continue;
            },
            ']' => {
                try list.append(.{ .kind = .r_bracket, .text = source[i..i+1], .line = line });
                i += 1;
                continue;
            },
            '+' => {
                if (i + 1 < source.len and source[i + 1] == '=') {
                    try list.append(.{ .kind = .plus_equal, .text = source[i..i+2], .line = line });
                    i += 2;
                } else {
                    try list.append(.{ .kind = .plus, .text = source[i..i+1], .line = line });
                    i += 1;
                }
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
            '>' => {
                if (i + 1 < source.len and source[i + 1] == '=') {
                    try list.append(.{ .kind = .greater_equal, .text = source[i..i+2], .line = line });
                    i += 2;
                } else {
                    try list.append(.{ .kind = .greater, .text = source[i..i+1], .line = line });
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
                else if (std.mem.eql(u8, word, "else")) .keyword_else
                else if (std.mem.eql(u8, word, "while")) .keyword_while
                else if (std.mem.eql(u8, word, "and")) .keyword_and
                else if (std.mem.eql(u8, word, "or")) .keyword_or
                else if (std.mem.eql(u8, word, "accel")) .keyword_accel
                else if (std.mem.eql(u8, word, "true")) .keyword_true
                else if (std.mem.eql(u8, word, "false")) .keyword_false
                else if (std.mem.eql(u8, word, "null")) .keyword_null
                else if (std.mem.eql(u8, word, "for")) .keyword_for
                else if (std.mem.eql(u8, word, "in")) .keyword_in
                else if (std.mem.eql(u8, word, "break")) .keyword_break
                else if (std.mem.eql(u8, word, "continue")) .keyword_continue
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
                const ctrl = evalStmt(global_env);
                switch (ctrl) {
                    .none => {},
                    .ret => @panic("return outside function"),
                    .brk => @panic("break outside loop"),
                    .cont => @panic("continue outside loop"),
                }
                if (verbose and peek().kind != .eof) {
                    print("\n", .{});
                }
            },
        }
    }

    if (functions.get("main")) |main_func| {
        _ = main_func; // value unused, we just check existence
        const tmp_args = [_]Value{};
        _ = runFunction("main", tmp_args[0..], global_env);
    }

    if (verbose) {
        print("\n\nVEX JUST RAN YOUR CODE - NO LLVM - NO EXCUSES\n", .{});
        print("THE FINAL LANGUAGE IS ALIVE - RIGHT NOW\n", .{});
    }
}
