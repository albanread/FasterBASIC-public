// ─── Ed Glyph Shader — Instanced Text Rendering ────────────────────────────
//
// Renders monospaced text via instanced quads. Each instance represents one
// character cell with:
//   - Screen position (pixels, top-left of cell)
//   - Glyph atlas UV (pixels, top-left of glyph in atlas)
//   - Foreground colour (RGBA u8)
//   - Background colour (RGBA u8)
//   - Flags (underline, bold, cursor, wavy underline, selection, inverse)
//
// The vertex shader positions a unit quad per instance and computes texture
// coordinates. The fragment shader samples the glyph atlas alpha mask and
// composites foreground over background.
//
// A single draw call renders all visible text: editor, gutter, terminal, etc.

#include <metal_stdlib>
using namespace metal;

// ─── Shared Types (must match platform.zig GlyphInstance / EdUniforms) ──────

struct GlyphInstance {
    float pos_x;        // screen pos X (pixels, top-left)
    float pos_y;        // screen pos Y (pixels, top-left)
    float uv_x;         // atlas UV X (pixels, top-left of glyph)
    float uv_y;         // atlas UV Y (pixels, top-left of glyph)
    uchar4 fg;          // foreground RGBA
    uchar4 bg;          // background RGBA
    uint   flags;       // bit flags
};

struct EdUniforms {
    float viewport_width;
    float viewport_height;
    float cell_width;
    float cell_height;
    float atlas_width;
    float atlas_height;
    float time;
    float effects_mode; // 0=none, 1=crt, 2=scanlines
};

// Flag constants (must match platform.zig)
constant uint FLAG_UNDERLINE      = 1u << 0;
constant uint FLAG_BOLD           = 1u << 1;
constant uint FLAG_CURSOR         = 1u << 2;
constant uint FLAG_STRIKETHROUGH  = 1u << 3;
constant uint FLAG_WAVY_UNDERLINE = 1u << 4;
constant uint FLAG_SELECTION      = 1u << 5;
constant uint FLAG_INVERSE        = 1u << 6;

// ─── Vertex Output ──────────────────────────────────────────────────────────

struct VertexOut {
    float4 position [[position]];
    float2 tex_coord;
    float4 fg_color;
    float4 bg_color;
    uint   flags;
    float2 cell_pos;      // position within the cell (0..1, 0..1)
    float  cell_width;
    float  cell_height;
    float  time;
    float2 screen_pos;    // screen position in normalized coords (0..1)
    float  effects_mode;
};

// ─── Vertex Shader ──────────────────────────────────────────────────────────

vertex VertexOut glyph_vertex(
    uint vertex_id      [[vertex_id]],
    uint instance_id    [[instance_id]],
    const device GlyphInstance* instances [[buffer(0)]],
    constant EdUniforms& uniforms        [[buffer(1)]]
) {
    // Unit quad: two triangles covering (0,0) to (1,1)
    // Triangle 1: (0,0), (1,0), (0,1)
    // Triangle 2: (1,0), (1,1), (0,1)
    float2 quad_positions[6] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 0.0),
        float2(1.0, 1.0),
        float2(0.0, 1.0)
    };

    float2 quad_pos = quad_positions[vertex_id];
    GlyphInstance inst = instances[instance_id];

    // Screen position: instance position + quad corner * cell size
    float2 screen_pos = float2(inst.pos_x, inst.pos_y) + quad_pos * float2(uniforms.cell_width, uniforms.cell_height);

    // Convert to NDC: (0,0) = top-left, (w,h) = bottom-right → (-1,1) to (1,-1)
    float2 ndc;
    ndc.x = (screen_pos.x / uniforms.viewport_width)  *  2.0 - 1.0;
    ndc.y = (screen_pos.y / uniforms.viewport_height) * -2.0 + 1.0;

    // Texture coordinate: atlas UV + quad corner * cell size, normalised to atlas size
    float2 tex_coord;
    tex_coord.x = (inst.uv_x + quad_pos.x * uniforms.cell_width)  / uniforms.atlas_width;
    tex_coord.y = (inst.uv_y + quad_pos.y * uniforms.cell_height) / uniforms.atlas_height;

    // Convert uchar4 colours to float4 (0.0–1.0)
    float4 fg = float4(inst.fg) / 255.0;
    float4 bg = float4(inst.bg) / 255.0;

    // Handle inverse flag: swap fg and bg
    if (inst.flags & FLAG_INVERSE) {
        float4 tmp = fg;
        fg = bg;
        bg = tmp;
        fg.a = 1.0;
        bg.a = 1.0;
    }

    VertexOut out;
    out.position    = float4(ndc, 0.0, 1.0);
    out.tex_coord   = tex_coord;
    out.fg_color    = fg;
    out.bg_color    = bg;
    out.flags       = inst.flags;
    out.cell_pos    = quad_pos;
    out.cell_width  = uniforms.cell_width;
    out.cell_height = uniforms.cell_height;
    out.time        = uniforms.time;
    out.screen_pos  = screen_pos / float2(uniforms.viewport_width, uniforms.viewport_height);
    out.effects_mode = uniforms.effects_mode;
    return out;
}

