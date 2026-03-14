// ─── Ed Graphics Metal Shaders ──────────────────────────────────────────────
//
// Metal compute and render shaders for the retro graphics system:
//
//   Pass 1: palette_animate — GPU-side palette animation state machine
//   Pass 2: palette_lookup  — convert indexed pixels to RGBA via palettes
//   Pass 3: collision_check — pixel-perfect collision detection
//   Pass 4: display_vertex / display_fragment — fullscreen quad with NN scaling
//
// All `device` buffer bindings point to MTLStorageModeShared buffers
// except where noted as "Private" (GPU-only scratch space).

#include <metal_stdlib>
using namespace metal;

// ─── Shared Structures (must match ed_graphics.zig) ─────────────────────────

struct GfxUniforms {
    uint visible_width;
    uint visible_height;
    uint buffer_width;
    uint buffer_height;
    int  scroll_x;
    int  scroll_y;
    uint frame_counter;
    uint front_buffer;     // which pixel buffer to read from
};

struct PaletteEffect {
    uint  type;          // 0=none, 1=cycle, 2=fade, 3=pulse, 4=gradient, 5=strobe
    uint  flags;         // bit 0: per-line, bit 1: active, bit 2: one-shot
    uint  index_start;
    uint  index_end;
    uint  line_start;
    uint  line_end;
    float speed;
    float phase;
    uchar4 colour_a;
    uchar4 colour_b;
    int   direction;
    uint  _pad;
};

// Effect type constants
constant uint EFFECT_NONE     = 0;
constant uint EFFECT_CYCLE    = 1;
constant uint EFFECT_FADE     = 2;
constant uint EFFECT_PULSE    = 3;
constant uint EFFECT_GRADIENT = 4;
constant uint EFFECT_STROBE   = 5;

// Effect flag bits
constant uint FLAG_PER_LINE  = 1u << 0;
constant uint FLAG_ACTIVE    = 1u << 1;
constant uint FLAG_ONE_SHOT  = 1u << 2;

// Number of per-line palette entries
constant uint LINE_PAL_ENTRIES = 16;
// Number of global palette entries
constant uint GLOBAL_PAL_ENTRIES = 240;
// Maximum effect slots
constant uint MAX_EFFECTS = 32;

// ─── Helper: Linear interpolation for uchar4 ───────────────────────────────

static uchar4 lerp_colour(uchar4 a, uchar4 b, float t) {
    float4 fa = float4(a) / 255.0;
    float4 fb = float4(b) / 255.0;
    float4 result = mix(fa, fb, clamp(t, 0.0, 1.0));
    return uchar4(result * 255.0);
}

// ═══════════════════════════════════════════════════════════════════════════
// Pass 1: Palette Animation Compute Shader
// ═══════════════════════════════════════════════════════════════════════════
//
// Reads base palettes from SHARED buffers (CPU-written).
// Writes working palettes to PRIVATE buffers (GPU scratch).
// Applies all 32 palette effect slots on top of the base state.

