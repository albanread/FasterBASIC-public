const std = @import("std");
const builtin = @import("builtin");
const sysc = @cImport({
    @cInclude("sys/wait.h");
});
const backend_config = @import("backend_config.zig");
const jit_shared = @import("jit_shared.zig");
const terminal_mod = @import("ed_terminal.zig");
const basic_frontend = @import("basic_frontend");
const lexer_mod = basic_frontend.lexer;
const parser_mod = basic_frontend.parser;
const semantic_mod = basic_frontend.semantic;
const cfg_mod = basic_frontend.cfg;

const Terminal = terminal_mod.Terminal;
const EXIT_PENDING: i32 = -2147483647;

pub export fn basic_jit_stop() callconv(.c) void {}

pub const RunnerState = enum {
    idle,
    compiling,
    running,
    finished,
};

pub const RunResult = struct {
    completed: bool = false,
    exit_code: i32 = 0,
    was_stopped: bool = false,
    compile_ms: f64 = 0,
    exec_ms: f64 = 0,
    source_lines: usize = 0,
    error_count: u32 = 0,
};

pub const ErrorInfo = struct {
    line: u32 = 0,
    col: u32 = 0,
    is_warning: bool = false,
    message_buf: [256]u8 = [_]u8{0} ** 256,
    message_len: u16 = 0,
};

pub const StdinInput = struct {
    buf: [1024]u8 = [_]u8{0} ** 1024,
    len: usize = 0,

    pub fn clear(self: *StdinInput) void {
        self.len = 0;
    }

    pub fn backspace(self: *StdinInput) bool {
        if (self.len == 0) return false;
        self.len -= 1;
        return true;
    }

    pub fn append(self: *StdinInput, b: u8) bool {
        if (self.len >= self.buf.len) return false;
        self.buf[self.len] = b;
        self.len += 1;
        return true;
    }

    pub fn contents(self: *const StdinInput) []const u8 {
        return self.buf[0..self.len];
    }
};

const TaskKind = enum {
    run,
    build,
    analyse,
    show_asm,
    show_ir,
    show_ast,
    show_cfg,
    show_symbols,
};

const LocalAnalyseOptions = struct {
    print_heading: bool = false,
    print_summary: bool = false,
    print_warnings: bool = false,
};

const LocalAnalyseReport = struct {
    error_count: u32 = 0,
    warning_count: u32 = 0,
    requires_graphics_mode: bool = false,
};

const RunnerFastPathOptions = struct {
    opt_level: u8 = 1,
    fast_math_trig: bool = false,
    supported: bool = true,
};

const SourceAnalysisFingerprint = struct {
    hash: u64 = 0,
    len: usize = 0,
};

