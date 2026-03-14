// ─── Ed CRT Post-Processing Shader ──────────────────────────────────────────
//
// Applies authentic CRT monitor effects to the rendered editor frame:
//   - Barrel distortion (curved screen)
//   - Horizontal scanlines
//   - Phosphor glow / bloom
//   - Vignette (darkened corners)
//   - RGB color separation (chromatic aberration)
//   - Subtle noise/grain
//
// This shader is applied as a post-processing pass when a theme has
// .effects = .crt enabled. The editor is first rendered to an offscreen
// texture, then this shader displays it with CRT effects.

#include <metal_stdlib>
using namespace metal;

// ─── Uniforms ───────────────────────────────────────────────────────────────

struct CRTUniforms {
    float time;           // For animated effects (noise, flicker)
    float viewport_width;
    float viewport_height;
    float curvature;      // Strength of barrel distortion (0.0 = flat, 0.15 = typical CRT)
    float scanline_intensity; // Scanline darkness (0.0 = none, 0.3 = typical)
    float glow_strength;  // Phosphor glow amount (0.0 = none, 0.3 = typical)
    float vignette_strength; // Corner darkening (0.0 = none, 0.5 = typical)
    float chromatic_aberration; // RGB separation (0.0 = none, 0.002 = typical)
};

// ─── Vertex Shader ──────────────────────────────────────────────────────────

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texcoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texcoord;
};

vertex VertexOut crt_vertex(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texcoord = in.texcoord;
    return out;
}

// ─── Helper Functions ───────────────────────────────────────────────────────

/// Apply barrel distortion to UV coordinates (curved screen effect).
float2 barrelDistortion(float2 uv, float curvature) {
    // Center the coordinates
    float2 centered = uv * 2.0 - 1.0;

    // Apply radial distortion
    float r2 = dot(centered, centered);
    float distortion = 1.0 + curvature * r2;

    // Transform back to 0..1 space
    float2 distorted = centered * distortion;
    return distorted * 0.5 + 0.5;
}

/// Generate scanline effect (horizontal lines across the screen).
float scanlines(float2 uv, float height, float intensity) {
    // Calculate which scanline we're on
    float line = floor(uv.y * height);
    float scanline = sin(line * 3.14159);

    // Make scanlines more pronounced
    scanline = scanline * 0.5 + 0.5;
    scanline = pow(scanline, 3.0);

    return mix(1.0, scanline, intensity);
}

/// Vignette effect (darken corners).
float vignette(float2 uv, float strength) {
    float2 centered = uv * 2.0 - 1.0;
    float dist = length(centered);
    float vig = smoothstep(1.4, 0.5, dist);
    return mix(1.0, vig, strength);
}

/// Phosphor glow / bloom effect (samples neighboring pixels).
float3 glow(texture2d<float> tex, sampler smp, float2 uv, float strength) {
    float3 color = float3(0.0);

    // Sample a 3x3 neighborhood with gaussian-like weights
    const float weights[9] = {
        0.05, 0.09, 0.05,
        0.09, 0.16, 0.09,
        0.05, 0.09, 0.05
    };

    const float2 offsets[9] = {
        float2(-1, -1), float2(0, -1), float2(1, -1),
        float2(-1,  0), float2(0,  0), float2(1,  0),
        float2(-1,  1), float2(0,  1), float2(1,  1)
    };

    float2 texel_size = float2(1.0 / 2560.0, 1.0 / 1600.0); // Approximate

    for (int i = 0; i < 9; i++) {
        float2 offset_uv = uv + offsets[i] * texel_size * 2.0;
        color += tex.sample(smp, offset_uv).rgb * weights[i];
    }

    return color * strength;
}

/// Random noise for subtle grain effect.
float noise(float2 uv, float time) {
    return fract(sin(dot(uv + time * 0.001, float2(12.9898, 78.233))) * 43758.5453);
}

// ─── Fragment Shader ────────────────────────────────────────────────────────

fragment float4 crt_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> rendered_frame [[texture(0)]],
    sampler frame_sampler [[sampler(0)]],
    constant CRTUniforms& uniforms [[buffer(0)]]
) {
    float2 uv = in.texcoord;

    // ── 1. Apply barrel distortion ──────────────────────────────────────
    float2 distorted_uv = barrelDistortion(uv, uniforms.curvature);

    // Check if we're outside the distorted screen bounds (black borders)
    if (distorted_uv.x < 0.0 || distorted_uv.x > 1.0 ||
        distorted_uv.y < 0.0 || distorted_uv.y > 1.0) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    // ── 2. Sample the rendered frame with chromatic aberration ──────────
    // Separate RGB channels slightly for authentic CRT color fringing
    float2 r_uv = distorted_uv - float2(uniforms.chromatic_aberration, 0.0);
    float2 g_uv = distorted_uv;
    float2 b_uv = distorted_uv + float2(uniforms.chromatic_aberration, 0.0);

    float r = rendered_frame.sample(frame_sampler, r_uv).r;
    float g = rendered_frame.sample(frame_sampler, g_uv).g;
    float b = rendered_frame.sample(frame_sampler, b_uv).b;

    float3 color = float3(r, g, b);

    // ── 3. Add phosphor glow / bloom ────────────────────────────────────
    if (uniforms.glow_strength > 0.0) {
        float3 bloom = glow(rendered_frame, frame_sampler, distorted_uv, uniforms.glow_strength);
        color += bloom;
    }

    // ── 4. Apply scanlines ──────────────────────────────────────────────
    float scanline_factor = scanlines(distorted_uv, uniforms.viewport_height, uniforms.scanline_intensity);
    color *= scanline_factor;

    // ── 5. Apply vignette ───────────────────────────────────────────────
    float vignette_factor = vignette(uv, uniforms.vignette_strength);
    color *= vignette_factor;

    // ── 6. Add subtle film grain / noise ────────────────────────────────
    float grain = noise(uv * uniforms.viewport_width, uniforms.time);
    color += (grain - 0.5) * 0.02;

    // ── 7. Subtle flicker (very gentle, like power fluctuation) ─────────
    float flicker = 1.0 + sin(uniforms.time * 120.0) * 0.005;
    color *= flicker;

    // ── 8. Ensure we don't exceed 1.0 (bloom can brighten things) ──────
    color = saturate(color);

    return float4(color, 1.0);
}

// ─── Simple Vertex Shader (for testing without attributes) ─────────────────

vertex VertexOut crt_vertex_simple(
    uint vertex_id [[vertex_id]]
) {
    // Fullscreen triangle (covers -1..1 NDC space)
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };

    float2 texcoords[3] = {
        float2(0.0, 1.0),
        float2(2.0, 1.0),
        float2(0.0, -1.0)
    };

    VertexOut out;
    out.position = float4(positions[vertex_id], 0.0, 1.0);
    out.texcoord = texcoords[vertex_id];
    return out;
}