kernel void palette_animate(
    device uchar4*              line_pal_work   [[buffer(0)]],  // Private (GPU scratch) — buf_height * 16 entries
    device uchar4*              global_pal_work [[buffer(1)]],  // Private (GPU scratch) — 240 entries
    device const uchar4*        line_pal_base   [[buffer(2)]],  // Shared (CPU-written)
    device const uchar4*        global_pal_base [[buffer(3)]],  // Shared (CPU-written)
    device PaletteEffect*       effects         [[buffer(4)]],  // Shared (CPU-written, phase updated by GPU)
    constant GfxUniforms&       uniforms        [[buffer(5)]],
    uint tid                                    [[thread_position_in_threadgroup]],
    uint tg_size                                [[threads_per_threadgroup]]
) {
    // ── Phase 1: Copy base palettes to working palettes in parallel ──
    //
    // All threads in the single threadgroup cooperate to copy palette data.
    // Using thread_position_in_threadgroup (not grid) so that the barrier
    // below correctly synchronises ALL copying threads before effects run.

    uint total_line_entries = uniforms.buffer_height * LINE_PAL_ENTRIES;

    // Copy per-line palette
    for (uint i = tid; i < total_line_entries; i += tg_size) {
        line_pal_work[i] = line_pal_base[i];
    }

    // Copy global palette
    for (uint i = tid; i < GLOBAL_PAL_ENTRIES; i += tg_size) {
        global_pal_work[i] = global_pal_base[i];
    }

    // Synchronise — all threads in the threadgroup must finish copying
    // before any thread applies effects.  This only works correctly when
    // the entire kernel is dispatched as a single threadgroup.
    threadgroup_barrier(mem_flags::mem_device);

    // ── Phase 2: Apply active effects ──
    // Each thread with tid < MAX_EFFECTS processes one effect slot.
    if (tid >= MAX_EFFECTS) return;

    device PaletteEffect& eff = effects[tid];

    // Skip inactive effects
    if (eff.type == EFFECT_NONE) return;
    if (!(eff.flags & FLAG_ACTIVE)) return;

    uint frame = uniforms.frame_counter;

    switch (eff.type) {
        case EFFECT_CYCLE: {
            // Colour cycling: rotate palette entries in the range.
            // The top-level index_start >= index_end guard has been removed —
            // the per-line path handles r < 2 per-line, and the global path
            // guards itself.  Removing it here prevents per-line cycle from
            // breaking early when index_start == index_end (single index).

            // Calculate cycle step based on frame and speed
            float cycle_phase = eff.phase;
            uint range = (eff.index_end >= eff.index_start)
                       ? (eff.index_end - eff.index_start + 1)
                       : 1u;

            // Determine shift amount
            int shift = int(cycle_phase) % int(range);
            if (eff.direction < 0) shift = int(range) - shift;

            if (eff.flags & FLAG_PER_LINE) {
                // Apply to per-line palette entries across a scanline band.
                for (uint line = eff.line_start; line <= min(eff.line_end, uniforms.buffer_height - 1); line++) {
                    uint base = line * LINE_PAL_ENTRIES;
                    // Only cycle within per-line range (indices 2-15)
                    uint start = min(eff.index_start, LINE_PAL_ENTRIES - 1);
                    uint end   = min(eff.index_end,   LINE_PAL_ENTRIES - 1);
                    uint r = (end >= start) ? (end - start + 1) : 0u;
                    if (r < 2) continue;

                    // Read original values (max 16 per-line entries)
                    uchar4 tmp[16];
                    for (uint k = 0; k < r; k++) {
                        tmp[k] = line_pal_work[base + start + k];
                    }
                    // Write shifted values
                    for (uint k = 0; k < r; k++) {
                        uint src_idx = (k + uint(shift)) % r;
                        line_pal_work[base + start + k] = tmp[src_idx];
                    }
                }
            } else if (eff.index_start >= 16) {
                // Global palette cycling — requires at least 2 entries
                if (eff.index_start >= eff.index_end) break;
                uint gstart = eff.index_start - 16;
                uint gend = min(eff.index_end - 16, GLOBAL_PAL_ENTRIES - 1);
                uint r = (gend >= gstart) ? (gend - gstart + 1) : 0u;
                if (r < 2) break;
                // Cap to 64 entries to bound GPU thread-stack usage
                // (was 240 = 960 bytes/thread × 32 slots ≈ 30 KB)
                uint rcap = min(r, 64u);

                uchar4 tmp[64];
                for (uint k = 0; k < rcap; k++) {
                    tmp[k] = global_pal_work[gstart + k];
                }
                for (uint k = 0; k < rcap; k++) {
                    uint src_idx = (k + uint(shift)) % rcap;
                    global_pal_work[gstart + k] = tmp[src_idx];
                }
            }

            // Advance phase
            eff.phase += 1.0 / max(eff.speed, 1.0);
            break;
        }

        case EFFECT_FADE: {
            // Smooth fade from colour_a to colour_b
            float progress = eff.phase / max(eff.speed, 1.0);
            progress = clamp(progress, 0.0, 1.0);

            uchar4 colour = lerp_colour(eff.colour_a, eff.colour_b, progress);

            if (eff.flags & FLAG_PER_LINE) {
                // Guard matches PULSE/STROBE: prevent OOB write when index >= 16
                if (eff.index_start < LINE_PAL_ENTRIES) {
                    for (uint line = eff.line_start; line <= min(eff.line_end, uniforms.buffer_height - 1); line++) {
                        uint idx = line * LINE_PAL_ENTRIES + eff.index_start;
                        line_pal_work[idx] = colour;
                    }
                }
            } else if (eff.index_start >= 16) {
                uint gidx = eff.index_start - 16;
                if (gidx < GLOBAL_PAL_ENTRIES) {
                    global_pal_work[gidx] = colour;
                }
            }

            eff.phase += 1.0;

            // One-shot: deactivate when complete
            if ((eff.flags & FLAG_ONE_SHOT) && progress >= 1.0) {
                eff.flags &= ~FLAG_ACTIVE;
            }
            break;
        }

        case EFFECT_PULSE: {
            // Oscillate between two colours using a sine wave
            float t = (sin(eff.phase * 2.0 * M_PI_F / max(eff.speed, 1.0)) + 1.0) * 0.5;
            uchar4 colour = lerp_colour(eff.colour_a, eff.colour_b, t);

            if (eff.flags & FLAG_PER_LINE) {
                // Hoist constant bounds check out of the per-line loop
                if (eff.index_start < LINE_PAL_ENTRIES) {
                    for (uint line = eff.line_start; line <= min(eff.line_end, uniforms.buffer_height - 1); line++) {
                        uint idx = line * LINE_PAL_ENTRIES + eff.index_start;
                        line_pal_work[idx] = colour;
                    }
                }
            } else if (eff.index_start >= 16) {
                uint gidx = eff.index_start - 16;
                if (gidx < GLOBAL_PAL_ENTRIES) {
                    global_pal_work[gidx] = colour;
                }
            }

            eff.phase += 1.0;
            break;
        }

        case EFFECT_GRADIENT: {
            // Fill per-line palette entry with a smooth gradient across scanlines
            if (!(eff.flags & FLAG_PER_LINE)) break;
            if (eff.index_start >= LINE_PAL_ENTRIES) break;

            uint ls = eff.line_start;
            uint le = min(eff.line_end, uniforms.buffer_height - 1);
            uint span = le - ls;
            if (span == 0) span = 1;

            for (uint line = ls; line <= le; line++) {
                float t = float(line - ls) / float(span);
                uchar4 colour = lerp_colour(eff.colour_a, eff.colour_b, t);
                uint idx = line * LINE_PAL_ENTRIES + eff.index_start;
                line_pal_work[idx] = colour;
            }
            break;
        }

        case EFFECT_STROBE: {
            // Alternate between two colours at a fixed rate
            // speed = on_frames, phase field stores off_frames (set at install time)
            float on_frames = max(eff.speed, 1.0);
            float off_frames = max(eff.phase, 1.0);  // Note: phase is reused for off_frames
            float total = on_frames + off_frames;
            float pos = fmod(float(frame), total);
            uchar4 colour = (pos < on_frames) ? eff.colour_a : eff.colour_b;

            if (eff.flags & FLAG_PER_LINE) {
                // Hoist constant bounds check out of the per-line loop
                if (eff.index_start < LINE_PAL_ENTRIES) {
                    for (uint line = eff.line_start; line <= min(eff.line_end, uniforms.buffer_height - 1); line++) {
                        uint idx = line * LINE_PAL_ENTRIES + eff.index_start;
                        line_pal_work[idx] = colour;
                    }
                }
            } else if (eff.index_start >= 16) {
                uint gidx = eff.index_start - 16;
                if (gidx < GLOBAL_PAL_ENTRIES) {
                    global_pal_work[gidx] = colour;
                }
            }
            // Note: strobe doesn't advance phase — it uses frame_counter directly
            break;
        }

        default:
            break;
    }
}