pub const JitRunner = struct {
    allocator: std.mem.Allocator,
    terminal: *Terminal,
    backend_kind: backend_config.BackendKind,
    compiler_exe: []u8,
    compiler_options: []u8,
    compiler_config_session_override: bool = false,

    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(RunnerState.idle)),
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    task_thread: ?std.Thread = null,
    result_pending: ?RunResult = null,

    source_buf: ?[]u8 = null,
    build_output_path: ?[]u8 = null,

    shared_mutex: std.Thread.Mutex = .{},
    shared_region: ?jit_shared.SharedRegion = null,
    output_read: u32 = 0,
    error_read: u32 = 0,
    error_infos: std.ArrayListUnmanaged(ErrorInfo) = .{},
    cached_analysis_fingerprint: SourceAnalysisFingerprint = .{},
    cached_analysis_valid: bool = false,
    cached_analysis_report: LocalAnalyseReport = .{},
    cached_analysis_infos: std.ArrayListUnmanaged(ErrorInfo) = .{},

    is_build: bool = false,
    build_outputs_app: bool = false,
    is_analyse: bool = false,
    is_show_asm: bool = false,
    is_show_ir: bool = false,
    stdin_input: StdinInput = .{},

    pub fn init(allocator: std.mem.Allocator, terminal: *Terminal) !JitRunner {
        const resolved = try backend_config.resolve(allocator);
        return .{
            .allocator = allocator,
            .terminal = terminal,
            .backend_kind = resolved.kind,
            .compiler_exe = resolved.compiler_exe,
            .compiler_options = resolved.compiler_options,
        };
    }

    pub fn deinit(self: *JitRunner) void {
        self.requestStop();
        self.waitForTask();
        self.freePendingBuffers();
        self.error_infos.deinit(self.allocator);
        self.cached_analysis_infos.deinit(self.allocator);
        self.allocator.free(self.compiler_exe);
        self.allocator.free(self.compiler_options);
    }

    pub fn getCompilerExe(self: *const JitRunner) []const u8 {
        return self.compiler_exe;
    }

    pub fn getCompilerBackendKind(self: *const JitRunner) backend_config.BackendKind {
        return self.backend_kind;
    }

    pub fn getCompilerOptions(self: *const JitRunner) []const u8 {
        return self.compiler_options;
    }

    pub fn setCompilerBackend(self: *JitRunner, compiler_exe: []const u8, compiler_options: []const u8) !void {
        const next_exe = try dupTrimmedRequired(self.allocator, compiler_exe);
        errdefer self.allocator.free(next_exe);
        const next_options = try dupTrimmedOptional(self.allocator, compiler_options);
        errdefer self.allocator.free(next_options);

        self.allocator.free(self.compiler_exe);
        self.allocator.free(self.compiler_options);
        self.compiler_exe = next_exe;
        self.compiler_options = next_options;
        self.compiler_config_session_override = true;
    }

    pub fn persistCompilerConfig(self: *JitRunner) !void {
        try backend_config.persistCurrent(self.allocator, self.backend_kind, self.compiler_exe, self.compiler_options);
        self.compiler_config_session_override = false;
    }

    pub fn clearCompilerConfigOverride(self: *JitRunner) !void {
        try backend_config.clearPersistedConfig(self.allocator);
        try self.reloadCompilerBackend();
    }

    pub fn reloadCompilerBackend(self: *JitRunner) !void {
        const resolved = try backend_config.resolve(self.allocator);

        self.allocator.free(self.compiler_exe);
        self.allocator.free(self.compiler_options);
        self.backend_kind = resolved.kind;
        self.compiler_exe = resolved.compiler_exe;
        self.compiler_options = resolved.compiler_options;
        self.compiler_config_session_override = false;
    }

    pub fn getState(self: *const JitRunner) RunnerState {
        return @enumFromInt(self.state.load(.acquire));
    }

    pub fn isActive(self: *const JitRunner) bool {
        return switch (self.getState()) {
            .compiling, .running => true,
            .idle, .finished => false,
        };
    }

    pub fn isRunning(self: *const JitRunner) bool {
        return self.getState() == .running;
    }

    pub fn collectResult(self: *JitRunner) ?RunResult {
        if (self.getState() != .finished) return null;
        if (self.result_pending) |r| {
            self.result_pending = null;
            self.state.store(@intFromEnum(RunnerState.idle), .release);
            return r;
        }
        self.state.store(@intFromEnum(RunnerState.idle), .release);
        return null;
    }

    pub fn getErrorInfos(self: *const JitRunner) []const ErrorInfo {
        return self.error_infos.items;
    }

    pub fn requestStop(self: *JitRunner) void {
        self.stop_requested.store(true, .release);

        self.shared_mutex.lock();
        defer self.shared_mutex.unlock();

        if (self.shared_region) |*region| {
            @atomicStore(u32, &region.header.stop_requested, 1, .release);
        }
    }

    pub fn flushStdinLine(self: *JitRunner) bool {
        const bytes = self.stdin_input.contents();
        const ok = self.writeStdin(bytes);
        self.stdin_input.clear();
        if (ok) {
            return self.writeStdinByte('\n');
        }
        return false;
    }

    pub fn writeStdinByte(self: *JitRunner, byte: u8) bool {
        var one = [_]u8{byte};
        return self.writeStdin(one[0..]);
    }

    pub fn startRun(self: *JitRunner, source_utf8: []const u8) bool {
        return self.startTask(.run, source_utf8, null);
    }

    pub fn startBuild(self: *JitRunner, source_utf8: []const u8, output_path: []const u8) bool {
        return self.startTask(.build, source_utf8, output_path);
    }

    pub fn sourceRequiresGraphicsMode(self: *JitRunner, source_utf8: []const u8) bool {
        if (self.cached_analysis_valid and analysisFingerprintMatches(self.cached_analysis_fingerprint, source_utf8)) {
            return self.cached_analysis_report.requires_graphics_mode;
        }

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const report = self.performLocalAnalysis(source_utf8, arena_state.allocator(), .{});
        return report.requires_graphics_mode;
    }

    pub fn startAnalyse(self: *JitRunner, source_utf8: []const u8) bool {
        return self.startTask(.analyse, source_utf8, null);
    }

    pub fn startShowAsm(self: *JitRunner, source_utf8: []const u8) bool {
        return self.startTask(.show_asm, source_utf8, null);
    }

    pub fn startShowIR(self: *JitRunner, source_utf8: []const u8) bool {
        return self.startTask(.show_ir, source_utf8, null);
    }

    pub fn startShowAST(self: *JitRunner, source_utf8: []const u8) bool {
        return self.startTask(.show_ast, source_utf8, null);
    }

    pub fn startShowCFG(self: *JitRunner, source_utf8: []const u8) bool {
        return self.startTask(.show_cfg, source_utf8, null);
    }

    pub fn startShowSymbols(self: *JitRunner, source_utf8: []const u8) bool {
        return self.startTask(.show_symbols, source_utf8, null);
    }

    fn startTask(self: *JitRunner, kind: TaskKind, source_utf8: []const u8, output_path: ?[]const u8) bool {
        if (self.isActive()) return false;

        self.waitForTask();
        _ = self.collectResult();

        self.freePendingBuffers();

        self.stop_requested.store(false, .release);
        self.result_pending = null;
        self.output_read = 0;
        self.error_read = 0;
        self.stdin_input.clear();
        self.error_infos.clearRetainingCapacity();

        self.is_build = (kind == .build);
        self.build_outputs_app = (kind == .build) and builtin.os.tag == .macos and self.sourceRequiresGraphicsMode(source_utf8);
        self.is_analyse = (kind == .analyse);
        self.is_show_asm = (kind == .show_asm);
        self.is_show_ir = (kind == .show_ir);

        if (kind == .run and self.finishRunFromCachedAnalysis(source_utf8)) {
            self.state.store(@intFromEnum(RunnerState.finished), .release);
            return true;
        }

        self.source_buf = self.allocator.dupe(u8, source_utf8) catch return false;
        if (output_path) |path| {
            self.build_output_path = self.allocator.dupe(u8, path) catch {
                self.freePendingBuffers();
                return false;
            };
        }

        self.state.store(@intFromEnum(RunnerState.compiling), .release);

        self.task_thread = std.Thread.spawn(.{}, taskMain, .{ self, kind }) catch {
            self.state.store(@intFromEnum(RunnerState.idle), .release);
            self.freePendingBuffers();
            return false;
        };
        return true;
    }

    fn taskMain(self: *JitRunner, kind: TaskKind) void {
        defer self.state.store(@intFromEnum(RunnerState.finished), .release);

        const started_ns = std.time.nanoTimestamp();

        switch (kind) {
            .run, .build, .show_asm, .show_ir => self.runThroughEdglue(kind, started_ns),
            .analyse => self.runLocalAnalyse(started_ns),
            .show_ast => self.runLocalShowAST(started_ns),
            .show_cfg => self.runLocalShowCFG(started_ns),
            .show_symbols => self.runLocalShowSymbols(started_ns),
        }
    }

    fn runLocalAnalyse(self: *JitRunner, started_ns: i128) void {
        const source = self.source_buf orelse {
            self.finishWithResult(.{ .completed = false, .exit_code = 1, .error_count = 1 });
            return;
        };

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const report = self.performLocalAnalysis(source, arena_state.allocator(), .{
            .print_heading = true,
            .print_summary = true,
            .print_warnings = true,
        });

        const elapsed_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - started_ns)) / 1_000_000.0;
        self.finishWithResult(.{
            .completed = (report.error_count == 0),
            .exit_code = if (report.error_count == 0) 0 else 1,
            .was_stopped = false,
            .compile_ms = elapsed_ms,
            .exec_ms = 0,
            .source_lines = countLines(source),
            .error_count = report.error_count,
        });
    }

    fn performLocalAnalysis(self: *JitRunner, source: []const u8, arena: std.mem.Allocator, options: LocalAnalyseOptions) LocalAnalyseReport {
        if (self.cached_analysis_valid and analysisFingerprintMatches(self.cached_analysis_fingerprint, source)) {
            if (options.print_heading) {
                self.terminal.ringWrite("[analyse] cached local frontend (lexer/parser/semantic)\r\n");
            }
            self.replayCachedAnalysis(options);
            return self.cached_analysis_report;
        }

        if (options.print_heading) {
            self.terminal.ringWrite("[analyse] local frontend (lexer/parser/semantic)\r\n");
        }

        var report: LocalAnalyseReport = .{};
        var diagnostics: std.ArrayListUnmanaged(ErrorInfo) = .{};
        defer diagnostics.deinit(self.allocator);

        var lexer = lexer_mod.Lexer.init(source, arena);
        defer lexer.deinit();

        var lexer_failed = false;
        lexer.tokenize() catch {
            lexer_failed = true;
        };
        if (lexer_failed and lexer.errors.items.len == 0) {
            report.error_count += 1;
            appendDiagnosticTo(self.allocator, &diagnostics, 1, 1, false, "lexer failed unexpectedly");
        }

        for (lexer.errors.items) |e| {
            report.error_count += 1;
            appendDiagnosticTo(self.allocator, &diagnostics, e.location.line, e.location.column, false, e.message);
        }

        var parser = parser_mod.Parser.init(lexer.tokens.items, arena);
        defer parser.deinit();

        var parser_failed = false;
        const parsed = parser.parse() catch blk: {
            parser_failed = true;
            break :blk null;
        };
        if (parser_failed and parser.errors.items.len == 0) {
            report.error_count += 1;
            appendDiagnosticTo(self.allocator, &diagnostics, 1, 1, false, "parser failed unexpectedly");
        }

        for (parser.errors.items) |e| {
            report.error_count += 1;
            appendDiagnosticTo(self.allocator, &diagnostics, e.location.line, e.location.column, false, e.message);
        }

        if (parsed) |program| {
            var sema = semantic_mod.SemanticAnalyzer.init(arena);
            defer sema.deinit();

            var semantic_aborted = false;
            const sem_ok = sema.analyze(&program) catch blk: {
                semantic_aborted = true;
                break :blk false;
            };

            for (sema.errors.items) |e| {
                report.error_count += 1;
                appendDiagnosticTo(self.allocator, &diagnostics, e.location.line, e.location.column, false, e.message);
            }

            if (semantic_aborted and sema.errors.items.len == 0) {
                report.error_count += 1;
                appendDiagnosticTo(self.allocator, &diagnostics, 1, 1, false, "semantic analysis aborted");
            } else if (!sem_ok and sema.errors.items.len == 0) {
                report.error_count += 1;
                appendDiagnosticTo(self.allocator, &diagnostics, 1, 1, false, "semantic analysis failed");
            }

            report.requires_graphics_mode = sema.getSymbolTable().requires_graphics_mode;
            report.warning_count = @as(u32, @intCast(sema.warnings.items.len));
            for (sema.warnings.items) |w| {
                appendDiagnosticTo(self.allocator, &diagnostics, w.location.line, w.location.column, true, w.message);
            }
        }

        self.storeCachedAnalysis(source, report, diagnostics.items);
        self.replayCachedAnalysis(options);

        return report;
    }

    fn storeCachedAnalysis(self: *JitRunner, source: []const u8, report: LocalAnalyseReport, diagnostics: []const ErrorInfo) void {
        self.cached_analysis_infos.clearRetainingCapacity();
        self.cached_analysis_infos.appendSlice(self.allocator, diagnostics) catch {
            self.cached_analysis_infos.clearRetainingCapacity();
            self.cached_analysis_valid = false;
            return;
        };
        self.cached_analysis_fingerprint = fingerprintSource(source);
        self.cached_analysis_report = report;
        self.cached_analysis_valid = true;
    }

    fn replayCachedAnalysis(self: *JitRunner, options: LocalAnalyseOptions) void {
        for (self.cached_analysis_infos.items) |info| {
            if (info.is_warning and !options.print_warnings) continue;
            self.error_infos.append(self.allocator, info) catch {};
            self.printDiagnostic(info.is_warning, info.line, info.col, info.message_buf[0..info.message_len]);
        }

        if (options.print_summary) {
            var summary_buf: [192]u8 = undefined;
            const summary = std.fmt.bufPrint(&summary_buf, "[analyse] {d} error(s), {d} warning(s)\r\n", .{ self.cached_analysis_report.error_count, self.cached_analysis_report.warning_count }) catch "[analyse] done\r\n";
            self.terminal.ringWrite(summary);
        }
    }

    fn finishRunFromCachedAnalysis(self: *JitRunner, source: []const u8) bool {
        if (!self.cached_analysis_valid) return false;
        if (!analysisFingerprintMatches(self.cached_analysis_fingerprint, source)) return false;
        if (self.cached_analysis_report.error_count == 0) return false;

        self.terminal.ringWrite("[run] skipped: current buffer has cached analysis errors\r\n");
        self.replayCachedAnalysis(.{
            .print_heading = false,
            .print_summary = true,
            .print_warnings = true,
        });
        self.finishWithResult(.{
            .completed = false,
            .exit_code = 1,
            .was_stopped = false,
            .compile_ms = 0,
            .exec_ms = 0,
            .source_lines = countLines(source),
            .error_count = self.cached_analysis_report.error_count,
        });
        return true;
    }

    fn runLocalShowAST(self: *JitRunner, started_ns: i128) void {
        const source = self.source_buf orelse {
            self.finishWithResult(.{ .completed = false, .exit_code = 1, .error_count = 1 });
            return;
        };

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var lexer = lexer_mod.Lexer.init(source, arena);
        defer lexer.deinit();
        lexer.tokenize() catch {};

        var parser = parser_mod.Parser.init(lexer.tokens.items, arena);
        defer parser.deinit();

        const parsed = parser.parse() catch null;
        if (parsed == null or lexer.errors.items.len > 0 or parser.errors.items.len > 0) {
            self.runLocalAnalyse(started_ns);
            return;
        }

        const program = parsed.?;
        var header: [128]u8 = undefined;
        const hdr = std.fmt.bufPrint(&header, "=== AST ({d} lines, {d} tokens) ===\r\n", .{ program.lines.len, lexer.tokens.items.len }) catch "=== AST ===\r\n";
        self.terminal.ringWrite(hdr);

        for (program.lines, 0..) |line, i| {
            var line_buf: [384]u8 = undefined;
            const text = std.fmt.bufPrint(&line_buf, "Line[{d}] basic_line={d} loc={d}:{d} statements={d}\r\n", .{ i, line.line_number, line.loc.line, line.loc.column, line.statements.len }) catch continue;
            self.terminal.ringWrite(text);

            const src_line = sourceLineSlice(source, line.loc.line);
            if (src_line.len > 0) {
                var src_buf: [320]u8 = undefined;
                const quoted = std.fmt.bufPrint(&src_buf, "    src: {s}\r\n", .{src_line}) catch "";
                if (quoted.len > 0) self.terminal.ringWrite(quoted);
            }

            for (line.statements, 0..) |stmt, si| {
                var stmt_buf: [220]u8 = undefined;
                const s = std.fmt.bufPrint(&stmt_buf, "  - [{d}] {s} @ {d}:{d}\r\n", .{ si, @tagName(stmt.data), stmt.loc.line, stmt.loc.column }) catch continue;
                self.terminal.ringWrite(s);
            }
        }
        self.terminal.ringWrite("=== End AST ===\r\n");

        const elapsed_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - started_ns)) / 1_000_000.0;
        self.finishWithResult(.{
            .completed = true,
            .exit_code = 0,
            .compile_ms = elapsed_ms,
            .source_lines = countLines(source),
            .error_count = 0,
        });
    }

    fn runLocalShowCFG(self: *JitRunner, started_ns: i128) void {
        const source = self.source_buf orelse {
            self.finishWithResult(.{ .completed = false, .exit_code = 1, .error_count = 1 });
            return;
        };

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var lexer = lexer_mod.Lexer.init(source, arena);
        defer lexer.deinit();
        lexer.tokenize() catch {};

        var parser = parser_mod.Parser.init(lexer.tokens.items, arena);
        defer parser.deinit();

        const parsed = parser.parse() catch null;
        if (parsed == null or lexer.errors.items.len > 0 or parser.errors.items.len > 0) {
            self.runLocalAnalyse(started_ns);
            return;
        }

        var sema = semantic_mod.SemanticAnalyzer.init(arena);
        defer sema.deinit();
        _ = sema.analyze(&parsed.?) catch {};
        if (sema.hasErrors()) {
            self.runLocalAnalyse(started_ns);
            return;
        }

        var builder = cfg_mod.CFGBuilder.init(arena);
        defer builder.deinit();
        const cfg = builder.buildFromProgram(&parsed.?) catch {
            self.terminal.ringWrite("[cfg] failed to build CFG\r\n");
            self.finishWithResult(.{ .completed = false, .exit_code = 1, .error_count = 1 });
            return;
        };

        var head: [160]u8 = undefined;
        const h = std.fmt.bufPrint(&head, "=== CFG: {s} ({d} blocks, {d} edges) ===\r\n", .{ cfg.function_name, cfg.numBlocks(), cfg.numEdges() }) catch "=== CFG ===\r\n";
        self.terminal.ringWrite(h);

        for (cfg.blocks.items) |*blk| {
            var bb: [220]u8 = undefined;
            const t = std.fmt.bufPrint(&bb, "  block #{d} {s} kind={s} stmts={d} succ={d}\r\n", .{ blk.index, blk.name, @tagName(blk.kind), blk.statements.items.len, blk.successors.items.len }) catch continue;
            self.terminal.ringWrite(t);
        }
        self.terminal.ringWrite("=== End CFG ===\r\n");

        const elapsed_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - started_ns)) / 1_000_000.0;
        self.finishWithResult(.{
            .completed = true,
            .exit_code = 0,
            .compile_ms = elapsed_ms,
            .source_lines = countLines(source),
            .error_count = 0,
        });
    }

    fn runLocalShowSymbols(self: *JitRunner, started_ns: i128) void {
        const source = self.source_buf orelse {
            self.finishWithResult(.{ .completed = false, .exit_code = 1, .error_count = 1 });
            return;
        };

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var lexer = lexer_mod.Lexer.init(source, arena);
        defer lexer.deinit();
        lexer.tokenize() catch {};

        var parser = parser_mod.Parser.init(lexer.tokens.items, arena);
        defer parser.deinit();

        const parsed = parser.parse() catch null;
        if (parsed == null or lexer.errors.items.len > 0 or parser.errors.items.len > 0) {
            self.runLocalAnalyse(started_ns);
            return;
        }

        var sema = semantic_mod.SemanticAnalyzer.init(arena);
        defer sema.deinit();
        _ = sema.analyze(&parsed.?) catch {};

        for (sema.errors.items) |e| {
            self.appendDiagnostic(e.location.line, e.location.column, false, e.message);
        }
        for (sema.warnings.items) |w| {
            self.appendDiagnostic(w.location.line, w.location.column, true, w.message);
        }

        const st = sema.getSymbolTable();
        self.terminal.ringWrite("=== Symbol Table ===\r\n");
        var counts: [256]u8 = undefined;
        const c = std.fmt.bufPrint(&counts, "functions={d}, vars={d}, arrays={d}, types={d}, classes={d}, labels={d}, constants={d}\r\n", .{ st.functions.count(), st.variables.count(), st.arrays.count(), st.types.count(), st.classes.count(), st.labels.count(), st.constants.count() }) catch "(counts unavailable)\r\n";
        self.terminal.ringWrite(c);

        self.terminal.ringWrite("\r\n[functions]\r\n");
        {
            var it = st.functions.iterator();
            while (it.next()) |entry| {
                const f = entry.value_ptr.*;
                var b: [320]u8 = undefined;
                const rt = if (f.return_type_name.len > 0) f.return_type_name else @tagName(f.return_type_desc.base_type);
                const msg = std.fmt.bufPrint(&b, "  {s} params={d} return={s} worker={s} loc={d}:{d}\r\n", .{ entry.key_ptr.*, f.parameters.len, rt, if (f.is_worker) "yes" else "no", f.definition.line, f.definition.column }) catch continue;
                self.terminal.ringWrite(msg);
            }
        }

        self.terminal.ringWrite("\r\n[variables]\r\n");
        {
            var it = st.variables.iterator();
            while (it.next()) |entry| {
                const v = entry.value_ptr.*;
                var b: [320]u8 = undefined;
                const tn = if (v.type_name.len > 0) v.type_name else @tagName(v.type_desc.base_type);
                const msg = std.fmt.bufPrint(&b, "  {s} type={s} scope={s} declared={s} used={s}\r\n", .{ entry.key_ptr.*, tn, @tagName(v.scope.kind), if (v.is_declared) "yes" else "no", if (v.is_used) "yes" else "no" }) catch continue;
                self.terminal.ringWrite(msg);
            }
        }

        self.terminal.ringWrite("\r\n[arrays]\r\n");
        {
            var it = st.arrays.iterator();
            while (it.next()) |entry| {
                const a = entry.value_ptr.*;
                var b: [320]u8 = undefined;
                const et = if (a.as_type_name.len > 0) a.as_type_name else @tagName(a.element_type_desc.base_type);
                const msg = std.fmt.bufPrint(&b, "  {s} elem={s} dims={d} total={d}\r\n", .{ entry.key_ptr.*, et, a.num_dimensions, a.total_size }) catch continue;
                self.terminal.ringWrite(msg);
            }
        }

        self.terminal.ringWrite("\r\n[types]\r\n");
        {
            var it = st.types.iterator();
            while (it.next()) |entry| {
                const t = entry.value_ptr.*;
                var b: [320]u8 = undefined;
                const msg = std.fmt.bufPrint(&b, "  {s} fields={d} declared={s}\r\n", .{ entry.key_ptr.*, t.fields.len, if (t.is_declared) "yes" else "no" }) catch continue;
                self.terminal.ringWrite(msg);
            }
        }

        self.terminal.ringWrite("\r\n[classes]\r\n");
        {
            var it = st.classes.iterator();
            while (it.next()) |entry| {
                const cls = entry.value_ptr.*;
                var b: [384]u8 = undefined;
                const parent = if (cls.parent_class_name.len > 0) cls.parent_class_name else "<none>";
                const msg = std.fmt.bufPrint(&b, "  {s} parent={s} fields={d} methods={d} object_size={d}\r\n", .{ entry.key_ptr.*, parent, cls.fields.len, cls.methods.len, cls.object_size }) catch continue;
                self.terminal.ringWrite(msg);
            }
        }

        self.terminal.ringWrite("\r\n[constants]\r\n");
        {
            var it = st.constants.iterator();
            while (it.next()) |entry| {
                const k = entry.value_ptr.*;
                var b: [320]u8 = undefined;
                const kind = @tagName(k.kind);
                const msg = switch (k.kind) {
                    .integer_const => std.fmt.bufPrint(&b, "  {s} kind={s} value={d}\r\n", .{ entry.key_ptr.*, kind, k.int_value }) catch continue,
                    .double_const => std.fmt.bufPrint(&b, "  {s} kind={s} value={d}\r\n", .{ entry.key_ptr.*, kind, k.double_value }) catch continue,
                    .string_const => std.fmt.bufPrint(&b, "  {s} kind={s} value=\"{s}\"\r\n", .{ entry.key_ptr.*, kind, k.string_value }) catch continue,
                };
                self.terminal.ringWrite(msg);
            }
        }

        self.terminal.ringWrite("\r\n[labels]\r\n");
        {
            var it = st.labels.iterator();
            while (it.next()) |entry| {
                const l = entry.value_ptr.*;
                var b: [320]u8 = undefined;
                const msg = std.fmt.bufPrint(&b, "  {s} id={d} line_index={d} loc={d}:{d}\r\n", .{ entry.key_ptr.*, l.label_id, l.program_line_index, l.definition.line, l.definition.column }) catch continue;
                self.terminal.ringWrite(msg);
            }
        }

        self.terminal.ringWrite("\r\n[line numbers]\r\n");
        {
            var it = st.line_numbers.iterator();
            while (it.next()) |entry| {
                const ln = entry.value_ptr.*;
                var b: [220]u8 = undefined;
                const msg = std.fmt.bufPrint(&b, "  {d} -> line_index={d}\r\n", .{ ln.line_number, ln.program_line_index }) catch continue;
                self.terminal.ringWrite(msg);
            }
        }

        if (sema.warnings.items.len > 0) {
            self.terminal.ringWrite("warnings:\r\n");
            for (sema.warnings.items) |w| {
                self.printDiagnostic(true, w.location.line, w.location.column, w.message);
            }
        }
        if (sema.errors.items.len > 0) {
            self.terminal.ringWrite("errors:\r\n");
            for (sema.errors.items) |e| {
                self.printDiagnostic(false, e.location.line, e.location.column, e.message);
            }
        }
        self.terminal.ringWrite("=== End Symbol Table ===\r\n");

        const elapsed_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - started_ns)) / 1_000_000.0;
        self.finishWithResult(.{
            .completed = (sema.errors.items.len == 0),
            .exit_code = if (sema.errors.items.len == 0) 0 else 1,
            .compile_ms = elapsed_ms,
            .source_lines = countLines(source),
            .error_count = @as(u32, @intCast(sema.errors.items.len)),
        });
    }

    fn runThroughEdglue(self: *JitRunner, kind: TaskKind, started_ns: i128) void {
        const source = self.source_buf orelse {
            self.finishWithResult(.{ .completed = false, .exit_code = 1 });
            return;
        };

        var analysis_arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer analysis_arena_state.deinit();
        const analysis = self.performLocalAnalysis(source, analysis_arena_state.allocator(), .{});
        if (analysis.error_count != 0) {
            var msg_buf: [192]u8 = undefined;
            const action = compilerLaunchActionText(kind);
            const msg = std.fmt.bufPrint(&msg_buf, "[{s}] local analysis failed; compiler not launched ({d} error(s))\r\n", .{ action, analysis.error_count }) catch "[run] local analysis failed; compiler not launched\r\n";
            self.terminal.ringWrite(msg);

            const elapsed_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - started_ns)) / 1_000_000.0;
            self.finishWithResult(.{
                .completed = false,
                .exit_code = 1,
                .was_stopped = false,
                .compile_ms = elapsed_ms,
                .exec_ms = 0,
                .source_lines = countLines(source),
                .error_count = analysis.error_count,
            });
            return;
        }

        if (kind == .run) {
            const runner_options = parseRunnerFastPathOptions(self.compiler_options);
            if (shouldUseRunnerFastPath(self, analysis, runner_options)) {
                self.runThroughRunner(started_ns, source, runner_options);
                return;
            }
        }

        if (source.len == 0 or source.len > jit_shared.SOURCE_CAPACITY) {
            self.terminal.ringWrite("[run] source too large for shared memory\r\n");
            self.finishWithResult(.{ .completed = false, .exit_code = 2, .error_count = 1 });
            return;
        }

        var shm_buf: [128]u8 = [_]u8{0} ** 128;
        const pid = std.c.getpid();
        const nonce = @as(u64, @intCast(std.time.nanoTimestamp()));
        const shm_name = std.fmt.bufPrint(shm_buf[0 .. shm_buf.len - 1], "/edjit-{d}-{x}", .{ pid, nonce }) catch {
            self.finishWithResult(.{ .completed = false, .exit_code = 1 });
            return;
        };
        shm_buf[shm_name.len] = 0;
        const shm_name_z: [:0]const u8 = shm_buf[0..shm_name.len :0];

        var region = jit_shared.create(shm_name_z) catch {
            self.terminal.ringWrite("[run] failed to create shared region\r\n");
            self.finishWithResult(.{ .completed = false, .exit_code = 1 });
            return;
        };
        defer {
            self.shared_mutex.lock();
            self.shared_region = null;
            self.shared_mutex.unlock();
            jit_shared.close(&region);
            jit_shared.unlink(&region);
        }

        self.shared_mutex.lock();
        self.shared_region = region;
        self.shared_mutex.unlock();

        @memcpy(region.source[0..source.len], source);
        @atomicStore(u32, &region.header.source_len, @as(u32, @intCast(source.len)), .release);
        @atomicStore(u32, &region.header.stop_requested, if (self.stop_requested.load(.acquire)) 1 else 0, .release);
        @atomicStore(i32, &region.header.exit_code, EXIT_PENDING, .release);
        @atomicStore(u64, &region.header.compile_ns, 0, .release);
        @atomicStore(u64, &region.header.exec_ns, 0, .release);

        const glue_path = self.resolveEdgluePath() catch {
            self.terminal.ringWrite("[run] edglue executable not found\r\n");
            self.finishWithResult(.{ .completed = false, .exit_code = 127 });
            return;
        };
        defer self.allocator.free(glue_path);

        var argv: std.ArrayListUnmanaged([]const u8) = .{};
        defer argv.deinit(self.allocator);

        argv.append(self.allocator, glue_path) catch {
            self.finishWithResult(.{ .completed = false, .exit_code = 1 });
            return;
        };
        argv.append(self.allocator, shm_name) catch {
            self.finishWithResult(.{ .completed = false, .exit_code = 1 });
            return;
        };
        argv.append(self.allocator, "--backend") catch {
            self.finishWithResult(.{ .completed = false, .exit_code = 1 });
            return;
        };
        argv.append(self.allocator, self.backend_kind.text()) catch {
            self.finishWithResult(.{ .completed = false, .exit_code = 1 });
            return;
        };

        if (self.compiler_config_session_override) {
            argv.append(self.allocator, "--compiler") catch {
                self.finishWithResult(.{ .completed = false, .exit_code = 1 });
                return;
            };
            argv.append(self.allocator, self.compiler_exe) catch {
                self.finishWithResult(.{ .completed = false, .exit_code = 1 });
                return;
            };
        }

        if (self.compiler_config_session_override and self.compiler_options.len != 0) {
            argv.append(self.allocator, "--compiler-options") catch {
                self.finishWithResult(.{ .completed = false, .exit_code = 1 });
                return;
            };
            argv.append(self.allocator, self.compiler_options) catch {
                self.finishWithResult(.{ .completed = false, .exit_code = 1 });
                return;
            };
        }

        if (kind == .build) {
            const out_path = self.build_output_path orelse "program";
            argv.append(self.allocator, "--build") catch {
                self.finishWithResult(.{ .completed = false, .exit_code = 1 });
                return;
            };
            argv.append(self.allocator, out_path) catch {
                self.finishWithResult(.{ .completed = false, .exit_code = 1 });
                return;
            };
            if (builtin.os.tag == .macos and analysis.requires_graphics_mode) {
                argv.append(self.allocator, "--bundle-app") catch {
                    self.finishWithResult(.{ .completed = false, .exit_code = 1 });
                    return;
                };
            }
        } else if (kind == .show_asm) {
            argv.append(self.allocator, "--show-asm") catch {
                self.finishWithResult(.{ .completed = false, .exit_code = 1 });
                return;
            };
        } else if (kind == .show_ir) {
            argv.append(self.allocator, "--show-ir") catch {
                self.finishWithResult(.{ .completed = false, .exit_code = 1 });
                return;
            };
        }

        var child = std.process.Child.init(argv.items, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        child.spawn() catch {
            self.terminal.ringWrite("[run] failed to launch edglue\r\n");
            self.finishWithResult(.{ .completed = false, .exit_code = 127 });
            return;
        };

        self.state.store(@intFromEnum(RunnerState.running), .release);

        var stopped = false;
        var wait_status: c_int = 0;
        var exit_code: ?i32 = null;
        var stop_requested_at_ns: ?i128 = null;

        while (exit_code == null) {
            self.drainSharedOutput(&region);

            if (self.stop_requested.load(.acquire)) {
                @atomicStore(u32, &region.header.stop_requested, 1, .release);
                if (!stopped) {
                    stopped = true;
                    stop_requested_at_ns = std.time.nanoTimestamp();
                    _ = child.kill() catch null;
                } else if (stop_requested_at_ns) |stop_started_ns| {
                    if (std.time.nanoTimestamp() - stop_started_ns >= 1_500 * std.time.ns_per_ms) {
                        _ = child.kill() catch null;
                        stop_requested_at_ns = null;
                    }
                }
            }

            const wait_result = sysc.waitpid(@as(c_int, @intCast(child.id)), &wait_status, sysc.WNOHANG);
            if (wait_result < 0) {
                self.finishWithResult(.{ .completed = false, .exit_code = 127 });
                return;
            }
            if (wait_result == @as(c_int, @intCast(child.id))) {
                exit_code = waitStatusToExitCode(wait_status);
                break;
            }

            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        const child_exit = exit_code orelse 127;

        self.drainSharedOutput(&region);

        const shared_exit = @atomicLoad(i32, &region.header.exit_code, .acquire);
        const shared_compile_ns = @atomicLoad(u64, &region.header.compile_ns, .acquire);
        const shared_exec_ns = @atomicLoad(u64, &region.header.exec_ns, .acquire);
        const final_code = if (shared_exit != EXIT_PENDING) shared_exit else child_exit;

        const elapsed_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - started_ns)) / 1_000_000.0;
        const compile_ms = if (shared_compile_ns != 0)
            @as(f64, @floatFromInt(shared_compile_ns)) / 1_000_000.0
        else
            elapsed_ms;
        const exec_ms = @as(f64, @floatFromInt(shared_exec_ns)) / 1_000_000.0;
        self.finishWithResult(.{
            .completed = (!stopped and final_code == 0),
            .exit_code = final_code,
            .was_stopped = stopped,
            .compile_ms = compile_ms,
            .exec_ms = exec_ms,
            .source_lines = countLines(source),
            .error_count = if (final_code == 0) 0 else 1,
        });
    }

    fn finishUnsupported(self: *JitRunner, kind: TaskKind, started_ns: i128) void {
        const msg = switch (kind) {
            .analyse => "[analyse] not yet wired through edglue\r\n",
            .show_asm => "[show asm] not available in editor-only mode\r\n",
            .show_ir => "[show ir] not available in editor-only mode\r\n",
            .show_ast => "[show ast] not available in editor-only mode\r\n",
            .show_cfg => "[show cfg] not available in editor-only mode\r\n",
            .show_symbols => "[show symbols] not available in editor-only mode\r\n",
            else => "[run] unsupported task\r\n",
        };
        self.terminal.ringWrite(msg);

        const elapsed_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - started_ns)) / 1_000_000.0;
        self.finishWithResult(.{
            .completed = false,
            .exit_code = 1,
            .compile_ms = elapsed_ms,
            .error_count = 1,
        });
    }

    fn finishWithResult(self: *JitRunner, result: RunResult) void {
        self.result_pending = result;
    }

    fn appendDiagnostic(self: *JitRunner, line: u32, col: u32, is_warning: bool, message: []const u8) void {
        appendDiagnosticTo(self.allocator, &self.error_infos, line, col, is_warning, message);
    }

    fn printDiagnostic(self: *JitRunner, is_warning: bool, line: u32, col: u32, message: []const u8) void {
        var buf: [512]u8 = undefined;
        const kind = if (is_warning) "warning" else "error";
        const text = std.fmt.bufPrint(&buf, "[{s}] L{d}:{d} {s}\r\n", .{ kind, line, col, message }) catch return;
        self.terminal.ringWrite(text);
    }

    fn resolveEdgluePath(self: *JitRunner) ![]u8 {
        const exe_path = try std.fs.selfExePathAlloc(self.allocator);
        defer self.allocator.free(exe_path);

        const exe_dir = std.fs.path.dirname(exe_path) orelse return error.NoExeDir;
        const candidate = try std.fs.path.join(self.allocator, &.{ exe_dir, "edglue" });
        errdefer self.allocator.free(candidate);

        if (fileExists(candidate)) return candidate;

        self.allocator.free(candidate);
        const repo_candidate = try self.allocator.dupe(u8, "zig-out/bin/edglue");
        if (fileExists(repo_candidate)) return repo_candidate;
        self.allocator.free(repo_candidate);

        return error.FileNotFound;
    }

    fn runThroughRunner(self: *JitRunner, started_ns: i128, source: []const u8, options: RunnerFastPathOptions) void {
        if (source.len == 0 or source.len > jit_shared.SOURCE_CAPACITY) {
            self.terminal.ringWrite("[run] source too large for shared memory\r\n");
            self.finishWithResult(.{ .completed = false, .exit_code = 2, .error_count = 1 });
            return;
        }

        self.terminal.ringWrite("[run] using basic-runner execution path\r\n");

        var shm_buf: [128]u8 = [_]u8{0} ** 128;
        const pid = std.c.getpid();
        const nonce = @as(u64, @intCast(std.time.nanoTimestamp()));
        const shm_name = std.fmt.bufPrint(shm_buf[0 .. shm_buf.len - 1], "/edjr-{d}-{x}", .{ pid, nonce }) catch {
            self.finishWithResult(.{ .completed = false, .exit_code = 1 });
            return;
        };
        shm_buf[shm_name.len] = 0;
        const shm_name_z: [:0]const u8 = shm_buf[0..shm_name.len :0];

        var region = jit_shared.create(shm_name_z) catch {
            self.terminal.ringWrite("[run] failed to create shared region\r\n");
            self.finishWithResult(.{ .completed = false, .exit_code = 1 });
            return;
        };
        defer {
            self.shared_mutex.lock();
            self.shared_region = null;
            self.shared_mutex.unlock();
            jit_shared.close(&region);
            jit_shared.unlink(&region);
        }

        self.shared_mutex.lock();
        self.shared_region = region;
        self.shared_mutex.unlock();

        @memcpy(region.source[0..source.len], source);
        @atomicStore(u32, &region.header.source_len, @as(u32, @intCast(source.len)), .release);
        @atomicStore(u32, &region.header.stop_requested, if (self.stop_requested.load(.acquire)) 1 else 0, .release);
        @atomicStore(i32, &region.header.exit_code, EXIT_PENDING, .release);
        @atomicStore(u64, &region.header.compile_ns, 0, .release);
        @atomicStore(u64, &region.header.exec_ns, 0, .release);

        const runner_path = self.resolveRunnerPath() catch {
            self.terminal.ringWrite("[run] basic-runner executable not found\r\n");
            self.finishWithResult(.{ .completed = false, .exit_code = 127 });
            return;
        };
        defer self.allocator.free(runner_path);

        var argv: std.ArrayListUnmanaged([]const u8) = .{};
        defer argv.deinit(self.allocator);

        argv.append(self.allocator, runner_path) catch {
            self.finishWithResult(.{ .completed = false, .exit_code = 1 });
            return;
        };
        argv.append(self.allocator, "--jit-shared") catch {
            self.finishWithResult(.{ .completed = false, .exit_code = 1 });
            return;
        };
        argv.append(self.allocator, shm_name) catch {
            self.finishWithResult(.{ .completed = false, .exit_code = 1 });
            return;
        };
        argv.append(self.allocator, "--opt-level") catch {
            self.finishWithResult(.{ .completed = false, .exit_code = 1 });
            return;
        };

        var opt_level_buf: [4]u8 = undefined;
        const opt_level_text = std.fmt.bufPrint(&opt_level_buf, "{d}", .{options.opt_level}) catch {
            self.finishWithResult(.{ .completed = false, .exit_code = 1 });
            return;
        };
        argv.append(self.allocator, opt_level_text) catch {
            self.finishWithResult(.{ .completed = false, .exit_code = 1 });
            return;
        };

        if (options.fast_math_trig) {
            argv.append(self.allocator, "--fast-math-trig") catch {
                self.finishWithResult(.{ .completed = false, .exit_code = 1 });
                return;
            };
        }

        var child = std.process.Child.init(argv.items, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        child.spawn() catch {
            self.terminal.ringWrite("[run] failed to launch basic-runner\r\n");
            self.finishWithResult(.{ .completed = false, .exit_code = 127 });
            return;
        };

        self.state.store(@intFromEnum(RunnerState.running), .release);

        var stopped = false;
        if (self.stop_requested.load(.acquire)) {
            _ = child.kill() catch null;
            stopped = true;
        }

        const term = child.wait() catch {
            self.finishWithResult(.{ .completed = false, .exit_code = 127 });
            return;
        };
        const child_exit = termToExitCode(term);

        self.drainSharedOutput(&region);

        const shared_exit = @atomicLoad(i32, &region.header.exit_code, .acquire);
        const shared_compile_ns = @atomicLoad(u64, &region.header.compile_ns, .acquire);
        const shared_exec_ns = @atomicLoad(u64, &region.header.exec_ns, .acquire);
        const final_code = if (shared_exit != EXIT_PENDING) shared_exit else child_exit;

        const elapsed_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - started_ns)) / 1_000_000.0;
        const compile_ms = if (shared_compile_ns != 0)
            @as(f64, @floatFromInt(shared_compile_ns)) / 1_000_000.0
        else
            elapsed_ms;
        const exec_ms = @as(f64, @floatFromInt(shared_exec_ns)) / 1_000_000.0;
        self.finishWithResult(.{
            .completed = (!stopped and final_code == 0),
            .exit_code = final_code,
            .was_stopped = stopped,
            .compile_ms = compile_ms,
            .exec_ms = exec_ms,
            .source_lines = countLines(source),
            .error_count = if (final_code == 0) 0 else 1,
        });
    }

    fn resolveRunnerPath(self: *JitRunner) ![]u8 {
        const exe_path = try std.fs.selfExePathAlloc(self.allocator);
        defer self.allocator.free(exe_path);

        const exe_dir = std.fs.path.dirname(exe_path) orelse return error.NoExeDir;
        const sibling_candidate = try std.fs.path.join(self.allocator, &.{ exe_dir, "basic-runner" });
        errdefer self.allocator.free(sibling_candidate);
        if (fileExists(sibling_candidate)) return sibling_candidate;
        self.allocator.free(sibling_candidate);

        const repo_candidate = try self.allocator.dupe(u8, "../runner/zig-out/bin/basic-runner");
        if (fileExists(repo_candidate)) return repo_candidate;
        self.allocator.free(repo_candidate);

        const abs_candidate = try self.allocator.dupe(u8, "/Volumes/xc/March2026/runner/zig-out/bin/basic-runner");
        if (fileExists(abs_candidate)) return abs_candidate;
        self.allocator.free(abs_candidate);

        return error.FileNotFound;
    }

    fn dupTrimmedRequired(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidCompilerPath;
        return allocator.dupe(u8, trimmed);
    }

    fn dupTrimmedOptional(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        return allocator.dupe(u8, trimmed);
    }

    fn dupTrimmedOptionalOrNull(allocator: std.mem.Allocator, raw: []const u8) ?[]u8 {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return null;
        return allocator.dupe(u8, trimmed) catch null;
    }

    fn drainSharedOutput(self: *JitRunner, region: *jit_shared.SharedRegion) void {
        var tmp: std.ArrayListUnmanaged(u8) = .{};
        defer tmp.deinit(self.allocator);

        const out_w = @atomicLoad(u32, &region.header.output_write, .acquire);
        jit_shared.ringRead(region.output, &self.output_read, out_w, &tmp, self.allocator) catch {};
        if (tmp.items.len != 0) {
            self.terminal.ringWrite(tmp.items);
        }

        tmp.clearRetainingCapacity();
        const err_w = @atomicLoad(u32, &region.header.error_write, .acquire);
        jit_shared.ringRead(region.err, &self.error_read, err_w, &tmp, self.allocator) catch {};
        if (tmp.items.len != 0) {
            self.terminal.ringWrite(tmp.items);
        }
    }

    fn writeStdin(self: *JitRunner, bytes: []const u8) bool {
        self.shared_mutex.lock();
        defer self.shared_mutex.unlock();

        if (self.shared_region) |*region| {
            jit_shared.ringWrite(region.input, &region.header.input_write, bytes);
            return true;
        }
        return false;
    }

    fn waitForTask(self: *JitRunner) void {
        if (self.task_thread) |t| {
            t.join();
            self.task_thread = null;
        }
    }

    fn freePendingBuffers(self: *JitRunner) void {
        if (self.source_buf) |buf| {
            self.allocator.free(buf);
            self.source_buf = null;
        }
        if (self.build_output_path) |buf| {
            self.allocator.free(buf);
            self.build_output_path = null;
        }
    }
};

