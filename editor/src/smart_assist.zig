const std = @import("std");
const build_options = @import("build_options");

/// Compile-time flag exported from build.zig.
pub const llama_enabled = build_options.enable_smart_assist;

/// Default model path baked in at build time (override with SmartAssistConfig.model_path).
pub const default_model_path: []const u8 = build_options.smart_assist_model_path;

pub const SmartAssistError = error{
    FeatureDisabled,
    ModelNotLoaded,
    RequestOverflow,
    Cancelled,
    DecodeFailed,
    TokenizationFailed,
} || std.mem.Allocator.Error || std.Thread.SpawnError;

pub const FimFormat = struct {
    prefix_token: []const u8 = "<|fim_prefix|>",
    suffix_token: []const u8 = "<|fim_suffix|>",
    middle_token: []const u8 = "<|fim_middle|>",
};

pub const InferenceRequest = struct {
    prefix: []const u8,
    suffix: []const u8,
    max_tokens: usize = 64,
};

pub const PendingRequest = struct {
    prefix: []u8,
    suffix: []u8,
    max_tokens: usize,
};

pub const TokenQueue = struct {
    mutex: std.Thread.Mutex = .{},
    items: std.ArrayListUnmanaged([]u8) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TokenQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TokenQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |token| {
            self.allocator.free(token);
        }
        self.items.deinit(self.allocator);
    }

    pub fn push(self: *TokenQueue, token: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const copy = try self.allocator.dupe(u8, token);
        try self.items.append(self.allocator, copy);
    }

    pub fn drain(self: *TokenQueue, out: *std.ArrayList([]u8)) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |token| {
            try out.append(self.allocator, token);
        }
        self.items.clearRetainingCapacity();
    }

    pub fn clear(self: *TokenQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |token| {
            self.allocator.free(token);
        }
        self.items.clearRetainingCapacity();
    }
};

const llama = if (llama_enabled) @cImport({
    @cInclude("llama.h");
}) else struct {};

pub const CoderModel = if (llama_enabled) struct {
    model: *llama.llama_model,
    ctx: *llama.llama_context,

    pub fn load(allocator: std.mem.Allocator, model_path: [:0]const u8, n_ctx: u32) !*CoderModel {
        llama.llama_backend_init();

        var model_params = llama.llama_model_default_params();
        model_params.n_gpu_layers = 99;

        const model = llama.llama_load_model_from_file(model_path, model_params) orelse
            return error.ModelLoadFailed;

        var ctx_params = llama.llama_context_default_params();
        ctx_params.n_ctx = n_ctx;
        ctx_params.abort_callback = abortShim;
        ctx_params.abort_callback_data = null;

        const ctx = llama.llama_new_context_with_model(model, ctx_params) orelse {
            llama.llama_free_model(model);
            return error.ContextInitFailed;
        };

        const self = try allocator.create(CoderModel);
        self.* = .{ .model = model, .ctx = ctx };
        return self;
    }

    pub fn deinit(self: *CoderModel, allocator: std.mem.Allocator) void {
        llama.llama_free(self.ctx);
        llama.llama_free_model(self.model);
        allocator.destroy(self);
    }

    fn abortShim(_: ?*anyopaque) callconv(.c) bool {
        // The owning SmartAssist struct overrides this via ctx_params.abort_callback_data;
        // leave default false here so contexts constructed without that data do not abort.
        return false;
    }
} else struct {
    pub fn load(_: std.mem.Allocator, _: [:0]const u8, _: i32) SmartAssistError!*CoderModel {
        return error.FeatureDisabled;
    }
    pub fn deinit(_: *CoderModel, _: std.mem.Allocator) void {}
};

pub const SmartAssistConfig = struct {
    allocator: std.mem.Allocator,
    model_path: [:0]const u8,
    n_ctx: u32 = 2048,
    fim_format: FimFormat = .{},
    max_prefix_bytes: usize = 1000,
    max_suffix_bytes: usize = 500,
    enabled: bool = false, // runtime opt-in (default off)
};