// ═══════════════════════════════════════════════════════════════════════════
// Pass 2: Palette Lookup Compute Shader
// ═══════════════════════════════════════════════════════════════════════════
//
// Runs once per pixel of the visible area.
// Reads 8-bit indexed pixels from the front buffer (SHARED).
// Reads working palettes from PRIVATE buffers (Pass 1 output).
// Writes RGBA output texture (PRIVATE).

kernel void palette_lookup(
    device const uint8_t*       pixels          [[buffer(0)]],  // Shared (CPU-written pixel buffer)
    device const uchar4*        line_pal_work   [[buffer(1)]],  // Private (Pass 1 output)
    device const uchar4*        global_pal_work [[buffer(2)]],  // Private (Pass 1 output)
    constant GfxUniforms&       uniforms        [[buffer(3)]],
    texture2d<half, access::write> output       [[texture(0)]],  // Private output
    uint2 gid                                   [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms.visible_width || gid.y >= uniforms.visible_height)
        return;

    // Apply scroll offset with wrapping
    int src_x_signed = int(gid.x) + uniforms.scroll_x;
    int src_y_signed = int(gid.y) + uniforms.scroll_y;

    // Modulo with correct wrapping for negative values
    int bw = int(uniforms.buffer_width);
    int bh = int(uniforms.buffer_height);
    uint src_x = uint(((src_x_signed % bw) + bw) % bw);
    uint src_y = uint(((src_y_signed % bh) + bh) % bh);

    uint pixel_offset = src_y * uniforms.buffer_width + src_x;
    uint8_t index = pixels[pixel_offset];

    half4 rgba;
    if (index == 0) {
        // Index 0: always transparent (FIXED)
        rgba = half4(0.0h, 0.0h, 0.0h, 0.0h);
    } else if (index == 1) {
        // Index 1: always black (FIXED)
        rgba = half4(0.0h, 0.0h, 0.0h, 1.0h);
    } else if (index < 16) {
        // Per-line palette: use the display scanline (gid.y, before scroll)
        uint pal_line = gid.y;  // Use display line, not source line
        if (pal_line >= uniforms.buffer_height) pal_line = uniforms.buffer_height - 1;
        uchar4 c = line_pal_work[pal_line * LINE_PAL_ENTRIES + uint(index)];
        rgba = half4(half(c.r), half(c.g), half(c.b), half(c.a)) / 255.0h;
    } else {
        // Global palette (indices 16–255)
        uint gidx = uint(index) - 16;
        if (gidx >= GLOBAL_PAL_ENTRIES) gidx = GLOBAL_PAL_ENTRIES - 1;
        uchar4 c = global_pal_work[gidx];
        rgba = half4(half(c.r), half(c.g), half(c.b), half(c.a)) / 255.0h;
    }

    output.write(rgba, gid);
}