fn appendDiagnosticTo(allocator: std.mem.Allocator, infos: *std.ArrayListUnmanaged(ErrorInfo), line: u32, col: u32, is_warning: bool, message: []const u8) void {
    var info: ErrorInfo = .{};
    info.line = if (line == 0) 1 else line;
    info.col = if (col == 0) 1 else col;
    info.is_warning = is_warning;

    const n: usize = @min(message.len, info.message_buf.len - 1);
    @memcpy(info.message_buf[0..n], message[0..n]);
    info.message_len = @intCast(n);

    infos.append(allocator, info) catch {};
}

fn fingerprintSource(source: []const u8) SourceAnalysisFingerprint {
    return .{
        .hash = std.hash.Wyhash.hash(0, source),
        .len = source.len,
    };
}

fn analysisFingerprintMatches(fingerprint: SourceAnalysisFingerprint, source: []const u8) bool {
    return fingerprint.len == source.len and fingerprint.hash == std.hash.Wyhash.hash(0, source);
}

fn termToExitCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .Exited => |code| @as(i32, @intCast(code)),
        .Signal => |sig| -@as(i32, @intCast(sig)),
        else => 1,
    };
}

fn waitStatusToExitCode(status: c_int) i32 {
    if (sysc.WIFEXITED(status)) {
        return @as(i32, sysc.WEXITSTATUS(status));
    }
    if (sysc.WIFSIGNALED(status)) {
        return -@as(i32, sysc.WTERMSIG(status));
    }
    return 1;
}