// ─── CRT Effect Helper Functions ────────────────────────────────────────────

/// Scanline effect (horizontal lines across the screen).
float crt_scanlines(float2 screen_pos, float viewport_height) {
    float line = screen_pos.y * viewport_height;
    float scanline = sin(line * 3.14159);
    scanline = scanline * 0.5 + 0.5;
    scanline = pow(scanline, 3.0);
    return mix(1.0, scanline, 0.25); // 0.25 = intensity
}

/// Vignette effect (darken corners).
float crt_vignette(float2 screen_pos) {
    float2 centered = screen_pos * 2.0 - 1.0;
    float dist = length(centered);
    float vig = smoothstep(1.4, 0.5, dist);
    return mix(1.0, vig, 0.4); // 0.4 = strength
}

/// Phosphor glow effect (brighten high-intensity areas).
float3 crt_glow(float3 color) {
    float brightness = dot(color, float3(0.299, 0.587, 0.114));
    float glow = pow(brightness, 2.0) * 0.15; // 0.15 = glow strength
    return color + float3(glow);
}

// ─── Fragment Shader ────────────────────────────────────────────────────────

fragment float4 glyph_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlas_sampler   [[sampler(0)]]
) {
    // Sample glyph alpha from the atlas
    float glyph_alpha = atlas.sample(atlas_sampler, in.tex_coord).a;

    // Bold: thicken the glyph by biasing the alpha
    if (in.flags & FLAG_BOLD) {
        glyph_alpha = saturate(glyph_alpha * 1.4 + 0.05);
    }

    // Composite: foreground over background using glyph alpha
    float4 color = mix(in.bg_color, in.fg_color, glyph_alpha);

    // ── Cursor overlay ──────────────────────────────────────────────────
    if (in.flags & FLAG_CURSOR) {
        // Block cursor with blink: 530ms on, 530ms off
        float blink = step(0.0, sin(in.time * 3.14159 / 0.53));
        if (blink > 0.5) {
            // Semi-transparent cursor overlay
            float4 cursor_color = in.fg_color;
            cursor_color.a = 0.7;
            color = mix(color, cursor_color, cursor_color.a);
        }
    }

    // ── Selection highlight ─────────────────────────────────────────────
    if (in.flags & FLAG_SELECTION) {
        // Blend a selection tint over the background
        // The selection colours are already set in bg, so just ensure visibility
        color = mix(in.bg_color, in.fg_color, glyph_alpha);
    }

    // ── Underline ───────────────────────────────────────────────────────
    if (in.flags & FLAG_UNDERLINE) {
        // Draw a 1px underline at ~90% of cell height
        float underline_y = 0.9;
        float underline_thickness = 1.0 / in.cell_height;
        if (in.cell_pos.y > underline_y && in.cell_pos.y < underline_y + underline_thickness * 2.0) {
            color = in.fg_color;
        }
    }

    // ── Wavy underline (errors) ─────────────────────────────────────────
    if (in.flags & FLAG_WAVY_UNDERLINE) {
        float underline_y = 0.88;
        // Wavy: sine wave along x, 2 cycles per cell
        float wave = sin(in.cell_pos.x * 3.14159 * 4.0) * 0.03;
        float y_dist = abs(in.cell_pos.y - (underline_y + wave));
        float thickness = 1.5 / in.cell_height;
        if (y_dist < thickness) {
            // Error red colour — uses the fg_color which should be set to error colour
            float wave_alpha = 1.0 - (y_dist / thickness);
            float4 wave_color = float4(1.0, 0.3, 0.3, wave_alpha);
            color = mix(color, wave_color, wave_alpha);
        }
    }

    // ── Strikethrough ───────────────────────────────────────────────────
    if (in.flags & FLAG_STRIKETHROUGH) {
        float strike_y = 0.45;
        float strike_thickness = 1.0 / in.cell_height;
        if (in.cell_pos.y > strike_y && in.cell_pos.y < strike_y + strike_thickness * 2.0) {
            color = in.fg_color;
        }
    }

    // ── CRT Effects (if enabled) ────────────────────────────────────────
    if (in.effects_mode >= 1.0) {
        // Apply scanlines
        float scanline_factor = crt_scanlines(in.screen_pos, 1600.0); // Approx height
        color.rgb *= scanline_factor;

        // Apply vignette
        float vignette_factor = crt_vignette(in.screen_pos);
        color.rgb *= vignette_factor;

        // Apply phosphor glow (for CRT mode only, not scanlines-only)
        if (in.effects_mode >= 1.0 && in.effects_mode < 2.0) {
            color.rgb = crt_glow(color.rgb);
        }

        // Add subtle noise/grain
        float grain = fract(sin(dot(in.screen_pos + in.time * 0.001, float2(12.9898, 78.233))) * 43758.5453);
        color.rgb += (grain - 0.5) * 0.015;

        // Subtle flicker
        float flicker = 1.0 + sin(in.time * 120.0) * 0.003;
        color.rgb *= flicker;

        // Clamp
        color.rgb = saturate(color.rgb);
    }

    return color;
}