// ═══════════════════════════════════════════════════════════════════════════
// Pass 3: Collision Detection Compute Shader
// ═══════════════════════════════════════════════════════════════════════════
//
// Reads pixel buffers from SHARED memory (CPU-written).
// Writes collision flags to SHARED memory (CPU-readable).
// Both non-transparent (index != 0) at the same relative position = collision.

struct CollisionParams {
    uint buf_a_offset;   // Byte offset of buffer A within the contiguous pixel buffer array
    uint buf_b_offset;   // Byte offset of buffer B
    uint buf_stride;     // Buffer width (stride in bytes)
    int  ax;             // Region A position X
    int  ay;             // Region A position Y
    int  bx;             // Region B position X
    int  by;             // Region B position Y
    uint width;          // Overlap region width
    uint height;         // Overlap region height
    uint flags_index;    // Index into the collision flags buffer to write result
};

kernel void collision_check(
    device const uint8_t*   all_buffers   [[buffer(0)]],  // Shared (all 8 pixel buffers contiguous)
    device atomic_uint*     hit_flags     [[buffer(1)]],  // Shared (CPU reads result)
    constant CollisionParams& params      [[buffer(2)]],
    uint2 gid                             [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) return;

    uint a_idx = params.buf_a_offset +
                 uint(params.ay + int(gid.y)) * params.buf_stride +
                 uint(params.ax + int(gid.x));
    uint b_idx = params.buf_b_offset +
                 uint(params.by + int(gid.y)) * params.buf_stride +
                 uint(params.bx + int(gid.x));

    uint8_t a = all_buffers[a_idx];
    uint8_t b = all_buffers[b_idx];

    // Both non-transparent = collision
    if (a != 0 && b != 0) {
        atomic_store_explicit(&hit_flags[params.flags_index], 1u, memory_order_relaxed);
    }
}


// ═══════════════════════════════════════════════════════════════════════════
// Batch Collision Detection
// ═══════════════════════════════════════════════════════════════════════════
//
// Tests all pairs from a set of collision sources in a single dispatch.
// Each thread handles one pixel of one pair.

struct BatchCollisionParams {
    uint num_sources;
    uint buf_stride;
    uint buffer_size;    // Size of one pixel buffer in bytes
    uint _pad;
};

struct CollisionSource {
    uint buffer_index;   // Which of the 8 buffers (0-7)
    int  x;
    int  y;
    uint width;
    uint height;
    uint _pad[3];
};

// Note: Batch collision is dispatched as multiple collision_check calls
// by the ObjC bridge, one per pair. This avoids the complexity of a
// single mega-kernel. The bridge iterates over pairs and encodes each
// collision_check dispatch with appropriate CollisionParams.


// ═══════════════════════════════════════════════════════════════════════════
// Pass 4: Fullscreen Display Quad
// ═══════════════════════════════════════════════════════════════════════════
//
// Reads the output texture (PRIVATE) and displays it with nearest-neighbour
// sampling for crispy pixel-art scaling.

struct DisplayVertexOut {
    float4 position [[position]];
    float2 tex_coord;
};

struct DisplayUniforms {
    float2 viewport_size;     // Physical viewport size in pixels
    float2 texture_size;      // Logical texture size (visible_width × visible_height)
    float  par_numerator;     // Pixel aspect ratio correction
    float  par_denominator;
    float  _pad[2];
};