fn compilerLaunchActionText(kind: TaskKind) []const u8 {
    return switch (kind) {
        .run => "run",
        .build => "build",
        .show_asm => "show asm",
        .show_ir => "show ir",
        .analyse => "analyse",
        .show_ast => "show ast",
        .show_cfg => "show cfg",
        .show_symbols => "show symbols",
    };
}

fn parseRunnerFastPathOptions(raw_options: []const u8) RunnerFastPathOptions {
    var options: RunnerFastPathOptions = .{};
    var it = std.mem.tokenizeAny(u8, raw_options, " \t\r\n");
    while (it.next()) |token| {
        if (std.mem.eql(u8, token, "-O0")) {
            options.opt_level = 0;
        } else if (std.mem.eql(u8, token, "-O1")) {
            options.opt_level = 1;
        } else if (std.mem.eql(u8, token, "-O2")) {
            options.opt_level = 2;
        } else if (std.mem.eql(u8, token, "-O3")) {
            options.opt_level = 3;
        } else if (std.mem.eql(u8, token, "--fast-math-trig")) {
            options.fast_math_trig = true;
        } else {
            options.supported = false;
            return options;
        }
    }
    return options;
}

fn shouldUseRunnerFastPath(self: *const JitRunner, analysis: LocalAnalyseReport, options: RunnerFastPathOptions) bool {
    if (analysis.error_count != 0) return false;
    if (!options.supported) return false;
    if (self.backend_kind != .fbzig) return false;
    return true;
}

fn fileExists(path: []const u8) bool {
    _ = std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn countLines(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var lines: usize = 1;
    for (bytes) |b| {
        if (b == '\n') lines += 1;
    }
    return lines;
}

fn sourceLineSlice(source: []const u8, one_based_line: u32) []const u8 {
    if (one_based_line == 0) return "";

    var current: u32 = 1;
    var start: usize = 0;
    var i: usize = 0;

    while (i < source.len) : (i += 1) {
        if (current == one_based_line and source[i] == '\n') {
            return std.mem.trimRight(u8, source[start..i], "\r\n");
        }
        if (source[i] == '\n') {
            current += 1;
            start = i + 1;
        }
    }

    if (current == one_based_line and start <= source.len) {
        return std.mem.trimRight(u8, source[start..], "\r\n");
    }
    return "";
}
