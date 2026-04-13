#if ENABLE_SCENE
import Foundation

extension SceneEngine {
    static let metalShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct QuadUniforms {
        float uMin, uMax, vMin, vMax, alpha;
    };

    struct QuadVertexOut {
        float4 position [[position]];
        float2 uv;
        float alpha;
    };

    vertex QuadVertexOut quadVertex(uint vid [[vertex_id]],
                                     constant QuadUniforms &u [[buffer(0)]]) {
        float2 pos[4] = { {-1,-1}, {1,-1}, {-1,1}, {1,1} };
        float2 uv[4] = { {u.uMin, u.vMax}, {u.uMax, u.vMax}, {u.uMin, u.vMin}, {u.uMax, u.vMin} };
        QuadVertexOut out;
        out.position = float4(pos[vid], 0, 1);
        out.uv = uv[vid];
        out.alpha = u.alpha;
        return out;
    }

    fragment float4 quadFragment(QuadVertexOut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]],
                                  sampler s [[sampler(0)]]) {
        float4 c = tex.sample(s, in.uv);
        c.a *= in.alpha;
        return c;
    }

    // --- Particles ---

    struct ParticleVertexOut {
        float4 position [[position]];
        float4 color;
        float pointSize [[point_size]];
        float softness;
    };

    struct ParticleVertexIn {
        float2 position;
        float4 color;
        float size;
        float softness;
    };

    vertex ParticleVertexOut particleVertex(uint vid [[vertex_id]],
                                            constant ParticleVertexIn *particles [[buffer(0)]],
                                            constant float2 &viewSize [[buffer(1)]]) {
        ParticleVertexOut out;
        float2 ndc = particles[vid].position / viewSize * 2.0 - 1.0;
        ndc.y = -ndc.y;
        out.position = float4(ndc, 0, 1);
        out.color = particles[vid].color;
        out.pointSize = particles[vid].size;
        out.softness = particles[vid].softness;
        return out;
    }

    fragment float4 particleFragment(ParticleVertexOut in [[stage_in]],
                                      float2 pointCoord [[point_coord]]) {
        float dist = length(pointCoord - 0.5) * 2.0;
        float alpha;
        if (in.softness > 0.5) {
            alpha = 1.0 - smoothstep(0.0, 1.0, dist);
            alpha *= alpha;
        } else {
            alpha = 1.0 - smoothstep(0.8, 1.0, dist);
        }
        return float4(in.color.rgb, in.color.a * alpha);
    }

    // --- Effects ---

    struct EffectUniforms {
        float time, strength, speed, scale, ratio;
        float scrollSpeed, scrollDirection;
        float texWidth, texHeight;
    };

    struct EffectVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex EffectVertexOut effectVertex(uint vid [[vertex_id]]) {
        float2 pos[4] = { {-1,-1}, {1,-1}, {-1,1}, {1,1} };
        float2 uv[4] = { {0,1}, {1,1}, {0,0}, {1,0} };
        EffectVertexOut out;
        out.position = float4(pos[vid], 0, 1);
        out.uv = uv[vid];
        return out;
    }

    fragment float4 waterRippleFragment(EffectVertexOut in [[stage_in]],
                                         constant EffectUniforms &u [[buffer(0)]],
                                         texture2d<float> fb [[texture(0)]],
                                         texture2d<float> mask [[texture(1)]],
                                         texture2d<float> normal [[texture(2)]],
                                         sampler s [[sampler(0)]]) {
        float2 uv = in.uv;
        float m = mask.sample(s, uv).r;
        float asp = u.texWidth / u.texHeight;
        float animSp = u.speed * u.speed;
        float2 scroll = float2(sin(u.scrollDirection), cos(u.scrollDirection)) * u.scrollSpeed * u.scrollSpeed * u.time;
        float2 r1 = (uv + u.time * animSp + scroll) * u.scale;
        float2 r2 = (uv * 1.333 - u.time * animSp + scroll) * u.scale;
        r1.x *= asp; r2.x *= asp; r1.y *= u.ratio; r2.y *= u.ratio;
        float3 n1 = normal.sample(s, r1).xyz * 2.0 - 1.0;
        float3 n2 = normal.sample(s, r2).xyz * 2.0 - 1.0;
        float2 n = normalize(float3(n1.xy + n2.xy, n1.z)).xy;
        uv += n * u.strength * u.strength * m;
        return fb.sample(s, uv);
    }

    fragment float4 waterFlowFragment(EffectVertexOut in [[stage_in]],
                                       constant EffectUniforms &u [[buffer(0)]],
                                       texture2d<float> fb [[texture(0)]],
                                       texture2d<float> flow [[texture(1)]],
                                       texture2d<float> phase [[texture(2)]],
                                       sampler s [[sampler(0)]]) {
        float2 uv = in.uv;
        float fp = phase.sample(s, uv).r - 0.5;
        float2 fc = flow.sample(s, uv).rg;
        float2 fm = (fc - float2(0.498)) * 2.0;
        float fa = length(fm);
        float c1 = fract(u.time * u.speed);
        float c2 = fract(u.time * u.speed + 0.5);
        float bl = 2.0 * abs(c1 - 0.5);
        bl = smoothstep(max(0.0, fp), min(1.0, 1.0 + fp), bl);
        float2 o1 = fm * u.strength * 0.1 * c1;
        float2 o2 = fm * u.strength * 0.1 * c2;
        float4 a = fb.sample(s, uv);
        float4 f = mix(fb.sample(s, uv + o1), fb.sample(s, uv + o2), bl);
        return mix(a, f, fa);
    }

    fragment float4 bloomFragment(EffectVertexOut in [[stage_in]],
                                   constant EffectUniforms &u [[buffer(0)]],
                                   texture2d<float> fb [[texture(0)]],
                                   sampler s [[sampler(0)]]) {
        // Simple bloom: extract bright pixels, blur, add back
        float4 c = fb.sample(s, in.uv);
        float brightness = dot(c.rgb, float3(0.299, 0.587, 0.114));
        float bloom = max(0.0, brightness - u.strength) * u.speed; // strength=threshold, speed=intensity
        return float4(c.rgb * (1.0 + bloom * 0.5), c.a);
    }
    """
}
#endif