vertex DisplayVertexOut display_vertex(
    uint vid [[vertex_id]],
    constant DisplayUniforms& uniforms [[buffer(0)]]
) {
    // Fullscreen triangle trick: 3 vertices, no vertex buffer needed
    // Vertex 0: (-1, -1), Vertex 1: (3, -1), Vertex 2: (-1, 3)
    // This covers the entire screen with a single oversized triangle.
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };

    // Compute texture coordinates with aspect ratio correction
    float par = uniforms.par_numerator / max(uniforms.par_denominator, 1.0);

    // The logical display dimensions after PAR correction
    float display_w = uniforms.texture_size.x;
    float display_h = uniforms.texture_size.y * par;

    // Compute scaling to fit in viewport while maintaining aspect ratio
    float scale_x = uniforms.viewport_size.x / display_w;
    float scale_y = uniforms.viewport_size.y / display_h;
    float scale = min(scale_x, scale_y);

    // Integer scaling for pixel-perfect rendering (round down to nearest integer)
    float int_scale = max(floor(scale), 1.0);

    // If integer scaling would be too small, use non-integer
    if (int_scale * display_w < uniforms.viewport_size.x * 0.5 ||
        int_scale * display_h < uniforms.viewport_size.y * 0.5) {
        int_scale = scale;
    }

    // Compute the actual displayed area in normalised device coordinates
    float ndc_w = (int_scale * display_w) / uniforms.viewport_size.x;
    float ndc_h = (int_scale * display_h) / uniforms.viewport_size.y;

    // Remap position to center the display area
    float2 pos = positions[vid];

    // Compute texture coordinate from NDC position
    // Map from [-1, 1] NDC to [0, 1] texture space, accounting for centering
    float2 tex;
    tex.x = (pos.x / ndc_w + 1.0) * 0.5;
    tex.y = (1.0 - pos.y / ndc_h) * 0.5;  // Flip Y for Metal's texture coordinates

    DisplayVertexOut out;
    out.position = float4(pos, 0.0, 1.0);
    out.tex_coord = tex;
    return out;
}

fragment half4 display_fragment(
    DisplayVertexOut in [[stage_in]],
    texture2d<half> screen [[texture(0)]],
    sampler nearest_sampler [[sampler(0)]]
) {
    // Clamp to valid texture region
    if (in.tex_coord.x < 0.0 || in.tex_coord.x > 1.0 ||
        in.tex_coord.y < 0.0 || in.tex_coord.y > 1.0) {
        return half4(0.0h, 0.0h, 0.0h, 1.0h);  // Black letterbox/pillarbox
    }

    return screen.sample(nearest_sampler, in.tex_coord);
}


// ═══════════════════════════════════════════════════════════════════════════
// Sprite System — GPU-Driven Rendering
// ═══════════════════════════════════════════════════════════════════════════
//
// Composite sprites onto the output texture after palette_lookup.
// Each thread handles one output pixel and iterates over all active
// sprite instances (pre-sorted by priority, back-to-front).
//
// CPU cost: zero per-pixel work — only instance descriptor updates.
// GPU cost: per-pixel loop over instances with early bbox exit.

// ─── Sprite Structures (must match sprite.zig extern structs) ───────────────

struct SpriteAtlasEntry {
    uint atlas_x;
    uint atlas_y;
    uint width;
    uint height;
    uint frame_count;
    uint frame_w;
    uint frame_h;
    uint palette_offset;
};

struct SpriteInstanceGPU {
    float  x;
    float  y;
    float  rotation;
    float  scale_x;
    float  scale_y;
    float  anchor_x;
    float  anchor_y;
    uint   atlas_entry_id;
    uint   frame;
    uint   flags;
    uint   priority;
    float  alpha;
    uint   effect_type;
    float  effect_param1;
    float  effect_param2;
    uchar4 effect_colour;
    uint   palette_override;
    uint   collision_group;
    uint   _pad[2];
};

struct SpriteUniforms {
    uint num_instances;
    uint atlas_width;
    uint atlas_height;
    uint output_width;
    uint output_height;
    uint frame_counter;
    uint _pad[2];
};

// ─── Sprite Flag Bits ───────────────────────────────────────────────────────

constant uint SFLAG_VISIBLE  = 1u << 0;
constant uint SFLAG_FLIP_H   = 1u << 1;
constant uint SFLAG_FLIP_V   = 1u << 2;
constant uint SFLAG_ADDITIVE = 1u << 3;

// ─── Sprite Effect Types ────────────────────────────────────────────────────

constant uint SFX_NONE     = 0;
constant uint SFX_GLOW     = 1;
constant uint SFX_OUTLINE  = 2;
constant uint SFX_SHADOW   = 3;
constant uint SFX_TINT     = 4;
constant uint SFX_FLASH    = 5;
constant uint SFX_DISSOLVE = 6;

