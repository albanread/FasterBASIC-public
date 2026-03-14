// ─── Sprite System — GPU-Driven Sprite Bank ─────────────────────────────────
//
// This module implements the CPU-side management for the GPU-driven sprite
// system.  All per-pixel rendering happens on the GPU via the sprite_render
// Metal compute kernel.  The CPU's responsibilities are:
//
//   • Manage sprite definitions (atlas allocation, palette slots)
//   • Manage sprite instances (position, rotation, scale, effects)
//   • Advance animation accumulators each frame
//   • Sort instances by priority and sync to the GPU instance buffer
//   • Provide bounding-box collision detection
//
// Thread safety: same model as pixel buffers — the JIT thread writes
// instance fields, then calls updateAndSync() during VSYNC.  The main
// thread reads GPU buffers only during drawInMTKView: which runs after
// the JIT thread is blocked.

const std = @import("std");
const gfx = @import("ed_graphics.zig");
const RGBA32 = gfx.RGBA32;

// ─── Constants ──────────────────────────────────────────────────────────────

pub const MAX_DEFINITIONS: u16 = 1024;
pub const MAX_INSTANCES: u16 = 512;
pub const MAX_SPRITE_SIZE: u16 = 256;
pub const MAX_PALETTES: u16 = 1024;
pub const SPRITE_PALETTE_ENTRIES: u8 = 16;
pub const ATLAS_SIZE: u16 = 2048;

// ─── GPU Struct Mirrors ─────────────────────────────────────────────────────
//
// These extern structs match the Metal shader layout byte-for-byte.
// They are written into MTLStorageModeShared buffers.

pub const SpriteAtlasEntryGPU = extern struct {
    atlas_x: u32 = 0,
    atlas_y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    frame_count: u32 = 1,
    frame_w: u32 = 0,
    frame_h: u32 = 0,
    palette_offset: u32 = 0,
};

pub const SpriteInstanceGPU = extern struct {
    // Transform (28 bytes)
    x: f32 = 0,
    y: f32 = 0,
    rotation: f32 = 0,
    scale_x: f32 = 1.0,
    scale_y: f32 = 1.0,
    anchor_x: f32 = 0.5,
    anchor_y: f32 = 0.5,

    // Source (8 bytes)
    atlas_entry_id: u32 = 0,
    frame: u32 = 0,

    // Flags + rendering (12 bytes)
    flags: u32 = 0,
    priority: u32 = 128,
    alpha: f32 = 1.0,

    // Effects (16 bytes)
    effect_type: u32 = 0,
    effect_param1: f32 = 0,
    effect_param2: f32 = 0,
    effect_colour: [4]u8 = .{ 255, 255, 255, 255 },

    // Palette + collision (8 bytes)
    palette_override: u32 = 0,
    collision_group: u32 = 0,

    // Padding to 80 bytes
    _pad: [2]u32 = .{ 0, 0 },
};

pub const SpriteUniformsGPU = extern struct {
    num_instances: u32 = 0,
    atlas_width: u32 = ATLAS_SIZE,
    atlas_height: u32 = ATLAS_SIZE,
    output_width: u32 = 0,
    output_height: u32 = 0,
    frame_counter: u32 = 0,
    _pad: [2]u32 = .{ 0, 0 },
};

// Compile-time size checks
comptime {
    if (@sizeOf(SpriteAtlasEntryGPU) != 32) @compileError("SpriteAtlasEntryGPU must be 32 bytes");
    if (@sizeOf(SpriteInstanceGPU) != 80) @compileError("SpriteInstanceGPU must be 80 bytes");
    if (@sizeOf(SpriteUniformsGPU) != 32) @compileError("SpriteUniformsGPU must be 32 bytes");
}

// ─── Flag Bits ──────────────────────────────────────────────────────────────

pub const SPRITE_FLAG_VISIBLE: u32 = 1 << 0;
pub const SPRITE_FLAG_FLIP_H: u32 = 1 << 1;
pub const SPRITE_FLAG_FLIP_V: u32 = 1 << 2;
pub const SPRITE_FLAG_ADDITIVE: u32 = 1 << 3;

// ─── Effect Types ───────────────────────────────────────────────────────────