pub const SmartAssist = struct {
    allocator: std.mem.Allocator,
    model: ?*CoderModel = null,
    worker: ?std.Thread = null,
    cond: std.Thread.Condition = .{},
    mutex: std.Thread.Mutex = .{},
    pending: ?PendingRequest = null,
    tokens: TokenQueue,
    shutting_down: bool = false,
    abort_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cfg: SmartAssistConfig,

    pub fn init(cfg: SmartAssistConfig) !*SmartAssist {
        if (!llama_enabled) {
            std.log.warn("SmartAssist: init skipped (llama disabled at build)", .{});
            return error.FeatureDisabled;
        }
        if (!cfg.enabled) {
            std.log.warn("SmartAssist: init skipped (runtime disabled)", .{});
            return error.FeatureDisabled;
        }

        const self = try cfg.allocator.create(SmartAssist);
        errdefer cfg.allocator.destroy(self);
        self.* = .{
            .allocator = cfg.allocator,
            .model = null,
            .worker = null,
            .cond = .{},
            .mutex = .{},
            .pending = null,
            .tokens = TokenQueue.init(cfg.allocator),
            .shutting_down = false,
            .abort_flag = std.atomic.Value(bool).init(false),
            .cfg = cfg,
        };

        self.model = CoderModel.load(cfg.allocator, cfg.model_path, cfg.n_ctx) catch |e| {
            std.log.warn("SmartAssist: model load failed: {}", .{e});
            return e;
        };
        errdefer if (self.model) |m| m.deinit(cfg.allocator);

        self.worker = try std.Thread.spawn(.{}, workerMain, .{self});
        std.log.info("SmartAssist: initialized (model={s}, n_ctx={d})", .{ cfg.model_path, cfg.n_ctx });
        return self;
    }

    pub fn deinit(self: *SmartAssist) void {
        self.mutex.lock();
        self.shutting_down = true;
        self.cond.signal();
        self.mutex.unlock();

        if (self.worker) |t| t.join();

        if (self.model) |m| m.deinit(self.allocator);
        self.tokens.deinit();
        self.allocator.destroy(self);
    }

    pub fn submit(self: *SmartAssist, req: InferenceRequest) SmartAssistError!void {
        if (!llama_enabled) return error.FeatureDisabled;
        if (!self.cfg.enabled) return error.FeatureDisabled;

        std.log.info("SmartAssist: submit (prefix={d}B suffix={d}B max_tokens={d})", .{
            req.prefix.len,
            req.suffix.len,
            req.max_tokens,
        });

        const prefix = try trimAndCopy(self.allocator, req.prefix, self.cfg.max_prefix_bytes);
        errdefer self.allocator.free(prefix);
        const suffix = try trimAndCopy(self.allocator, req.suffix, self.cfg.max_suffix_bytes);
        errdefer self.allocator.free(suffix);

        self.abort_flag.store(false, .monotonic);

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shutting_down) return error.Cancelled;

        if (self.pending) |old| {
            self.allocator.free(old.prefix);
            self.allocator.free(old.suffix);
        }

        self.pending = PendingRequest{
            .prefix = prefix,
            .suffix = suffix,
            .max_tokens = req.max_tokens,
        };
        self.cond.signal();
    }

    pub fn cancel(self: *SmartAssist) void {
        self.abort_flag.store(true, .monotonic);
    }

    pub fn drainTokens(self: *SmartAssist, out: *std.ArrayList([]u8)) !void {
        try self.tokens.drain(out);
    }

    fn workerMain(self: *SmartAssist) void {
        if (!llama_enabled) return;
        while (true) {
            var job: ?PendingRequest = null;
            self.mutex.lock();
            while (!self.shutting_down and self.pending == null) {
                self.cond.wait(&self.mutex);
            }
            if (self.shutting_down) {
                self.mutex.unlock();
                break;
            }
            job = self.pending;
            self.pending = null;
            self.mutex.unlock();

            if (job) |req| {
                self.runInference(req) catch {};
                self.allocator.free(req.prefix);
                self.allocator.free(req.suffix);
            }
        }
    }

    fn runInference(self: *SmartAssist, req: PendingRequest) !void {
        if (!llama_enabled) return error.FeatureDisabled;
        const model = self.model orelse return error.ModelNotLoaded;

        std.log.info("SmartAssist: inference start (prefix={d}B suffix={d}B max_tokens={d})", .{
            req.prefix.len,
            req.suffix.len,
            req.max_tokens,
        });

        // Attach abort callback so llama_decode respects cancel requests.
        llama.llama_set_abort_callback(model.ctx, abortThunk, self);

        // Clear any previous KV cache so each request is independent.
        if (@hasDecl(llama, "llama_kv_cache_clear")) {
            llama.llama_kv_cache_clear(model.ctx);
        }

        // Build FIM prompt.
        const prompt = try buildFimPrompt(self.allocator, self.cfg.fim_format, req.prefix, req.suffix);
        defer self.allocator.free(prompt);

        // Tokenize prompt.
        const vocab = llama.llama_model_get_vocab(model.model) orelse return error.ModelNotLoaded;
        const prompt_tokens = try tokenizeAll(self.allocator, vocab, prompt);
        defer self.allocator.free(prompt_tokens);
        if (prompt_tokens.len == 0) return error.TokenizationFailed;

        // Prime context with the prompt tokens.
        var batch = llama.llama_batch_init(@intCast(prompt_tokens.len), 0, 1);
        defer llama.llama_batch_free(batch);

        var seq_id: llama.llama_seq_id = 0;
        var pos: llama.llama_pos = 0;
        batch.n_tokens = @intCast(prompt_tokens.len);
        var i: usize = 0;
        while (i < prompt_tokens.len) : (i += 1) {
            batch.token[i] = prompt_tokens[i];
            batch.pos[i] = pos;
            batch.n_seq_id[i] = 1;
            batch.seq_id[i] = &seq_id;
            batch.logits[i] = 0; // only last token needs logits
            pos += 1;
        }
        if (batch.n_tokens > 0) batch.logits[@intCast(batch.n_tokens - 1)] = 1;

        const prime_rc = llama.llama_decode(model.ctx, batch);
        if (prime_rc != 0) return error.DecodeFailed;

        // Greedy generate tokens, streaming to TokenQueue.
        var remaining: usize = req.max_tokens;
        var next_pos: llama.llama_pos = pos;
        const n_vocab: usize = @intCast(llama.llama_vocab_n_tokens(vocab));
        var emitted: usize = 0;

        while (remaining > 0 and !self.abort_flag.load(.monotonic)) {
            const logits = llama.llama_get_logits_ith(model.ctx, -1) orelse break;
            const tok = greedySelect(logits, n_vocab);
            if (llama.llama_vocab_is_eog(vocab, tok)) break;

            // Stream piece to UI queue.
            const piece = try tokenToOwned(self.allocator, vocab, tok);
            defer self.allocator.free(piece);
            try self.tokens.push(piece);
            emitted += 1;

            // Append token into context for next step.
            var step_batch = llama.llama_batch_init(1, 0, 1);
            defer llama.llama_batch_free(step_batch);
            step_batch.n_tokens = 1;
            step_batch.token[0] = tok;
            step_batch.pos[0] = next_pos;
            step_batch.n_seq_id[0] = 1;
            step_batch.seq_id[0] = &seq_id;
            step_batch.logits[0] = 1;

            const rc = llama.llama_decode(model.ctx, step_batch);
            if (rc != 0) {
                if (self.abort_flag.load(.monotonic)) break;
                return error.DecodeFailed;
            }

            remaining -= 1;
            next_pos += 1;
        }

        if (self.abort_flag.load(.monotonic)) return error.Cancelled;
        std.log.info("SmartAssist: inference done (emitted={d} remaining={d})", .{ emitted, remaining });
    }
};