// ─── Glow probe directions (8 cardinal + diagonal) ──────────────────────────

constant float2 glow_dirs[8] = {
    float2( 1.0,  0.0),
    float2(-1.0,  0.0),
    float2( 0.0,  1.0),
    float2( 0.0, -1.0),
    float2( 0.7071,  0.7071),
    float2(-0.7071,  0.7071),
    float2( 0.7071, -0.7071),
    float2(-0.7071, -0.7071),
};

// ─── Helper: sample sprite atlas at local coordinates ───────────────────────

static uint sample_sprite_pixel(
    texture2d<uint, access::read> atlas,
    device const SpriteAtlasEntry& entry,
    uint frame,
    int lx,
    int ly
) {
    if (lx < 0 || lx >= int(entry.frame_w) || ly < 0 || ly >= int(entry.frame_h))
        return 0;
    uint ax = entry.atlas_x + frame * entry.frame_w + uint(lx);
    uint ay = entry.atlas_y + uint(ly);
    return atlas.read(uint2(ax, ay)).r;
}

// ─── Helper: inverse-transform screen pixel to sprite-local coords ──────────

static float2 screen_to_local(
    float px,
    float py,
    device const SpriteInstanceGPU& inst,
    device const SpriteAtlasEntry& entry
) {
    // Translate relative to instance position
    float dx = px - inst.x;
    float dy = py - inst.y;

    // Translate to pivot (in scaled space)
    float ax = float(entry.frame_w) * inst.scale_x * inst.anchor_x;
    float ay = float(entry.frame_h) * inst.scale_y * inst.anchor_y;
    dx -= ax;
    dy -= ay;

    // Inverse rotation
    float cos_r = cos(-inst.rotation);
    float sin_r = sin(-inst.rotation);
    float rx = dx * cos_r - dy * sin_r;
    float ry = dx * sin_r + dy * cos_r;

    // Inverse scale
    rx /= inst.scale_x;
    ry /= inst.scale_y;

    // Translate back from pivot (in unscaled space)
    rx += float(entry.frame_w) * inst.anchor_x;
    ry += float(entry.frame_h) * inst.anchor_y;

    return float2(rx, ry);
}


// ═══════════════════════════════════════════════════════════════════════════
// sprite_render — GPU Compute Kernel
// ═══════════════════════════════════════════════════════════════════════════
//
// Dispatched as a 2D grid over (output_width, output_height).
// Reads the output texture (from palette_lookup), composites sprites
// on top, and writes back.