pub const EffectType = enum(u8) {
    none = 0,
    glow = 1,
    outline = 2,
    shadow = 3,
    tint = 4,
    flash = 5,
    dissolve = 6,
};

// ─── CPU-Side Sprite Definition ─────────────────────────────────────────────
//
// Bookkeeping only — no pixel data stored on the CPU.  Pixels live in the
// GPU atlas texture (R8Uint, Private storage).

pub const SpriteDefinition = struct {
    width: u16 = 0,
    height: u16 = 0,
    frame_count: u16 = 1,
    frame_w: u16 = 0,
    frame_h: u16 = 0,
    atlas_entry_index: u16 = 0,
    palette_index: u16 = 0,
    active: bool = false,
};

// ─── CPU-Side Sprite Instance ───────────────────────────────────────────────
//
// Mirrors the GPU descriptor with additional CPU-only fields (animation
// accumulator, active flag, def_id for lookup).

pub const SpriteInstance = struct {
    // Transform
    x: f32 = 0,
    y: f32 = 0,
    rotation: f32 = 0,
    scale_x: f32 = 1.0,
    scale_y: f32 = 1.0,
    anchor_x: f32 = 0.5,
    anchor_y: f32 = 0.5,

    // Source
    def_id: u16 = 0,
    frame: u16 = 0,

    // Flags
    visible: bool = false,
    active: bool = false,
    flip_h: bool = false,
    flip_v: bool = false,
    additive: bool = false,

    // Rendering
    priority: u32 = 128,
    alpha: f32 = 1.0,

    // Effects
    effect_type: EffectType = .none,
    effect_param1: f32 = 0,
    effect_param2: f32 = 0,
    effect_colour: RGBA32 = RGBA32.WHITE,

    // Palette
    palette_override: u16 = 0,

    // Collision
    collision_group: u8 = 0,

    // Animation (CPU-only)
    anim_speed: f32 = 0,
    anim_accumulator: f32 = 0,

    /// Pack CPU instance state into a GPU descriptor.
    pub fn toGPU(self: *const SpriteInstance, def: *const SpriteDefinition) SpriteInstanceGPU {
        var gpu: SpriteInstanceGPU = .{};

        gpu.x = self.x;
        gpu.y = self.y;
        gpu.rotation = self.rotation;
        gpu.scale_x = self.scale_x;
        gpu.scale_y = self.scale_y;
        gpu.anchor_x = self.anchor_x;
        gpu.anchor_y = self.anchor_y;

        gpu.atlas_entry_id = def.atlas_entry_index;
        gpu.frame = self.frame;

        var flags: u32 = 0;
        if (self.visible) flags |= SPRITE_FLAG_VISIBLE;
        if (self.flip_h) flags |= SPRITE_FLAG_FLIP_H;
        if (self.flip_v) flags |= SPRITE_FLAG_FLIP_V;
        if (self.additive) flags |= SPRITE_FLAG_ADDITIVE;
        gpu.flags = flags;

        gpu.priority = self.priority;
        gpu.alpha = self.alpha;

        gpu.effect_type = @intFromEnum(self.effect_type);
        gpu.effect_param1 = self.effect_param1;
        gpu.effect_param2 = self.effect_param2;
        gpu.effect_colour = .{ self.effect_colour.r, self.effect_colour.g, self.effect_colour.b, self.effect_colour.a };

        gpu.palette_override = self.palette_override;
        gpu.collision_group = self.collision_group;

        return gpu;
    }
};

// ─── Atlas Shelf Packer ─────────────────────────────────────────────────────
//
// Simple shelf-based rectangle packer for the 2048×2048 atlas texture.
// Allocates rectangles left-to-right within horizontal shelves.  When the
// current shelf doesn't have enough horizontal space, a new shelf is
// started below the current one with height equal to the tallest sprite
// in the shelf.

pub const AtlasRect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
};