// ─── Minimap Shader ─────────────────────────────────────────────────────────
//
// The minimap uses the same instance format but renders at a much smaller scale.
// Each "character" becomes a tiny coloured dot. No atlas sampling needed.

struct MinimapVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex MinimapVertexOut minimap_vertex(
    uint vertex_id      [[vertex_id]],
    uint instance_id    [[instance_id]],
    const device GlyphInstance* instances [[buffer(0)]],
    constant EdUniforms& uniforms        [[buffer(1)]]
) {
    float2 quad_positions[6] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 0.0),
        float2(1.0, 1.0),
        float2(0.0, 1.0)
    };

    float2 quad_pos = quad_positions[vertex_id];
    GlyphInstance inst = instances[instance_id];

    // Minimap cells are tiny (e.g., 2x2 pixels)
    float2 screen_pos = float2(inst.pos_x, inst.pos_y) + quad_pos * float2(uniforms.cell_width, uniforms.cell_height);

    float2 ndc;
    ndc.x = (screen_pos.x / uniforms.viewport_width)  *  2.0 - 1.0;
    ndc.y = (screen_pos.y / uniforms.viewport_height) * -2.0 + 1.0;

    // Use the foreground colour directly (no atlas sampling)
    float4 fg = float4(inst.fg) / 255.0;

    MinimapVertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color    = fg;
    return out;
}

fragment float4 minimap_fragment(MinimapVertexOut in [[stage_in]]) {
    return in.color;
}

// ─── Solid Rect Shader ──────────────────────────────────────────────────────
//
// For drawing solid rectangles: cursor blocks, selection highlights, dividers,
// scrollbar elements, find highlights, etc. Uses the same instance buffer
// format but ignores the atlas UV — just draws a solid bg-coloured rect.

struct SolidVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex SolidVertexOut solid_vertex(
    uint vertex_id      [[vertex_id]],
    uint instance_id    [[instance_id]],
    const device GlyphInstance* instances [[buffer(0)]],
    constant EdUniforms& uniforms        [[buffer(1)]]
) {
    float2 quad_positions[6] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 0.0),
        float2(1.0, 1.0),
        float2(0.0, 1.0)
    };

    float2 quad_pos = quad_positions[vertex_id];
    GlyphInstance inst = instances[instance_id];

    // The "cell size" for solid rects is encoded in the UV field:
    // uv_x = rect width, uv_y = rect height
    float2 screen_pos = float2(inst.pos_x, inst.pos_y) + quad_pos * float2(inst.uv_x, inst.uv_y);

    float2 ndc;
    ndc.x = (screen_pos.x / uniforms.viewport_width)  *  2.0 - 1.0;
    ndc.y = (screen_pos.y / uniforms.viewport_height) * -2.0 + 1.0;

    float4 color = float4(inst.bg) / 255.0;

    SolidVertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color    = color;
    return out;
}

fragment float4 solid_fragment(SolidVertexOut in [[stage_in]]) {
    return in.color;
}