kernel void sprite_render(
    texture2d<half, access::read_write>    output     [[texture(0)]],
    texture2d<uint, access::read>          atlas      [[texture(1)]],
    device const SpriteAtlasEntry*         entries    [[buffer(0)]],
    device const SpriteInstanceGPU*        instances  [[buffer(1)]],
    device const uchar4*                   palettes   [[buffer(2)]],
    constant SpriteUniforms&               uniforms   [[buffer(3)]],
    uint2 gid                                         [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms.output_width || gid.y >= uniforms.output_height)
        return;

    half4 result = output.read(gid);
    float screen_x = float(gid.x);
    float screen_y = float(gid.y);

    // Iterate instances back-to-front (sorted by priority, lowest first)
    for (uint i = 0; i < uniforms.num_instances; i++) {
        device const SpriteInstanceGPU& inst = instances[i];

        // Skip invisible
        if (!(inst.flags & SFLAG_VISIBLE)) continue;

        device const SpriteAtlasEntry& entry = entries[inst.atlas_entry_id];
        if (entry.frame_w == 0 || entry.frame_h == 0) continue;

        // ── Bounding box early exit ──
        // Compute the max possible extent of the sprite in screen space
        float fw_scaled = float(entry.frame_w) * abs(inst.scale_x);
        float fh_scaled = float(entry.frame_h) * abs(inst.scale_y);
        float max_dim = max(fw_scaled, fh_scaled) * 1.4143; // sqrt(2) for rotation

        // Expand for effects (glow radius, outline thickness, shadow offset)
        float effect_expand = 0.0;
        if (inst.effect_type == SFX_GLOW) {
            effect_expand = inst.effect_param1;
        } else if (inst.effect_type == SFX_OUTLINE) {
            effect_expand = inst.effect_param1;
        } else if (inst.effect_type == SFX_SHADOW) {
            effect_expand = max(abs(inst.effect_param1), abs(inst.effect_param2));
        }
        max_dim += effect_expand * 2.0;

        // Centre of the sprite in screen space
        float cx = inst.x + fw_scaled * inst.anchor_x;
        float cy = inst.y + fh_scaled * inst.anchor_y;

        // Quick reject
        if (abs(screen_x - cx) > max_dim || abs(screen_y - cy) > max_dim)
            continue;

        // ── Inverse transform: screen → sprite local coords ──
        float2 local = screen_to_local(screen_x, screen_y, inst, entry);

        // Apply flip to local coordinates
        float lx = local.x;
        float ly = local.y;
        if (inst.flags & SFLAG_FLIP_H) lx = float(entry.frame_w - 1) - lx;
        if (inst.flags & SFLAG_FLIP_V) ly = float(entry.frame_h - 1) - ly;

        // Nearest-neighbour sample coordinates
        int sx = int(floor(lx));
        int sy = int(floor(ly));

        bool inside = (sx >= 0 && sx < int(entry.frame_w) &&
                       sy >= 0 && sy < int(entry.frame_h));

        uint pixel_index = inside ? sample_sprite_pixel(atlas, entry, inst.frame, sx, sy) : 0;

        // ── Palette lookup ──
        uint pal_base = (inst.palette_override > 0)
                       ? (inst.palette_override - 1) * 16
                       : entry.palette_offset * 16;

        // ── Process effects ──
        half4 sprite_colour = half4(0.0h);
        bool has_pixel = false;

        switch (inst.effect_type) {

        // ────────────────────────────────────────────────────────────
        // Effect: Shadow
        // ────────────────────────────────────────────────────────────
        case SFX_SHADOW: {
            // Shadow pass: check the shadow-shifted position first
            float shadow_ox = inst.effect_param1;
            float shadow_oy = inst.effect_param2;
            half4 shadow_colour = half4(inst.effect_colour) / 255.0h;

            // Shadow sample (shift local coords by shadow offset in unscaled space)
            float shadow_lx = lx - shadow_ox / inst.scale_x;
            float shadow_ly = ly - shadow_oy / inst.scale_y;
            int shadow_sx = int(floor(shadow_lx));
            int shadow_sy = int(floor(shadow_ly));
            uint shadow_pi = sample_sprite_pixel(atlas, entry, inst.frame, shadow_sx, shadow_sy);

            if (shadow_pi != 0 && (pixel_index == 0 || !inside)) {
                // Shadow pixel visible (no sprite pixel on top at this location)
                sprite_colour = shadow_colour;
                has_pixel = true;
            }

            // Main sprite pixel (draws on top of shadow)
            if (inside && pixel_index != 0) {
                uchar4 pc = palettes[pal_base + pixel_index];
                sprite_colour = half4(half(pc.r), half(pc.g), half(pc.b), half(pc.a)) / 255.0h;
                sprite_colour.a *= half(inst.alpha);
                has_pixel = true;
            }
            break;
        }

        // ────────────────────────────────────────────────────────────
        // Effect: Glow
        // ────────────────────────────────────────────────────────────
        case SFX_GLOW: {
            half4 glow_colour = half4(inst.effect_colour) / 255.0h;
            float radius = max(inst.effect_param1, 1.0);
            float intensity = inst.effect_param2;

            if (inside && pixel_index != 0) {
                // Sprite pixel: render normally + additive glow on top
                uchar4 pc = palettes[pal_base + pixel_index];
                sprite_colour = half4(half(pc.r), half(pc.g), half(pc.b), half(pc.a)) / 255.0h;
                sprite_colour.a *= half(inst.alpha);
                sprite_colour.rgb += glow_colour.rgb * half(intensity * 0.3);
                has_pixel = true;
            } else {
                // Outside sprite — probe for nearby opaque pixels to create glow
                float min_dist = radius + 1.0;
                for (int dir = 0; dir < 8; dir++) {
                    for (float d = 1.0; d <= radius; d += 1.0) {
                        float2 probe_offset = glow_dirs[dir] * d;
                        float plx_f = lx + probe_offset.x / inst.scale_x;
                        float ply_f = ly + probe_offset.y / inst.scale_y;
                        int plx = int(floor(plx_f));
                        int ply = int(floor(ply_f));
                        uint pi = sample_sprite_pixel(atlas, entry, inst.frame, plx, ply);
                        if (pi != 0) {
                            min_dist = min(min_dist, d);
                            break; // found nearest in this direction
                        }
                    }
                }
                if (min_dist <= radius) {
                    float falloff = 1.0 - (min_dist / radius);
                    float glow_alpha = falloff * falloff * intensity;
                    sprite_colour = glow_colour;
                    sprite_colour.a = half(glow_alpha);
                    has_pixel = true;
                }
            }
            break;
        }

        // ────────────────────────────────────────────────────────────
        // Effect: Outline
        // ────────────────────────────────────────────────────────────
        case SFX_OUTLINE: {
            int thickness = max(int(inst.effect_param1), 1);
            half4 outline_colour = half4(inst.effect_colour) / 255.0h;

            if (inside && pixel_index != 0) {
                // Opaque sprite pixel: render normally
                uchar4 pc = palettes[pal_base + pixel_index];
                sprite_colour = half4(half(pc.r), half(pc.g), half(pc.b), half(pc.a)) / 255.0h;
                sprite_colour.a *= half(inst.alpha);
                has_pixel = true;
            } else {
                // Transparent or outside: check if any neighbour within thickness is opaque
                bool found_neighbour = false;
                for (int dy = -thickness; dy <= thickness && !found_neighbour; dy++) {
                    for (int dx = -thickness; dx <= thickness && !found_neighbour; dx++) {
                        if (dx == 0 && dy == 0) continue;
                        int nx = int(floor(lx)) + dx;
                        int ny = int(floor(ly)) + dy;
                        uint ni = sample_sprite_pixel(atlas, entry, inst.frame, nx, ny);
                        if (ni != 0) {
                            found_neighbour = true;
                        }
                    }
                }
                if (found_neighbour) {
                    sprite_colour = outline_colour;
                    sprite_colour.a *= half(inst.alpha);
                    has_pixel = true;
                }
            }
            break;
        }

        // ────────────────────────────────────────────────────────────
        // Effect: Tint
        // ────────────────────────────────────────────────────────────
        case SFX_TINT: {
            if (inside && pixel_index != 0) {
                uchar4 pc = palettes[pal_base + pixel_index];
                sprite_colour = half4(half(pc.r), half(pc.g), half(pc.b), half(pc.a)) / 255.0h;
                half4 tint = half4(inst.effect_colour) / 255.0h;
                half factor = half(inst.effect_param1);
                sprite_colour.rgb = mix(sprite_colour.rgb, sprite_colour.rgb * tint.rgb, factor);
                sprite_colour.a *= half(inst.alpha);
                has_pixel = true;
            }
            break;
        }

        // ────────────────────────────────────────────────────────────
        // Effect: Flash
        // ────────────────────────────────────────────────────────────
        case SFX_FLASH: {
            if (inside && pixel_index != 0) {
                uchar4 pc = palettes[pal_base + pixel_index];
                sprite_colour = half4(half(pc.r), half(pc.g), half(pc.b), half(pc.a)) / 255.0h;

                // Alternate between normal and flash colour
                float speed = max(inst.effect_param1, 1.0);
                float phase = fmod(float(uniforms.frame_counter), speed * 2.0);
                if (phase < speed) {
                    half4 flash_c = half4(inst.effect_colour) / 255.0h;
                    sprite_colour.rgb = flash_c.rgb;
                }
                sprite_colour.a *= half(inst.alpha);
                has_pixel = true;
            }
            break;
        }

        // ────────────────────────────────────────────────────────────
        // Effect: Dissolve
        // ────────────────────────────────────────────────────────────
        case SFX_DISSOLVE: {
            if (inside && pixel_index != 0) {
                // Noise-based discard
                float threshold = clamp(inst.effect_param1, 0.0, 1.0);
                float seed = inst.effect_param2;
                float noise = fract(sin(dot(float2(float(sx), float(sy)),
                                            float2(12.9898, 78.233)) + seed) * 43758.5453);
                if (noise >= threshold) {
                    uchar4 pc = palettes[pal_base + pixel_index];
                    sprite_colour = half4(half(pc.r), half(pc.g), half(pc.b), half(pc.a)) / 255.0h;
                    sprite_colour.a *= half(inst.alpha);
                    has_pixel = true;
                }
            }
            break;
        }

        // ────────────────────────────────────────────────────────────
        // No effect (default)
        // ────────────────────────────────────────────────────────────
        default: {
            if (inside && pixel_index != 0) {
                uchar4 pc = palettes[pal_base + pixel_index];
                sprite_colour = half4(half(pc.r), half(pc.g), half(pc.b), half(pc.a)) / 255.0h;
                sprite_colour.a *= half(inst.alpha);
                has_pixel = true;
            }
            break;
        }
        } // end switch

        // ── Composite onto result ──
        if (has_pixel && sprite_colour.a > 0.001h) {
            if (inst.flags & SFLAG_ADDITIVE) {
                result.rgb += sprite_colour.rgb * sprite_colour.a;
            } else {
                result.rgb = mix(result.rgb, sprite_colour.rgb, sprite_colour.a);
                result.a = max(result.a, sprite_colour.a);
            }
        }
    } // end instance loop

    output.write(result, gid);
}
