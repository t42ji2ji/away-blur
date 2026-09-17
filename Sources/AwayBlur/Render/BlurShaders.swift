import Foundation

/// One full-screen pass over the frozen picture.
///
/// The picture carries a Gaussian pyramid, so a blur of any radius costs the
/// same: pick the mip level that already holds that much blur, then hide the
/// steps between levels with a 3x3 tent of trilinear taps. That is what makes
/// a radius ramp affordable at display refresh rate.
enum BlurShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 frame;   // drawable size (px), max radius (px), max mip level
        float4 look;    // blur 0-1, dim 0-1, wash 0-1, grain 0-1
        float4 misc;    // time, unused
        float4 cover;   // fraction of the texture the screen occupies
        float4 stamp;   // origin (px), cell size (px), alpha
        float4 grid;    // columns, rows
        float4 caption; // origin (px), cell size (px), alpha
        float4 line;    // columns, rows
    };

    // A one-bit stamp laid on the picture: whole pixels per cell, whole pixels
    // of position, nearest sampling. All three, or it goes soft.
    static inline float3 lay(float3 colour, float2 position, float4 place, float2 grid,
                             texture2d<float> art, sampler blocky, float3 tone) {
        if (place.w <= 0.001) { return colour; }
        float2 span = grid * place.z;
        float2 local = position - place.xy;
        if (any(local < 0.0) || any(local >= span)) { return colour; }
        float ink = art.sample(blocky, local / span).r;
        return mix(colour, tone, ink * place.w);
    }

    vertex float4 fullScreenVertex(uint id [[vertex_id]]) {
        const float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        return float4(corners[id], 0.0, 1.0);
    }

    static inline float hash(float2 p) {
        return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
    }

    fragment float4 blurFragment(float4 position [[position]],
                                 constant Uniforms &u [[buffer(0)]],
                                 texture2d<float> picture [[texture(0)]],
                                 texture2d<float> stamp [[texture(1)]],
                                 texture2d<float> caption [[texture(2)]]) {
        constexpr sampler smooth(filter::linear, mip_filter::linear, address::clamp_to_edge);
        // Nearest, always. A pixel is a square and it stays a square.
        constexpr sampler blocky(filter::nearest, address::clamp_to_edge);

        const float2 frameSize = u.frame.xy;
        const float  maxRadius = u.frame.z;
        const float  maxLevel  = u.frame.w;
        const float  blur      = u.look.x;
        const float  dim       = u.look.y;
        const float  wash      = u.look.z;
        const float  grain     = u.look.w;
        const float  time      = u.misc.x;
        const float2 cover     = u.cover.xy;

        float2 texCoord = (position.xy / frameSize) * cover;

        float radius = blur * maxRadius;
        // Naming this `level` would shadow Metal's level() selector.
        float mip = clamp(log2(max(radius, 1.0)), 0.0, maxLevel);

        float3 colour;
        if (radius < 0.75) {
            colour = picture.sample(smooth, texCoord, level(0.0)).rgb;
        } else {
            float2 stride = ((radius * 0.45) / frameSize) * cover;
            const float weights[3] = { 1.0, 2.0, 1.0 };
            colour = float3(0.0);
            for (int y = -1; y <= 1; y++) {
                for (int x = -1; x <= 1; x++) {
                    float w = weights[x + 1] * weights[y + 1] / 16.0;
                    colour += picture.sample(smooth, texCoord + float2(x, y) * stride, level(mip)).rgb * w;
                }
            }
        }

        // Wash towards the picture's own average colour (the top of the
        // pyramid), so the screen reads as lit glass rather than a soft photo.
        if (wash > 0.0005) {
            float3 average = picture.sample(smooth, cover * 0.5, level(maxLevel)).rgb;
            colour = mix(colour, average, wash);
        }

        // Sinking towards black. The values here are what the screen shows,
        // not light, so the fall does not need a curve on top.
        colour *= 1.0 - dim;

        // The cat and its line. Dark on a light screen, light on a dark one,
        // decided once from the picture's own average rather than per pixel,
        // so neither breaks up over a busy background.
        if (u.stamp.w > 0.001 || u.caption.w > 0.001) {
            float3 average = picture.sample(smooth, cover * 0.5, level(maxLevel)).rgb;
            float lit = dot(average, float3(0.299, 0.587, 0.114));
            float3 tone = lit > 0.5 ? float3(0.06) : float3(0.93);
            colour = lay(colour, position.xy, u.stamp, u.grid.xy, stamp, blocky, tone);
            colour = lay(colour, position.xy, u.caption, u.line.xy, caption, blocky, tone);
        }

        // Grain, so a wide dark gradient does not band on an 8-bit panel.
        if (grain > 0.0005) {
            float noise = hash(position.xy + fract(time) * 17.0) - 0.5;
            colour += noise * grain * (2.5 / 255.0);
        }

        return float4(max(colour, 0.0), 1.0);
    }
    """
}