pub const ShelfPacker = struct {
    atlas_w: u16 = ATLAS_SIZE,
    atlas_h: u16 = ATLAS_SIZE,
    shelf_y: u16 = 0,
    shelf_h: u16 = 0,
    cursor_x: u16 = 0,

    /// Try to allocate a rectangle of size (w, h) in the atlas.
    /// Returns the top-left corner, or null if the atlas is full.
    pub fn alloc(self: *ShelfPacker, w: u16, h: u16) ?AtlasRect {
        if (w == 0 or h == 0) return null;
        if (w > self.atlas_w or h > self.atlas_h) return null;

        // Try to fit in current shelf
        if (self.cursor_x + w <= self.atlas_w and self.shelf_y + h <= self.atlas_h) {
            const rect = AtlasRect{
                .x = self.cursor_x,
                .y = self.shelf_y,
                .w = w,
                .h = h,
            };
            self.cursor_x += w;
            if (h > self.shelf_h) self.shelf_h = h;
            return rect;
        }

        // Start a new shelf
        const new_y = self.shelf_y + self.shelf_h;
        if (new_y + h > self.atlas_h) return null; // Atlas full vertically
        if (w > self.atlas_w) return null;

        self.shelf_y = new_y;
        self.shelf_h = h;
        self.cursor_x = w;

        return AtlasRect{
            .x = 0,
            .y = new_y,
            .w = w,
            .h = h,
        };
    }

    /// Reset the packer (e.g. when all definitions are cleared).
    pub fn reset(self: *ShelfPacker) void {
        self.shelf_y = 0;
        self.shelf_h = 0;
        self.cursor_x = 0;
    }
};

// ─── Sprite Upload Payload ──────────────────────────────────────────────────
//
// Sent via the GfxCommandRing to trigger a blit from the staging buffer
// into the atlas texture on the GPU.

pub const SpriteUploadPayload = extern struct {
    atlas_x: u16,
    atlas_y: u16,
    width: u16,
    height: u16,
    /// Pointer to a malloc'd pixel snapshot, captured on the JIT thread
    /// the moment SPRITE END is called.  Cast to u64 for ABI portability.
    /// The main-thread drain owns it and must free() it after the blit.
    pixel_ptr: u64 = 0,
};

// ─── Sprite Bank ────────────────────────────────────────────────────────────
//
// Central manager for all sprite definitions and instances.
// Embedded in GraphicsState.