fn trimAndCopy(allocator: std.mem.Allocator, input: []const u8, limit: usize) ![]u8 {
    if (input.len == 0) return allocator.dupe(u8, input);
    const start = if (input.len > limit) input.len - limit else 0;
    return allocator.dupe(u8, input[start..]);
}

fn buildFimPrompt(allocator: std.mem.Allocator, fmt: FimFormat, prefix: []const u8, suffix: []const u8) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, fmt.prefix_token);
    try buf.appendSlice(allocator, prefix);
    try buf.appendSlice(allocator, fmt.suffix_token);
    try buf.appendSlice(allocator, suffix);
    try buf.appendSlice(allocator, fmt.middle_token);
    return buf.toOwnedSlice(allocator);
}

fn tokenizeAll(allocator: std.mem.Allocator, vocab: *const llama.llama_vocab, text: []const u8) ![]llama.llama_token {
    const first = llama.llama_tokenize(vocab, text.ptr, @intCast(text.len), null, 0, true, true);
    if (first == std.math.minInt(i32)) return error.RequestOverflow;
    const need_count: usize = @intCast(if (first < 0) -first else first);
    const tokens = try allocator.alloc(llama.llama_token, need_count);
    errdefer allocator.free(tokens);
    const written = llama.llama_tokenize(vocab, text.ptr, @intCast(text.len), tokens.ptr, @intCast(need_count), true, true);
    if (written < 0) return error.TokenizationFailed;
    return tokens;
}

fn greedySelect(logits: [*]const f32, n_vocab: usize) llama.llama_token {
    if (n_vocab == 0) return 0;
    var best_id: usize = 0;
    var best_logit: f32 = logits[0];
    var idx: usize = 1;
    while (idx < n_vocab) : (idx += 1) {
        const v = logits[idx];
        if (v > best_logit) {
            best_logit = v;
            best_id = idx;
        }
    }
    return @intCast(best_id);
}

fn tokenToOwned(allocator: std.mem.Allocator, vocab: *const llama.llama_vocab, token: llama.llama_token) ![]u8 {
    var scratch: [256]u8 = undefined;
    const len = llama.llama_token_to_piece(vocab, token, &scratch, @intCast(scratch.len), 0, true);
    if (len == std.math.minInt(i32)) return error.RequestOverflow;
    if (len <= scratch.len) {
        return allocator.dupe(u8, scratch[0..@intCast(len)]);
    }
    const buf = try allocator.alloc(u8, @intCast(len));
    const len2 = llama.llama_token_to_piece(vocab, token, buf.ptr, @intCast(len), 0, true);
    if (len2 < 0) {
        allocator.free(buf);
        return error.TokenizationFailed;
    }
    return buf;
}

fn abortThunk(user: ?*anyopaque) callconv(.c) bool {
    if (user == null) return false;
    const self: *SmartAssist = @ptrCast(@alignCast(user.?));
    return self.abort_flag.load(.monotonic);
}