pub const SpriteBank = struct {
    definitions: [MAX_DEFINITIONS]SpriteDefinition = [_]SpriteDefinition{.{}} ** MAX_DEFINITIONS,
    instances: [MAX_INSTANCES]SpriteInstance = [_]SpriteInstance{.{}} ** MAX_INSTANCES,

    // Atlas packer
    packer: ShelfPacker = .{},
    next_palette_slot: u16 = 0,

    // GPU buffer pointers (set by ObjC bridge via gfx_set_sprite_buffers)
    gpu_atlas_entries: ?[*]SpriteAtlasEntryGPU = null,
    gpu_instances: ?[*]SpriteInstanceGPU = null,
    gpu_palettes: ?[*][16]RGBA32 = null,
    gpu_uniforms: ?*SpriteUniformsGPU = null,

    // Staging buffer pointer (set by ObjC bridge)
    // Used to stage pixel data before GPU blit to atlas
    staging_buffer: ?[*]u8 = null,
    staging_buffer_size: u32 = 0,

    // Sorted instance indices for GPU sync
    sorted_indices: [MAX_INSTANCES]u16 = blk: {
        var arr: [MAX_INSTANCES]u16 = undefined;
        for (0..MAX_INSTANCES) |i| {
            arr[i] = @intCast(i);
        }
        break :blk arr;
    },

    // ─── Definition Management ──────────────────────────────────────

    /// Load a sprite definition from raw pixel data and palette.
    /// Allocates an atlas rect, writes the atlas entry and palette to
    /// GPU buffers, and stages pixel data for GPU upload.
    /// Returns true if successful, false if atlas is full or id is invalid.
    pub fn loadDefinition(
        self: *SpriteBank,
        id: u16,
        pixel_data: []const u8,
        width: u16,
        height: u16,
        palette: [16]RGBA32,
    ) bool {
        if (id >= MAX_DEFINITIONS) return false;
        if (width == 0 or height == 0) return false;
        if (width > MAX_SPRITE_SIZE or height > MAX_SPRITE_SIZE) return false;

        const pixel_count: u32 = @as(u32, width) * @as(u32, height);
        if (pixel_data.len < pixel_count) return false;

        // Allocate atlas rectangle
        const rect = self.packer.alloc(width, height) orelse return false;

        // Reuse existing palette slot when redefining to avoid palette table leak.
        // Only allocate a fresh slot for genuinely new sprite IDs.
        const pal_slot: u16 = if (self.definitions[id].active)
            self.definitions[id].palette_index
        else blk: {
            if (self.next_palette_slot >= MAX_PALETTES) return false;
            const s = self.next_palette_slot;
            self.next_palette_slot += 1;
            break :blk s;
        };

        // Write atlas entry to GPU buffer
        if (self.gpu_atlas_entries) |entries| {
            entries[id] = .{
                .atlas_x = rect.x,
                .atlas_y = rect.y,
                .width = width,
                .height = height,
                .frame_count = 1,
                .frame_w = width,
                .frame_h = height,
                .palette_offset = pal_slot,
            };
        }

        // Write palette to GPU buffer
        if (self.gpu_palettes) |palettes| {
            palettes[pal_slot] = palette;
        }

        // Stage pixel data for GPU upload
        if (self.staging_buffer) |staging| {
            if (pixel_count <= self.staging_buffer_size) {
                @memcpy(staging[0..pixel_count], pixel_data[0..pixel_count]);
            }
        }

        // Record definition
        self.definitions[id] = .{
            .width = width,
            .height = height,
            .frame_count = 1,
            .frame_w = width,
            .frame_h = height,
            .atlas_entry_index = id,
            .palette_index = pal_slot,
            .active = true,
        };

        return true;
    }

    /// Create an empty sprite definition of the given size.
    /// Pixels default to 0 (transparent).  Use setPixel() to populate.
    /// Returns true if successful.
    pub fn defineEmpty(self: *SpriteBank, id: u16, w: u16, h: u16) bool {
        if (id >= MAX_DEFINITIONS) return false;
        if (w == 0 or h == 0) return false;
        if (w > MAX_SPRITE_SIZE or h > MAX_SPRITE_SIZE) return false;

        const pixel_count: u32 = @as(u32, w) * @as(u32, h);

        // Allocate atlas rectangle
        const rect = self.packer.alloc(w, h) orelse return false;

        // Reuse existing palette slot when redefining to avoid palette table leak.
        // Only allocate a fresh slot for genuinely new sprite IDs.
        const pal_slot: u16 = if (self.definitions[id].active)
            self.definitions[id].palette_index
        else blk: {
            if (self.next_palette_slot >= MAX_PALETTES) return false;
            const s = self.next_palette_slot;
            self.next_palette_slot += 1;
            break :blk s;
        };

        // Write atlas entry
        if (self.gpu_atlas_entries) |entries| {
            entries[id] = .{
                .atlas_x = rect.x,
                .atlas_y = rect.y,
                .width = w,
                .height = h,
                .frame_count = 1,
                .frame_w = w,
                .frame_h = h,
                .palette_offset = pal_slot,
            };
        }

        // Write default palette (index 0 = transparent, index 1 = black, rest = white)
        if (self.gpu_palettes) |palettes| {
            var pal: [16]RGBA32 = undefined;
            pal[0] = RGBA32.TRANSPARENT;
            pal[1] = RGBA32.BLACK;
            for (2..16) |i| {
                pal[i] = RGBA32.WHITE;
            }
            palettes[pal_slot] = pal;
        }

        // Stage zeroed pixel data for GPU upload
        if (self.staging_buffer) |staging| {
            if (pixel_count <= self.staging_buffer_size) {
                @memset(staging[0..pixel_count], 0);
            }
        }

        // Record definition
        self.definitions[id] = .{
            .width = w,
            .height = h,
            .frame_count = 1,
            .frame_w = w,
            .frame_h = h,
            .atlas_entry_index = id,
            .palette_index = pal_slot,
            .active = true,
        };

        return true;
    }

    /// Set a single pixel in a sprite definition.
    /// This writes to the staging buffer and requires a subsequent upload
    /// command to push the change to the GPU atlas.
    ///
    /// For SPRITEDATA (procedural pixel-by-pixel definition), the caller
    /// should batch changes and issue a single upload at the end.
    pub fn setPixel(self: *SpriteBank, id: u16, x: u16, y: u16, colour_index: u8) void {
        if (id >= MAX_DEFINITIONS) return;
        const def = &self.definitions[id];
        if (!def.active) return;
        if (x >= def.width or y >= def.height) return;

        // We write into the staging buffer at the pixel offset.
        // The caller must trigger an upload command afterward.
        if (self.staging_buffer) |staging| {
            const offset: u32 = @as(u32, y) * @as(u32, def.width) + @as(u32, x);
            if (offset < self.staging_buffer_size) {
                staging[offset] = colour_index & 0x0F;
            }
        }
    }

    /// Set a palette colour for a sprite definition.
    /// Writes directly to the GPU palette buffer (shared memory).
    pub fn setPaletteColour(self: *SpriteBank, id: u16, idx: u8, r: u8, g: u8, b: u8) void {
        if (id >= MAX_DEFINITIONS) return;
        const def = &self.definitions[id];
        if (!def.active) return;
        if (idx >= SPRITE_PALETTE_ENTRIES) return;

        if (self.gpu_palettes) |palettes| {
            palettes[def.palette_index][idx] = RGBA32.init(r, g, b);
        }
    }

    /// Set the full palette for a sprite definition from a 16-entry RGBA array.
    pub fn setPalette(self: *SpriteBank, id: u16, palette: [16]RGBA32) void {
        if (id >= MAX_DEFINITIONS) return;
        const def = &self.definitions[id];
        if (!def.active) return;

        if (self.gpu_palettes) |palettes| {
            palettes[def.palette_index] = palette;
        }
    }

    /// Declare animation strip layout for a sprite definition.
    /// The sprite's pixel data should contain a horizontal strip of frames.
    pub fn setFrames(self: *SpriteBank, id: u16, frame_w: u16, frame_h: u16, count: u16) void {
        if (id >= MAX_DEFINITIONS) return;
        const def = &self.definitions[id];
        if (!def.active) return;
        if (frame_w == 0 or frame_h == 0 or count == 0) return;

        def.frame_count = count;
        def.frame_w = frame_w;
        def.frame_h = frame_h;

        // Update GPU atlas entry
        if (self.gpu_atlas_entries) |entries| {
            entries[def.atlas_entry_index].frame_count = count;
            entries[def.atlas_entry_index].frame_w = frame_w;
            entries[def.atlas_entry_index].frame_h = frame_h;
        }
    }

    // ─── Instance Management ────────────────────────────────────────

    /// Create or reassign a sprite instance.
    pub fn placeInstance(self: *SpriteBank, inst_id: u16, def_id: u16, x: f32, y: f32) void {
        if (inst_id >= MAX_INSTANCES) return;
        if (def_id >= MAX_DEFINITIONS) return;
        if (!self.definitions[def_id].active) return;

        var inst = &self.instances[inst_id];
        inst.* = .{}; // Reset all fields to defaults
        inst.def_id = def_id;
        inst.x = x;
        inst.y = y;
        inst.active = true;
        inst.visible = false; // Must call SPRITESHOW explicitly
    }

    /// Remove a sprite instance (deactivate it).
    pub fn removeInstance(self: *SpriteBank, inst_id: u16) void {
        if (inst_id >= MAX_INSTANCES) return;
        self.instances[inst_id].active = false;
        self.instances[inst_id].visible = false;
    }

    /// Remove all sprite instances.
    pub fn removeAll(self: *SpriteBank) void {
        for (&self.instances) |*inst| {
            inst.active = false;
            inst.visible = false;
        }
    }

    /// Get a mutable reference to an instance (with bounds and active check).
    pub fn getInstance(self: *SpriteBank, inst_id: u16) ?*SpriteInstance {
        if (inst_id >= MAX_INSTANCES) return null;
        const inst = &self.instances[inst_id];
        if (!inst.active) return null;
        return inst;
    }

    /// Count the number of active instances.
    pub fn activeInstanceCount(self: *const SpriteBank) u32 {
        var count: u32 = 0;
        for (&self.instances) |*inst| {
            if (inst.active) count += 1;
        }
        return count;
    }

    // ─── Animation Tick ─────────────────────────────────────────────

    /// Advance animation accumulators for all auto-animated instances.
    /// Called once per frame (typically during VSYNC).
    fn tickAnimation(self: *SpriteBank) void {
        for (&self.instances) |*inst| {
            if (!inst.active or inst.anim_speed <= 0) continue;

            const def = &self.definitions[inst.def_id];
            if (def.frame_count <= 1) continue;

            inst.anim_accumulator += inst.anim_speed;
            while (inst.anim_accumulator >= 1.0) {
                inst.anim_accumulator -= 1.0;
                inst.frame += 1;
                if (inst.frame >= def.frame_count) {
                    inst.frame = 0;
                }
            }
        }
    }

    // ─── GPU Sync ───────────────────────────────────────────────────

    /// Update animation, sort instances by priority, and write the sorted
    /// instance descriptors into the GPU instance buffer.
    ///
    /// Called from the JIT thread during VSYNC, before the GPU frame is
    /// submitted.  At this point the JIT thread is about to block, so
    /// writing to shared buffers is safe.
    pub fn updateAndSync(self: *SpriteBank) void {
        // 1. Advance animation
        self.tickAnimation();

        // 2. Collect active+visible instance indices
        var active_count: u32 = 0;
        for (0..MAX_INSTANCES) |i| {
            if (self.instances[i].active and self.instances[i].visible) {
                self.sorted_indices[active_count] = @intCast(i);
                active_count += 1;
            }
        }

        // 3. Sort by priority (insertion sort — stable, O(n²) but n ≤ 512)
        if (active_count > 1) {
            const indices = self.sorted_indices[0..active_count];
            var i: u32 = 1;
            while (i < active_count) : (i += 1) {
                const key = indices[i];
                const key_pri = self.instances[key].priority;
                var j: u32 = i;
                while (j > 0 and self.instances[indices[j - 1]].priority > key_pri) {
                    indices[j] = indices[j - 1];
                    j -= 1;
                }
                indices[j] = key;
            }
        }

        // 4. Write sorted instances to GPU buffer
        if (self.gpu_instances) |gpu_buf| {
            for (0..active_count) |i| {
                const inst_idx = self.sorted_indices[i];
                const inst = &self.instances[inst_idx];
                const def = &self.definitions[inst.def_id];
                gpu_buf[i] = inst.toGPU(def);
            }
        }

        // 5. Update uniforms
        if (self.gpu_uniforms) |uniforms| {
            uniforms.num_instances = active_count;
            uniforms.frame_counter = gfx.g_state.frame_counter;
            // output_width/height are set by the ObjC bridge during allocation
        }
    }

    // ─── Collision Detection ────────────────────────────────────────

    /// Compute the axis-aligned bounding box of a (possibly rotated/scaled)
    /// sprite instance in screen coordinates.
    pub fn getAABB(self: *const SpriteBank, inst_id: u16) ?struct { min_x: f32, min_y: f32, max_x: f32, max_y: f32 } {
        if (inst_id >= MAX_INSTANCES) return null;
        const inst = &self.instances[inst_id];
        if (!inst.active) return null;

        const def = &self.definitions[inst.def_id];
        const fw: f32 = @floatFromInt(def.frame_w);
        const fh: f32 = @floatFromInt(def.frame_h);

        // Scaled dimensions
        const sw = fw * inst.scale_x;
        const sh = fh * inst.scale_y;

        // Anchor point in scaled space
        const ax = sw * inst.anchor_x;
        const ay = sh * inst.anchor_y;

        // Four corners relative to position, centered on anchor
        const corners = [4][2]f32{
            .{ -ax, -ay },
            .{ sw - ax, -ay },
            .{ -ax, sh - ay },
            .{ sw - ax, sh - ay },
        };

        // Rotate corners
        const cos_r = @cos(inst.rotation);
        const sin_r = @sin(inst.rotation);

        var min_x: f32 = std.math.floatMax(f32);
        var min_y: f32 = std.math.floatMax(f32);
        var max_x: f32 = -std.math.floatMax(f32);
        var max_y: f32 = -std.math.floatMax(f32);

        for (corners) |corner| {
            const rx = corner[0] * cos_r - corner[1] * sin_r + inst.x + ax;
            const ry = corner[0] * sin_r + corner[1] * cos_r + inst.y + ay;
            min_x = @min(min_x, rx);
            min_y = @min(min_y, ry);
            max_x = @max(max_x, rx);
            max_y = @max(max_y, ry);
        }

        return .{ .min_x = min_x, .min_y = min_y, .max_x = max_x, .max_y = max_y };
    }

    /// Test bounding-box collision between two instances.
    pub fn testCollision(self: *const SpriteBank, a: u16, b: u16) bool {
        const aabb_a = self.getAABB(a) orelse return false;
        const aabb_b = self.getAABB(b) orelse return false;

        // AABB overlap test
        if (aabb_a.max_x <= aabb_b.min_x) return false;
        if (aabb_a.min_x >= aabb_b.max_x) return false;
        if (aabb_a.max_y <= aabb_b.min_y) return false;
        if (aabb_a.min_y >= aabb_b.max_y) return false;

        return true;
    }

    /// Test group-vs-group collision.  Returns true if any instance in
    /// group_a overlaps any instance in group_b.
    pub fn testGroupCollision(self: *const SpriteBank, group_a: u8, group_b: u8) bool {
        if (group_a == 0 or group_b == 0) return false;

        // Collect indices for each group
        var list_a: [MAX_INSTANCES]u16 = undefined;
        var count_a: u32 = 0;
        var list_b: [MAX_INSTANCES]u16 = undefined;
        var count_b: u32 = 0;

        for (0..MAX_INSTANCES) |i| {
            const inst = &self.instances[i];
            if (!inst.active or !inst.visible) continue;
            if (inst.collision_group == group_a) {
                list_a[count_a] = @intCast(i);
                count_a += 1;
            }
            if (inst.collision_group == group_b) {
                list_b[count_b] = @intCast(i);
                count_b += 1;
            }
        }

        // Test all pairs
        for (list_a[0..count_a]) |ia| {
            for (list_b[0..count_b]) |ib| {
                if (ia == ib) continue; // Don't test against self
                if (self.testCollision(ia, ib)) return true;
            }
        }

        return false;
    }

    // ─── Buffer Setup ───────────────────────────────────────────────

    /// Set GPU buffer pointers.  Called by the ObjC bridge after
    /// allocating the shared MTLBuffers.
    pub fn setBufferPointers(
        self: *SpriteBank,
        atlas_entries: ?*anyopaque,
        instances_buf: ?*anyopaque,
        palettes_buf: ?*anyopaque,
        uniforms_buf: ?*anyopaque,
    ) void {
        self.gpu_atlas_entries = if (atlas_entries) |p| @ptrCast(@alignCast(p)) else null;
        self.gpu_instances = if (instances_buf) |p| @ptrCast(@alignCast(p)) else null;
        self.gpu_palettes = if (palettes_buf) |p| @ptrCast(@alignCast(p)) else null;
        self.gpu_uniforms = if (uniforms_buf) |p| @ptrCast(@alignCast(p)) else null;
    }

    /// Set staging buffer pointer and size.
    pub fn setStagingBuffer(self: *SpriteBank, ptr: ?*anyopaque, size: u32) void {
        self.staging_buffer = if (ptr) |p| @ptrCast(p) else null;
        self.staging_buffer_size = size;
    }

    /// Clear all buffer pointers (called when the window is closed or
    /// buffers are released).
    pub fn clearBufferPointers(self: *SpriteBank) void {
        self.gpu_atlas_entries = null;
        self.gpu_instances = null;
        self.gpu_palettes = null;
        self.gpu_uniforms = null;
        self.staging_buffer = null;
        self.staging_buffer_size = 0;
    }

    /// Full reset — clear all definitions, instances, and atlas state.
    pub fn reset(self: *SpriteBank) void {
        self.definitions = [_]SpriteDefinition{.{}} ** MAX_DEFINITIONS;
        self.instances = [_]SpriteInstance{.{}} ** MAX_INSTANCES;
        self.packer.reset();
        self.next_palette_slot = 0;

        // Zero GPU buffers if they exist
        if (self.gpu_atlas_entries) |entries| {
            const bytes: [*]u8 = @ptrCast(entries);
            @memset(bytes[0 .. MAX_DEFINITIONS * @sizeOf(SpriteAtlasEntryGPU)], 0);
        }
        if (self.gpu_instances) |insts| {
            const bytes: [*]u8 = @ptrCast(insts);
            @memset(bytes[0 .. MAX_INSTANCES * @sizeOf(SpriteInstanceGPU)], 0);
        }
        if (self.gpu_uniforms) |uniforms| {
            uniforms.num_instances = 0;
        }
    }
};
