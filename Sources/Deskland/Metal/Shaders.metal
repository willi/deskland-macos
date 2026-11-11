#include <metal_stdlib>
using namespace metal;

constexpr sampler sRepeatMip(coord::normalized, address::repeat, filter::linear, mip_filter::linear);
constexpr sampler sClampLinear(coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler sClampMip(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);

struct FullscreenOut {
    float4 position [[position]];
};

vertex FullscreenOut fullscreenVertex(uint vid [[vertex_id]]) {
    FullscreenOut out;
    float2 uv = float2((vid << 1) & 2, vid & 2);
    out.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

inline float dlHash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

inline float dlHash2(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

inline float ss(float a, float b, float x) {
    float t = clamp((x - a) / (b - a), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

inline float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

inline float2 rot2D(float2 v, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}

inline float segSD(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-5), 0.0, 1.0);
    return length(pa - ba * h);
}

inline float fieldSample(texture2d<float> tex, float2 p, float stepSize, float2 grid) {
    return tex.sample(sClampLinear, (p / stepSize + 0.5) / grid).r;
}

struct BeachUniforms {
    float4 resAndGrid;
    float4 core;
    float4 wave0;
    float4 wave1;
    float4 counts;
    float4 solar;

    float4 sea0, sea1, sea2, sea3, sea4;
    float4 sand0, sand1, sand2, sand3;
    float4 wetSand, foam, sparkColor;
    float4 bed0, bed1, shoalTint0, shoalTint1, palmTint;

    float4 kayaks[4];
    float4 ripples[6];
    float4 birds[8];
};

struct PalmInstanceUniforms {
    float4 palm;
    float4 extra;
};

inline float3 seaRamp(float v, constant BeachUniforms& u) {
    v = clamp(v, 0.0, 1.0) * 4.0;
    if (v < 1.0) return mix(u.sea0.rgb, u.sea1.rgb, v);
    if (v < 2.0) return mix(u.sea1.rgb, u.sea2.rgb, v - 1.0);
    if (v < 3.0) return mix(u.sea2.rgb, u.sea3.rgb, v - 2.0);
    return mix(u.sea3.rgb, u.sea4.rgb, v - 3.0);
}

inline float3 sandRamp(float v, constant BeachUniforms& u) {
    v = clamp(v, 0.0, 1.0) * 3.0;
    if (v < 1.0) return mix(u.sand0.rgb, u.sand1.rgb, v);
    if (v < 2.0) return mix(u.sand1.rgb, u.sand2.rgb, v - 1.0);
    return mix(u.sand2.rgb, u.sand3.rgb, v - 2.0);
}

inline float2 worley(float2 p, float seed) {
    float2 i = floor(p), f = fract(p);
    float d1 = 8.0, d2 = 8.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 g = float2(float(x), float(y)), c = i + g;
            float2 r = g + float2(dlHash(c + seed), dlHash(c + seed + 17.3)) * 0.8 + 0.1 - f;
            float d = dot(r, r);
            if (d < d1) { d2 = d1; d1 = d; }
            else if (d < d2) { d2 = d; }
        }
    }
    return float2(sqrt(d1), sqrt(d2));
}

inline float hullSD(float2 q) {
    float L = 22.0, Wd = 5.4;
    float t = clamp(q.x / L, -1.0, 1.0);
    float w = Wd * (1.0 - t * t);
    return max(abs(q.y) - w, abs(q.x) - L);
}

inline float2 paddleSD(float2 q, float ph) {
    float a = 1.5708 + sin(ph) * 0.55;
    float2 dir = float2(cos(a), sin(a)), c = float2(0.5, 0.0);
    float shaft = segSD(q, c - dir * 13.0, c + dir * 13.0) - 0.7;
    float2 l1 = rot2D(q - (c + dir * 13.5), -a);
    float2 l2 = rot2D(q - (c - dir * 13.5), -a);
    float blade = min(length(l1 / float2(3.6, 1.6)) - 1.0, length(l2 / float2(3.6, 1.6)) - 1.0) * 1.6;
    return float2(shaft, blade);
}

inline float3 gullSD(float2 q, float span) {
    float body = (length((q - float2(0.8, 0.0)) / float2(6.2, 1.9)) - 1.0) * 1.9;
    float tail = max(abs(q.y) - 1.4 - (-q.x - 4.0) * 0.25, max(-q.x - 8.5, q.x + 4.0));
    float y = abs(q.y), reach = 15.0 * span;
    float u = clamp((y - 1.0) / max(reach, 0.001), 0.0, 1.0);
    float lead = 1.0 + 1.3 * sin(u * 3.14159) - 4.0 * u * u;
    float chord = mix(4.4, 1.3, u);
    float wing = max(max(q.x - lead, lead - chord - q.x), y - reach - 1.0);
    return float3(min(body, tail), wing, u);
}

fragment float4 beachFragment(
    FullscreenOut in [[stage_in]],
    constant BeachUniforms& u [[buffer(0)]],
    texture2d<float> texNoise [[texture(0)]],
    texture2d<float> texFA [[texture(1)]],
    texture2d<float> texFB [[texture(2)]]
) {
    float2 uGrid = u.resAndGrid.zw;
    float uScale = u.core.x;
    float uSeed  = u.core.y;
    float uStep  = u.core.z;
    float uMix   = u.core.w;

    float t        = u.wave0.x;
    float uSpeed   = u.wave0.y;
    float uRunup   = u.wave0.z;
    float wv       = u.wave0.w;

    float lam      = u.wave1.x;
    float uSigma   = u.wave1.y;
    float uShallow = u.wave1.z;
    float uShoal   = u.wave1.w;

    float gAmt     = u.counts.x;
    float uDebug   = u.counts.y;
    int kayN       = int(u.counts.z + 0.5);
    int birdN      = int(u.counts.w + 0.5);

    float sunsetW  = u.solar.x;
    float nightW   = u.solar.y;

    float2 p = in.position.xy / uScale;
    float2 gp = floor(p * (0.78 * max(uScale, 1.0)));
    float g1 = dlHash2(gp + 0.5), g2 = dlHash2(gp + 7.3);

    auto N = [&](float2 pt, float sc) -> float4 {
        return texNoise.sample(sRepeatMip, pt / sc + uSeed * 0.013);
    };
    auto SF = [&](float2 pt) -> float {
        return mix(fieldSample(texFA, pt, uStep, uGrid), fieldSample(texFB, pt, uStep, uGrid), uMix);
    };

    float s0 = SF(p);
    float s = s0 + (N(p, 700.0).r - 0.5) * 10.0;

    float along = N(p, 4200.0).b * 1.2;
    float uPhase = t * uSpeed / lam + along;
    float fu = fract(uPhase), cyc = floor(uPhase);

    float2 gr = float2(dfdx(s0), dfdy(s0));
    float2 nrm = length(gr) > 1e-4 ? normalize(gr) : float2(0.0, 1.0);
    float sIn = SF(p - nrm * 45.0);
    float sOut = SF(p + nrm * 70.0);
    float energy = mix(ss(2.0, -18.0, sIn), 1.0, ss(15.0, 40.0, s)) * ss(25.0, 70.0, sOut);

    float shoreE = 0.0, sW = s;
    if (s < 4.0 && s > -uSigma * 0.78 - 12.0) {
        float fR = SF(p + float2(10.0, 0.0)), fL = SF(p - float2(10.0, 0.0));
        float fD = SF(p + float2(0.0, 10.0)), fU = SF(p - float2(0.0, 10.0));
        float2 g10 = float2(fR - fL, fD - fU);
        float2 n10 = length(g10) > 1e-3 ? normalize(g10) : nrm;
        float2 sp = p - n10 * s0;
        float eIn = SF(sp - n10 * 45.0), eOut = SF(sp + n10 * 70.0);
        shoreE = ss(2.0, -18.0, eIn) * ss(25.0, 70.0, eOut);
        sW = mix(s, (fR + fL + fD + fU) * 0.25 + (s - s0), ss(-2.0, -16.0, s));
    }

    float3 col;
    if (s > 2.0) {
        float depth = pow(clamp(max(s - uShoal * 0.45, 0.0) / (uShallow * 1.3), 0.0, 1.0), 0.62);
        col = seaRamp(depth + (g1 - 0.5) * 0.09 * gAmt, u);

        float2 drift = float2(t * 2.2, t * 0.9);
        float deepK = ss(uShallow * 0.35, uShallow * 1.1, s);
        col *= 1.0 + (N(p + drift * 4.0, 1600.0).r - 0.5) * 0.07 * ss(0.0, uShoal + 40.0, s);

        float glitterBoost = 1.0 + sunsetW * 0.45 - nightW * 0.25;
        float glitter = ss(0.32, 0.72, N(p + drift * 3.0, 520.0).g) * deepK * glitterBoost;
        float spark = 0.0;
        for (int L = 0; L < 2; L++) {
            float fl = float(L), cs = L == 0 ? 23.0 : 37.0;
            float2 q = rot2D(p, L == 0 ? 0.62 : -1.13) / cs + fl * 17.3;
            float2 cell = floor(q), f = fract(q);
            float2 seedc = cell + fl * 51.7 + uSeed * 0.1;
            if (dlHash2(seedc) > (L == 0 ? 0.11 : 0.16) * glitter) continue;
            float2 c = 0.15 + 0.7 * float2(dlHash2(seedc + 1.3), dlHash2(seedc + 2.9));
            float life = fract(t * (0.3 + 0.35 * dlHash2(seedc + 8.1)) + dlHash2(seedc + 5.7));
            float tw = ss(0.0, 0.1, life) * (1.0 - ss(0.2, 0.45, life));
            float r = (0.7 + 0.9 * dlHash2(seedc + 3.3)) * (1.0 + sunsetW * 0.22);
            spark = max(spark, (1.0 - ss(r * 0.5, r * 1.5, length((f - c) * cs))) * tw);
        }
        col = mix(col, u.sparkColor.rgb, spark * (0.85 + sunsetW * 0.12));

        float k = clamp(ss(uShoal * 0.15, uShoal * 1.25, s) + (g2 - 0.5) * 0.16 * gAmt, 0.0, 1.0);
        if (k < 1.0 && uShoal > 0.5) {
            float3 bed = mix(u.bed0.rgb, u.bed1.rgb, ss(0.0, uShoal, s));
            float3 tint = mix(u.shoalTint0.rgb, u.shoalTint1.rgb, ss(0.0, uShoal * 0.9, s));
            col = mix(bed * tint, col, k);
        }
        col = mix(col, mix(sandRamp((g1 - 0.5) * 0.1 * gAmt, u), u.wetSand.rgb, 0.6), 1.0 - ss(2.0, 38.0, s));

        float shadow = 0.0;
        float2 kShadowOff = float2(8.0 + sunsetW * 5.0, 13.0 + sunsetW * 4.0);
        for (int i = 0; i < 4; i++) {
            if (i >= kayN) break;
            float4 ky = u.kayaks[i];
            float2 q2 = rot2D(p - ky.xy - kShadowOff, -ky.z);
            float sd = hullSD(q2);
            float2 pd = paddleSD(q2, ky.w);
            shadow = max(shadow, ss(1.6, -1.6, min(sd, min(pd.x, pd.y))));
        }
        col = mix(col, col * float3(0.62, 0.78, 0.84), shadow * (0.7 - nightW * 0.25));

        float rip = 0.0;
        for (int i = 0; i < 6; i++) {
            float4 r = u.ripples[i];
            if (r.w <= 0.0) continue;
            float dist = length(p - r.xy), rad = r.z * 80.0;
            rip = max(rip, (1.0 - ss(0.8, 2.0, abs(dist - rad))) * exp(-r.z * 1.4) * r.w);
            rip = max(rip, (1.0 - ss(0.6, 1.6, abs(dist - rad * 0.6))) * exp(-r.z * 1.8) * r.w * 0.6);
        }
        col = mix(col, u.foam.rgb, step(g2, rip * 0.95));

        float dd = s - 2.0;
        float ph = (s + t * uSpeed) / lam + along;
        float fr = fract(ph);
        float dpx = min(fr, 1.0 - fr) * lam;
        float vis = (1.0 - ss(lam * 0.45, lam * 1.35, s)) * ss(0.0, 4.0, dd) * energy;
        float brk = 1.0 - ss(8.0, 55.0, s);
        float cw = wv * (1.0 + 0.8 * brk);
        float crest = (1.0 - ss(0.7 * cw, 1.9 * cw, dpx)) * vis * (0.55 + 0.4 * brk);
        float crestSpray = exp(-fr * lam / (7.0 * cw)) * vis * (0.25 + 0.4 * brk);
        float burst = exp(-fu * 4.5) * ss(0.0, 0.04, fu);
        float spray = exp(-dd / (6.0 * wv)) * burst * energy * 0.45;
        float foam = max(crest, step(g2, max(spray, crestSpray)));
        col = mix(col, u.foam.rgb, foam * (1.0 - nightW * 0.15));
    } else {
        float wet = ss(-7.0 - 3.0 * shoreE, 1.0, s) * 0.2;
        col = mix(sandRamp((g1 - 0.5) * 0.1 * gAmt, u), u.wetSand.rgb, wet * 3.0);
        col *= 1.0 - 0.03 * ss(0.4, 0.8, N(p, 900.0).r) * (1.0 - wet);
    }

    float reachBase = min(uRunup * 0.25 * shoreE * (0.85 + 0.3 * N(p, 900.0).g), uSigma * 0.78);
    float wk = (1.0 - ss(2.0, 38.0, s)) * mix(1.0, energy, ss(2.0, 10.0, s));
    if ((s < 4.0 && reachBase > 0.5) || (s >= 4.0 && wk > 0.01)) {
        float3 FILM = u.wetSand.rgb, MARK = u.wetSand.rgb * 0.97;
        float onSand = step(s, 4.0);
        float2 wl = worley((p - nrm * fu * 8.0) / 7.0, uSeed);
        float laceNet = (1.0 - ss(0.03, 0.1, wl.y - wl.x)) * ss(0.4, 0.62, N(p + float2(t * 2.0, 0.0), 120.0).g);
        float wetMem = 0.0, filmA = 0.0;
        float4 layers[3];
        for (int j = 0; j < 3; j++) {
            float a = fu + float(j);
            float amp = reachBase * (0.5 + 0.5 * dlHash(float2(cyc - float(j), 3.7)));
            float front = a < 0.45 ? mix(3.0, -amp, 1.0 - pow(1.0 - a / 0.45, 2.2))
                                   : mix(-amp, 3.0, ss(0.45, 1.4, a));
            float reached = ss(-amp - 4.0, -amp + 12.0, sW);
            wetMem = max(wetMem, reached * (1.0 - ss(0.45, 2.8, a)) * ss(0.2, 0.45, a));
            float alpha = a < 0.45 ? 0.42 : 0.42 * (1.0 - ss(0.45, 1.4, a));
            float feather = 1.0 + 16.0 * ss(0.45, 1.1, a);
            filmA = max(filmA, ss(front - 1.0, front + feather, sW) * alpha * 1.6);
            layers[j] = float4(front, a, amp, feather);
        }
        col = mix(col, MARK, wetMem * 0.18 * wk);
        col = mix(col, mix(col * float3(0.98, 0.96, 0.90), FILM, 0.6), filmA * wk);
        for (int j = 2; j >= 0; j--) {
            float front = layers[j].x, a = layers[j].y;
            float cov = ss(front - 1.0, front + layers[j].w, sW);
            float lace = laceNet * cov * ss(0.4, 0.6, a) * (1.0 - ss(0.7, 1.4, a)) * wk;
            col = mix(col, u.foam.rgb, lace * 0.75 * (1.0 - nightW * 0.2));
            float edgeK = a < 0.45 ? 1.0 : 1.0 - ss(0.45, 1.05, a);
            float d = sW - front;
            float lineE = (1.0 - ss(0.8 * wv, 1.9 * wv, abs(d - 0.9 * wv))) * edgeK * onSand;
            float sprayE = exp(-max(d, 0.0) / (5.0 * wv)) * cov * edgeK * 0.5 * onSand;
            col = mix(col, u.foam.rgb, max(lineE * 0.95, step(g1, sprayE)) * (1.0 - nightW * 0.15));
        }
    }

    float3 actorLight = u.palmTint.rgb;

    for (int i = 0; i < 4; i++) {
        if (i >= kayN) break;
        float4 ky = u.kayaks[i];
        float2 q = rot2D(p - ky.xy, -ky.z);
        if (dot(q, q) > 900.0) continue;
        float sd = hullSD(q);
        float2 pd = paddleSD(q, ky.w);
        float3 kc = col;
        float mh = ss(0.7, -0.7, sd);
        if (mh > 0.0) {
            float tt = clamp(q.x / 22.0, -1.0, 1.0);
            float wd = 5.4 * (1.0 - tt * tt);
            float3 hull = mix(float3(0.99, 0.84, 0.16), float3(1.0, 0.93, 0.45), 1.0 - ss(0.2, 0.7, abs(q.y) / max(wd, 0.5)));
            hull = mix(hull, float3(0.90, 0.64, 0.10), ss(0.78, 1.0, abs(q.y) / max(wd, 0.5)));
            hull = mix(hull, float3(0.97, 0.96, 0.90), 1.0 - ss(1.0, 1.6, length(q - float2(13.0, 0.0))));
            hull = mix(hull, float3(0.97, 0.96, 0.90), 1.0 - ss(1.0, 1.6, length(q - float2(-12.0, 0.0))));
            hull = mix(hull, float3(0.30, 0.24, 0.20), 1.0 - ss(0.0, 0.6, length((q - float2(-1.0, 0.0)) / float2(6.0, 2.8)) - 1.0));
            kc = mix(kc, hull * actorLight, mh);
        }
        float body = ss(0.5, -0.5, length(q - float2(-1.5, 0.0)) - 3.3);
        kc = mix(kc, float3(0.96, 0.55, 0.18) * actorLight, body);
        float head = ss(0.5, -0.5, length(q - float2(0.2, 0.0)) - 2.0);
        kc = mix(kc, float3(0.22, 0.17, 0.16) * actorLight, head);
        float sh = ss(0.5, -0.5, pd.x), bl = ss(0.5, -0.5, pd.y);
        kc = mix(kc, float3(0.28, 0.24, 0.26) * actorLight, sh);
        kc = mix(kc, float3(0.90, 0.28, 0.22) * actorLight, bl);
        col = kc;
    }

    float2 gullShadowOff = float2(34.0 + sunsetW * 16.0, 55.0 + sunsetW * 12.0);
    for (int i = 0; i < 8; i++) {
        if (i >= birdN) break;
        float4 b = u.birds[i];
        float2 d0 = p - b.xy, d1 = d0 - gullShadowOff;
        if (dot(d1, d1) < 400.0) {
            float3 g = gullSD(rot2D(d1, -b.z), b.w);
            col = mix(col, col * float3(0.70, 0.74, 0.84), ss(1.8, -1.8, min(g.x, g.y)) * (0.28 - nightW * 0.16));
        }
        if (dot(d0, d0) < 400.0) {
            float3 g = gullSD(rot2D(d0, -b.z), b.w);
            float3 wingC = mix(float3(0.80, 0.84, 0.88), float3(0.20, 0.22, 0.26), ss(0.72, 0.80, g.z)) * actorLight;
            col = mix(col, wingC, ss(0.6, -0.6, g.y));
            col = mix(col, float3(0.99, 0.99, 0.98) * actorLight, ss(0.6, -0.6, g.x));
            col = mix(col, float3(0.98, 0.78, 0.22) * actorLight, ss(0.5, -0.5, length(rot2D(d0, -b.z) - float2(7.2, 0.0)) - 0.9));
        }
    }

    if (uDebug > 0.5) {
        col = mix(col, float3(0.9, 0.15, 0.15), 1.0 - ss(0.0, 1.5, abs(s0)));
    }
    col *= 1.0 + (g2 - 0.5) * 0.035 * gAmt;
    return float4(col, 1.0);
}

struct PalmVertOut {
    float4 position [[position]];
    float2 palmUV;
};

vertex PalmVertOut palmVertex(
    uint vid [[vertex_id]],
    constant BeachUniforms& u [[buffer(0)]],
    constant PalmInstanceUniforms& pu [[buffer(1)]]
) {
    PalmVertOut out;
    float2 corner = float2(float(vid & 1), float(vid >> 1));
    float2 local = corner * float2(224.0, 256.0) - float2(112.0, 162.0);
    local.x *= pu.extra.x;
    float a = sin(u.wave0.x * 0.65 + pu.palm.w * 2.0) * 0.008;
    local = rot2D(local, a);
    float2 p = pu.palm.xy + local * pu.palm.z;
    float2 res = u.resAndGrid.xy;
    out.position = float4(p.x / res.x * 2.0 - 1.0, 1.0 - p.y / res.y * 2.0, 0.0, 1.0);
    out.palmUV = float2((corner.x + pu.palm.w) / max(pu.extra.z, 1.0), corner.y);
    return out;
}

fragment float4 palmFragment(
    PalmVertOut in [[stage_in]],
    constant BeachUniforms& u [[buffer(0)]],
    constant PalmInstanceUniforms& pu [[buffer(1)]],
    texture2d<float> texPalmAtlas [[texture(0)]]
) {
    float4 tree = texPalmAtlas.sample(sClampMip, in.palmUV);
    if (tree.a < 0.002) discard_fragment();

    float2 p = in.position.xy / u.core.x;
    int birdN = int(u.counts.w + 0.5);
    for (int i = 0; i < 8; i++) {
        if (i >= birdN) break;
        float4 b = u.birds[i];
        float2 q = rot2D(p - b.xy, -b.z);
        if (dot(q, q) < 400.0) {
            float3 bird = gullSD(q, b.w);
            if (min(bird.x, bird.y) < 0.6) discard_fragment();
        }
    }
    float alpha = tree.a * pu.extra.y;
    float3 rgb = tree.rgb * u.palmTint.rgb;
    return float4(rgb * alpha, alpha);
}

constant int CIRC_K = 36;

struct MeadowUniforms {
    float4 resAndGrid;
    float4 core;
    float4 params;
    float4 gridInfo;
    float4 lighting;
    float4 solar;

    float4 actorRect;
    float4 catRect;
    float4 catExtra;

    float4 grassLight;
    float4 grassMid;
    float4 grassDeep;
    float4 grassInk;
    float4 shadowTint;
    float4 cloudHi;
    float4 cloudBody;
    float4 cloudShade;
};

inline float cloudDistEval(
    float2 q,
    bool findFront,
    thread float4& fc,
    constant MeadowUniforms& u,
    texture2d<float> texFA,
    texture2d<float> texFB,
    texture2d<float, access::read> texCirc
) {
    float2 uGrid = u.resAndGrid.zw;
    float uStep = u.core.z;
    float uMix = u.core.w;
    float uEdge = u.params.y;
    float uCellG = u.params.w;
    int cgW = int(u.gridInfo.x + 0.5);
    int cgH = int(u.gridInfo.y + 0.5);

    float sF = mix(fieldSample(texFA, q, uStep, uGrid), fieldSample(texFB, q, uStep, uGrid), uMix);
    float d = sF - uEdge + 0.6 * 95.0;
    int2 cell = int2(floor(q / uCellG)) + 4;
    if (cell.x < 0 || cell.y < 0 || cell.x >= cgW || cell.y >= cgH) return d;

    for (int k = 0; k < CIRC_K; k++) {
        float4 c = texCirc.read(uint2(uint(cell.x * CIRC_K + k), uint(cell.y)));
        if (c.z <= 0.0) break;
        float di = length(q - c.xy) - c.z;
        d = smin(d, di, 6.0);
        if (findFront && di < 0.0 && c.y > fc.y) fc = c;
    }
    return d;
}

inline float grassInkPattern(float2 p, float uSeed, texture2d<float> texNoise) {
    const float2 G = float2(12.0, 6.0);
    float2 c0 = floor(p / G);
    float ink = 0.0;
    for (int j = -1; j <= 1; j++) {
        float2 c = c0 + float2(0.0, float(j));
        float2 cp = (c + 0.5) * G;
        float h = dlHash2(c + 3.1);
        float4 n1 = texNoise.sample(sRepeatMip, cp / 900.0 + uSeed * 0.013);
        float4 n2 = texNoise.sample(sRepeatMip, (cp + 50.0) / 380.0 + uSeed * 0.013);
        float dens = 0.75 * ss(0.42, 0.72, n1.r) * ss(0.35, 0.60, n2.g) + 0.02;
        if (h > dens) continue;
        float4 n3 = texNoise.sample(sRepeatMip, cp / 1400.0 + uSeed * 0.013);
        float ang = (n3.g - 0.5) * 0.7 + (dlHash2(c + 7.7) - 0.5) * 0.3;
        float len = 2.5 + 3.0 * dlHash2(c + 1.9);
        float2 ctr = cp + (float2(dlHash2(c + 4.3), dlHash2(c + 5.9)) - 0.5) * float2(2.0, 3.0);
        float2 dir = float2(cos(ang), sin(ang)) * len;
        float d = segSD(p, ctr - dir, ctr + dir);
        ink = max(ink, (1.0 - ss(0.2, 0.9, d)) * (0.35 + 0.45 * dlHash2(c + 9.1)));
    }
    return ink;
}

inline float catTailMask(float2 uv) {
    return smoothstep(0.635, 0.665, uv.x) * smoothstep(0.715, 0.750, uv.y);
}

inline float4 evalCatColor(float2 uv, float tailAngle, texture2d<float> texCat) {
    float2 pivot = float2(0.68, 0.73), delta = uv - pivot;
    float angle = -tailAngle * smoothstep(0.025, 0.16, length(delta));
    float c = cos(angle), s = sin(angle);
    float2 source = pivot + float2(c * delta.x - s * delta.y, s * delta.x + c * delta.y);
    float4 body = texCat.sample(sClampMip, clamp(uv, 0.0, 1.0), level(0.5));
    float4 tail = texCat.sample(sClampMip, clamp(source, 0.0, 1.0), level(0.5));
    body.a *= 1.0 - catTailMask(uv);
    tail.a *= catTailMask(source);
    float borderFade = smoothstep(0.0, 0.03, uv.x) * smoothstep(0.0, 0.03, uv.y) *
                       smoothstep(0.0, 0.03, 1.0 - uv.x) * smoothstep(0.0, 0.03, 1.0 - uv.y);
    float alpha = (body.a + tail.a) * borderFade;
    return float4((body.rgb * body.a + tail.rgb * tail.a) / max(body.a + tail.a, 0.001), min(alpha, 1.0));
}

fragment float4 meadowFragment(
    FullscreenOut in [[stage_in]],
    constant MeadowUniforms& u [[buffer(0)]],
    texture2d<float> texNoise [[texture(0)]],
    texture2d<float> texFA [[texture(1)]],
    texture2d<float> texFB [[texture(2)]],
    texture2d<float, access::read> texCirc [[texture(3)]],
    texture2d<float> texActor [[texture(4)]],
    texture2d<float> texActorShadow [[texture(5)]],
    texture2d<float> texCat [[texture(6)]]
) {
    float2 uRes = u.resAndGrid.xy;
    float uScale = u.core.x;
    float uSeed = u.core.y;
    float t = u.params.x;
    float uDebug = u.params.z;
    bool hasActor = u.gridInfo.z > 0.5;
    bool hasCat = u.gridInfo.w > 0.5;
    float sunsetW = u.solar.x;
    float nightW = u.solar.y;

    float2 p = in.position.xy / uScale;
    auto N = [&](float2 pt, float sc) -> float4 {
        return texNoise.sample(sRepeatMip, pt / sc + uSeed * 0.013);
    };

    float w1 = N(p, 1900.0).b, w2 = N(p + 311.0, 650.0).g;
    float3 col = mix(u.grassMid.rgb, u.grassLight.rgb, ss(0.3, 0.75, w1 * 0.7 + w2 * 0.3));
    col = mix(col, u.grassDeep.rgb, ss(0.45, 0.85, N(p + 977.0, 1300.0).r) * 0.4);
    col *= 1.0 + 0.05 * (0.5 - (p.x + p.y) / max(uRes.x + uRes.y, 1.0));
    col *= 1.0 + (dlHash2(floor(p * (0.8 * max(uScale, 1.0)))) - 0.5) * 0.035;
    col = mix(col, u.grassInk.rgb, grassInkPattern(p, uSeed, texNoise) * 0.75);

    float3 spriteTint = mix(mix(float3(1.0), float3(1.04, 0.80, 0.66), sunsetW), float3(0.40, 0.50, 0.68), nightW);

    if (hasActor) {
        float2 actorUV = (p - u.actorRect.xy) / max(u.actorRect.zw, float2(1.0));
        float inActor = step(0.0, actorUV.x) * step(0.0, actorUV.y) * step(actorUV.x, 1.0) * step(actorUV.y, 1.0);
        if (inActor > 0.5) {
            float4 actor = texActor.sample(sClampLinear, actorUV);
            float actorSh = texActorShadow.sample(sClampLinear, actorUV).r;
            col = mix(col, col * u.shadowTint.rgb, actorSh * (0.85 - nightW * 0.25));
            col = mix(col, actor.rgb * spriteTint, actor.a);
        }
    }

    if (hasCat) {
        float2 catUV = (p - u.catRect.xy) / max(u.catRect.zw, float2(1.0));
        float2 catShadowUV = (p - u.catExtra.xy - u.catRect.xy) / max(u.catRect.zw, float2(1.0));
        float inCat = step(0.0, catUV.x) * step(0.0, catUV.y) * step(catUV.x, 1.0) * step(catUV.y, 1.0);
        float inShadow = step(0.0, catShadowUV.x) * step(0.0, catShadowUV.y) * step(catShadowUV.x, 1.0) * step(catShadowUV.y, 1.0);
        if (inShadow > 0.5) {
            float sh = evalCatColor(catShadowUV, u.catExtra.z, texCat).a;
            col = mix(col, col * u.shadowTint.rgb, sh * (0.78 - nightW * 0.2));
        }
        if (inCat > 0.5) {
            float4 cat = evalCatColor(catUV, u.catExtra.z, texCat);
            col = mix(col, cat.rgb * spriteTint, cat.a);
        }
    }

    if (nightW > 0.15) {
        float2 cell = floor(p / 96.0);
        float2 f = fract(p / 96.0);
        float seedc = dlHash2(cell + uSeed * 0.3);
        if (seedc < 0.28) {
            float2 center = 0.2 + 0.6 * float2(dlHash2(cell + 2.1), dlHash2(cell + 5.3));
            center += 0.12 * float2(sin(t * 0.9 + seedc * 20.0), cos(t * 0.7 + seedc * 15.0));
            float pulse = 0.4 + 0.6 * pow(0.5 + 0.5 * sin(t * (1.6 + seedc * 1.4) + seedc * 12.0), 2.0);
            float dist = length((f - center) * 96.0);
            float glow = exp(-dist * 0.26) * pulse * nightW;
            col += float3(0.95, 0.92, 0.42) * glow * 0.65;
        }
    }

    float4 dummy = float4(0.0, -1e9, 0.0, 0.0);
    float sd = cloudDistEval(p - u.lighting.xy, false, dummy, u, texFA, texFB, texCirc);
    col = mix(col, col * u.shadowTint.rgb, ss(3.0, -3.0, sd) * (0.85 - nightW * 0.22));

    float4 fc = float4(0.0, -1e9, 0.0, 0.0);
    float d = cloudDistEval(p, true, fc, u, texFA, texFB, texCirc);
    if (d < 1.5) {
        float4 dummy2 = float4(0.0, -1e9, 0.0, 0.0);
        float hi = d > -21.0 ? ss(-1.0, 1.0, cloudDistEval(p + u.lighting.zw * 20.0, false, dummy2, u, texFA, texFB, texCirc)) : 0.0;
        float3 cc = fc.y > -1e8 ? mix(u.cloudBody.rgb, u.cloudShade.rgb, fc.w * 0.6) : mix(u.cloudBody.rgb, u.cloudShade.rgb, 0.45);
        cc = mix(cc, u.cloudHi.rgb, hi);
        col = mix(col, cc, ss(1.0, -1.0, d));
    }

    if (uDebug > 0.5) {
        col = mix(col, float3(0.9, 0.15, 0.15), 1.0 - ss(0.0, 1.5, abs(d)));
    }
    return float4(col, 1.0);
}

struct MeadowBoyUniforms {
    float4 resAndOffset;
    float4 place;
    float4 kiteAndTime;
    float4 pose;
    float4 motion;
    float4 rig;
    float4 leftHipKnee;
    float4 rightHipKnee;
    float4 ankles;
    float4 feetAndGround;
    float4 contactLAndTension;
    float4 contactRAndRock;
    float4 bodyAndLegs;
    float4 handAndTug;
    float4 solarTint;
};

inline float4 overBlend(float4 base, float4 top) {
    float alpha = top.a + base.a * (1.0 - top.a);
    return float4((top.rgb * top.a + base.rgb * base.a * (1.0 - top.a)) / max(alpha, 0.001), alpha);
}

inline float2 boyTurn(float2 p, float angle) {
    float c = cos(angle), s = sin(angle);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

inline float2 boyBodySpace(float2 p, float2 uBody) {
    return p - uBody * clamp((78.0 - p.y) / 170.0, 0.0, 1.0);
}

inline float boyArmMask(float2 p) {
    float boundary = p.y < -30.0 ? -38.0 + (-p.y - 30.0) * 0.10 : min(-17.0, -38.0 + (p.y + 30.0) * 0.78);
    return (1.0 - smoothstep(boundary - 0.45, boundary + 0.45, p.x)) * (1.0 - smoothstep(0.0, 3.0, p.y));
}

inline float4 boySpriteColor(float4 color, float2 p) {
    color.a *= step(-76.0, p.x) * step(-95.0, p.y) * step(p.x, 76.0) * step(p.y, 85.0);
    return color;
}

inline float2 boySpriteUV(float2 p) {
    return clamp((p + float2(76.0, 95.0)) / float2(152.0, 180.0), 0.002, 0.998);
}

inline float2 boyPersonSource(float2 p, float2 uBody, float2 uLegs) {
    float2 boy = boyBodySpace(p, uBody);
    float2 rest = boy;
    float lower = smoothstep(24.0, 48.0, rest.y);
    float right = smoothstep(-4.0, 9.0, rest.x);
    float lift = mix(uLegs.x, uLegs.y, right);
    boy.y += lift * lower;
    boy.x -= (right * 2.0 - 1.0) * lift * 0.24 * lower;
    return boy;
}

inline float boyRibbon(float2 p, float offset, float phase, float uTime, float uRunWind, float uKiteRock) {
    float t = clamp(p.y / 108.0, 0.0, 1.0);
    float gust = sin(t * 5.6 - uTime * 4.8 + phase) * uRunWind * 9.0 + sin(t * 6.0 - uTime * 7.0 + phase) * abs(uKiteRock) * 12.0;
    float center = offset + 50.0 * t + (12.0 * sin(t * 4.8 - uTime * 1.15 + phase) + gust) * t;
    float width = mix(3.4, 1.6, t);
    return (1.0 - smoothstep(width, width + 1.0, abs(p.x - center))) * step(0.0, p.y) * step(p.y, 108.0);
}

inline float boyKiteAngle(float uTime, float uRunWind, float uKiteRock) {
    return -0.23 + sin(uTime * 0.7) * 0.09 + sin(uTime * 4.8 + 0.7) * uRunWind * 0.24 + uKiteRock;
}

inline float4 boyKiteColor(float2 p, float2 screen, constant MeadowBoyUniforms& u) {
    float uTime = u.kiteAndTime.z;
    float uShadow = u.kiteAndTime.w;
    float uRunWind = u.rig.w;
    float uKiteRock = u.contactRAndRock.w;

    float4 result = float4(0.0);
    float angle = boyKiteAngle(uTime, uRunWind, uKiteRock);
    float2 delta = p - u.kiteAndTime.xy;
    float2 q = float2(cos(angle) * delta.x + sin(angle) * delta.y, -sin(angle) * delta.x + cos(angle) * delta.y);
    float2 tail = q - float2(2.0, 65.0);
    result = overBlend(result, float4(0.88, 0.65, 0.37, boyRibbon(tail, 0.0, 0.0, uTime, uRunWind, uKiteRock)));
    result = overBlend(result, float4(0.81, 0.39, 0.30, boyRibbon(tail, 8.0, 0.45, uTime, uRunWind, uKiteRock)));
    result = overBlend(result, float4(0.32, 0.55, 0.62, boyRibbon(tail, 16.0, 0.9, uTime, uRunWind, uKiteRock)));
    float diamond = abs(q.x) / 53.0 + abs(q.y) / 70.0;
    float coverage = 1.0 - smoothstep(mix(0.97, 0.94, uShadow), mix(1.025, 1.07, uShadow), diamond);
    float3 fabric = q.y < 0.0
        ? (q.x < 0.0 ? float3(0.95, 0.77, 0.42) : float3(0.88, 0.43, 0.33))
        : (q.x < 0.0 ? float3(0.94, 0.77, 0.44) : float3(0.35, 0.57, 0.64));
    float grain = fract(sin(dot(floor(screen * 1.7), float2(12.9898, 78.233))) * 43758.5453);
    fabric *= 0.97 + grain * 0.06;
    fabric = mix(fabric, float3(0.46, 0.40, 0.25), smoothstep(0.93, 1.0, diamond) * 0.78);
    float seams = 1.0 - smoothstep(0.35, 0.9, min(abs(q.x), abs(q.y)));
    fabric = mix(fabric, float3(0.98, 0.92, 0.71), seams * 0.65);
    return overBlend(result, float4(fabric, coverage));
}

inline float4 boyStanding(float2 p, float lod, texture2d<float> uRunSprite) {
    return boySpriteColor(uRunSprite.sample(sClampMip, (boySpriteUV(p) + float2(1.0)) * 0.5, level(lod)), p);
}

inline float2 boyBoneSource(float2 p, float2 sourceA, float2 sourceB, float2 posedA, float2 posedB) {
    float2 v = posedB - posedA, s = sourceB - sourceA;
    float lengthV = max(length(v), 0.001), lengthS = max(length(s), 0.001);
    float2 axis = v / lengthV, normal = float2(-axis.y, axis.x), sourceAxis = s / lengthS;
    return sourceA + s * (dot(p - posedA, axis) / lengthV) + float2(-sourceAxis.y, sourceAxis.x) * dot(p - posedA, normal);
}

inline float boyRigMask(float2 p, float side, float y0, float y1) {
    float xMask = mix(1.0 - smoothstep(-2.0, 1.0, p.x), smoothstep(2.0, 5.0, p.x), step(0.0, side));
    return xMask * smoothstep(y0 - 0.6, y0 + 0.6, p.y) * (1.0 - smoothstep(y1 - 0.6, y1 + 0.6, p.y));
}

inline float4 boyRigPiece(float2 source, float side, float y0, float y1, float lod, texture2d<float> uRunSprite) {
    float4 color = boyStanding(source, lod, uRunSprite);
    color.a *= boyRigMask(source, side, y0, y1);
    return color;
}

inline float4 boyRigJoint(float2 p, float2 center, float3 color, float radius) {
    float d = length(p - center);
    float4 edge = float4(0.26, 0.18, 0.12, 1.0 - smoothstep(radius + 0.2, radius + 0.8, d));
    return overBlend(edge, float4(color, 1.0 - smoothstep(radius - 0.6, radius, d)));
}

inline float boyRunnerArmMask(float2 p) {
    return (1.0 - smoothstep(-25.0, -21.0, p.x)) * smoothstep(-8.0, -3.0, p.y) * (1.0 - smoothstep(29.0, 31.0, p.y));
}

inline float boyRunnerReelArmMask(float2 p) {
    float boundary = p.y < -50.0 ? 32.0 : p.y < -43.0 ? mix(31.0, 34.0, (p.y + 50.0) / 7.0) :
        p.y < -34.0 ? mix(34.0, 28.0, (p.y + 43.0) / 9.0) : mix(28.0, 23.0, clamp((p.y + 34.0) / 14.0, 0.0, 1.0));
    return smoothstep(boundary - 0.5, boundary + 0.5, p.x) * (1.0 - smoothstep(2.0, 6.0, p.y));
}

inline float4 boyRunning(float2 p, float4 trunk, float lod, constant MeadowBoyUniforms& u, texture2d<float> uRunSprite) {
    float2 lh = float2(-12.0, 37.0), lk = float2(-14.0, 47.0), la = float2(-15.0, 57.0);
    float2 rh = float2(14.0, 35.0), rk = float2(18.0, 44.0), ra = float2(21.0, 51.0);
    float2 uLeftAnkle = u.ankles.xy, uRightAnkle = u.ankles.zw;
    float2 uFootAngles = u.feetAndGround.xy;

    float2 leftThigh = boyBoneSource(p, lh, lk, u.leftHipKnee.xy, u.leftHipKnee.zw);
    float2 leftShin  = boyBoneSource(p, lk, la, u.leftHipKnee.zw, uLeftAnkle);
    float2 leftFoot  = la + boyTurn(p - uLeftAnkle, -uFootAngles.x);
    float2 rightThigh = boyBoneSource(p, rh, rk, u.rightHipKnee.xy, u.rightHipKnee.zw);
    float2 rightShin  = boyBoneSource(p, rk, ra, u.rightHipKnee.zw, uRightAnkle);
    float2 rightFoot  = ra + boyTurn(p - uRightAnkle, -uFootAngles.y);

    float4 left = boyRigJoint(p, u.leftHipKnee.zw, float3(0.98, 0.76, 0.47), 3.5);
    left = overBlend(left, boyRigJoint(p, uLeftAnkle, float3(0.97, 0.96, 0.88), 2.8));
    left = overBlend(left, boyRigPiece(leftThigh, -1.0, 35.5, 49.0, lod, uRunSprite));
    left = overBlend(left, boyRigPiece(leftShin, -1.0, 47.0, 58.5, lod, uRunSprite));
    left = overBlend(left, boyRigPiece(leftFoot, -1.0, 56.5, 74.0, lod, uRunSprite));

    float4 right = boyRigJoint(p, u.rightHipKnee.zw, float3(0.98, 0.76, 0.47), 3.5);
    right = overBlend(right, boyRigJoint(p, uRightAnkle, float3(0.97, 0.96, 0.88), 2.8));
    right = overBlend(right, boyRigPiece(rightThigh, 1.0, 34.5, 46.0, lod, uRunSprite));
    right = overBlend(right, boyRigPiece(rightShin, 1.0, 44.0, 53.0, lod, uRunSprite));
    right = overBlend(right, boyRigPiece(rightFoot, 1.0, 51.5, 68.0, lod, uRunSprite));

    float cut = max(boyRigMask(p, -1.0, 37.0, 86.0), boyRigMask(p, 1.0, 36.0, 86.0));
    trunk.a *= (1.0 - cut) * (1.0 - boyRunnerArmMask(p)) * (1.0 - boyRunnerReelArmMask(p));

    float2 armSource = float2(-23.0, -5.0) + boyTurn(p - float2(-23.0, -5.0), -u.rig.y);
    float4 arm = boyStanding(armSource, lod, uRunSprite);
    arm.a *= boyRunnerArmMask(armSource);

    float2 reelPivot = float2(22.0, -7.0);
    float2 reelSource = reelPivot + boyTurn(p - reelPivot, -u.rig.z);
    float4 reelArm = boyStanding(reelSource, lod, uRunSprite);
    reelArm.a *= boyRunnerReelArmMask(reelSource);

    float4 legs = mix(overBlend(left, right), overBlend(right, left), step(uRightAnkle.y, uLeftAnkle.y));
    legs = overBlend(legs, boyRigJoint(p, float2(-23.0, -5.0), float3(0.87, 0.24, 0.18), 4.5));
    legs = overBlend(legs, boyRigJoint(p, reelPivot, float3(0.87, 0.24, 0.18), 5.0));
    return overBlend(overBlend(overBlend(legs, trunk), arm), reelArm);
}

inline float4 boyCharacterColor(float2 p, constant MeadowBoyUniforms& u, texture2d<float> uCharacter, texture2d<float> uRunSprite) {
    p.x /= max(u.motion.z, 0.1);
    float2 uBody = u.bodyAndLegs.xy, uLegs = u.bodyAndLegs.zw, uTug = u.handAndTug.zw;
    float2 boy = boyPersonSource(p, uBody, uLegs);
    float2 space = boyBodySpace(p, uBody);
    float2 pivot = float2(-21.0, -9.0);
    float2 armSource = pivot + boyTurn(space + uTug * 0.35 - pivot, -(u.pose.z + 0.18));
    float lod = u.kiteAndTime.w * 2.8;

    float4 person = boySpriteColor(uCharacter.sample(sClampMip, boySpriteUV(boy), level(lod)), boy);
    float4 arm = boySpriteColor(uCharacter.sample(sClampMip, boySpriteUV(armSource), level(lod)), armSource);
    person.a *= 1.0 - boyArmMask(boy);
    arm.a *= boyArmMask(armSource);
    float4 shoulder = boyRigJoint(space, pivot, float3(0.90, 0.22, 0.16), 5.0);
    float4 front = overBlend(overBlend(person, shoulder), arm);

    float2 runPoint = p - float2(0.0, u.motion.w - 10.0);
    float2 cell = float2(fmod(u.motion.x, 2.0), floor(u.motion.x * 0.5));
    float4 back = boySpriteColor(uRunSprite.sample(sClampMip, (boySpriteUV(runPoint) + cell) * 0.5, level(lod)), runPoint);
    back = mix(back, boyRunning(runPoint, back, lod, u, uRunSprite), u.rig.x);
    return mix(front, back, u.motion.y);
}

fragment float4 meadowBoyFragment(
    FullscreenOut in [[stage_in]],
    constant MeadowBoyUniforms& u [[buffer(0)]],
    texture2d<float> uCharacter [[texture(0)]],
    texture2d<float> uRunSprite [[texture(1)]]
) {
    float uScale = u.place.w;
    float uShadow = u.kiteAndTime.w;
    float uTime = u.kiteAndTime.z;
    float uTension = u.contactLAndTension.w;
    float2 uGround = u.feetAndGround.zw;

    float2 screen = u.resAndOffset.zw + in.position.xy / uScale;
    float2 p = (screen - u.place.xy) / max(u.place.z, 0.001);

    float sy = (p.y - uGround.x * p.x - uGround.y) / (uGround.x * 0.46 - 0.64);
    float2 projected = float2(p.x + 0.46 * sy, uGround.x * (p.x + 0.46 * sy) + uGround.y + sy);
    float2 personPoint = mix(p, projected, uShadow);
    float4 person = boyCharacterColor(personPoint, u, uCharacter, uRunSprite);

    float4 kite = boyKiteColor(p - uShadow * float2(98.0, 134.0), screen, u);
    float2 hand = u.handAndTug.xy;
    float2 attach = u.kiteAndTime.xy + boyTurn(float2(-41.0, -16.0), boyKiteAngle(uTime, u.rig.w, u.contactRAndRock.w));
    float2 control = mix(hand, attach, 0.5) + float2(-13.0 + sin(uTime * 0.8) * 6.0, 18.0) * (1.0 - uTension * 0.85);
    float line = 1e5;
    float2 previous = hand;
    for (int i = 1; i <= 6; i++) {
        float t = float(i) / 6.0;
        float2 point = mix(mix(hand, control, t), mix(control, attach, t), t);
        line = min(line, segSD(p, previous, point));
        previous = point;
    }
    float4 result = overBlend(kite, person);
    result = overBlend(result, float4(0.94, 0.92, 0.77, (1.0 - smoothstep(0.4, 1.1, line)) * 0.94));

    float contactL = (1.0 - smoothstep(0.65, 1.15, length((p - u.contactLAndTension.xy) / float2(7.0, 2.6)))) * u.contactLAndTension.z;
    float contactR = (1.0 - smoothstep(0.65, 1.15, length((p - u.contactRAndRock.xy) / float2(7.0, 2.6)))) * u.contactRAndRock.z;
    float silhouette = max(max(person.a, kite.a), max(contactL, contactR));
    return mix(result, float4(float3(silhouette), 1.0), uShadow);
}

struct ForestUniforms {
    float4 resAndGrid;
    float4 core;
    float4 params;
    float4 gridInfo;
    float4 lighting;

    float4 clearingLight;
    float4 clearingMid;
    float4 canopy0;
    float4 canopy1;
    float4 canopy2;
    float4 canopyRim;
    float4 shadowTint;
    float4 grassInk;

    float4 birds[8];
    float4 ripples[4];
};

inline float3 forestCanopyEval(
    float2 q,
    thread float4& topPuff,
    constant ForestUniforms& u,
    texture2d<float, access::read> texCirc
) {
    float uCellG = u.params.w;
    int cgW = int(u.gridInfo.x + 0.5);
    int cgH = int(u.gridInfo.y + 0.5);
    int2 cell = int2(floor(q / uCellG)) + 4;
    float d = 1e6;
    float maxH = -1e9;
    if (cell.x < 0 || cell.y < 0 || cell.x >= cgW || cell.y >= cgH) return float3(d, 0.0, 0.0);

    for (int k = 0; k < CIRC_K; k++) {
        float4 c = texCirc.read(uint2(uint(cell.x * CIRC_K + k), uint(cell.y)));
        if (c.z <= 0.0) break;
        float di = length(q - c.xy) - c.z;
        d = smin(d, di, 4.5);
        float score = c.y * 0.01 + c.z * 0.1;
        if (di < 1.5 && score > maxH) {
            maxH = score;
            topPuff = c;
        }
    }
    return float3(d, topPuff.w, maxH > -1e8 ? 1.0 : 0.0);
}

fragment float4 forestFragment(
    FullscreenOut in [[stage_in]],
    constant ForestUniforms& u [[buffer(0)]],
    texture2d<float> texNoise [[texture(0)]],
    texture2d<float> texFA [[texture(1)]],
    texture2d<float> texFB [[texture(2)]],
    texture2d<float, access::read> texCirc [[texture(3)]]
) {
    float2 uRes = u.resAndGrid.xy;
    float2 uGrid = u.resAndGrid.zw;
    float uScale = u.core.x;
    float uSeed = u.core.y;
    float uStep = u.core.z;
    float uMix = u.core.w;
    float t = u.params.x;
    int birdN = int(u.gridInfo.z + 0.5);
    float nightW = u.gridInfo.w;
    float sunsetW = u.lighting.z;
    float uDebug = u.lighting.w;

    float2 p = in.position.xy / uScale;
    float2 gp = floor(p * (0.8 * max(uScale, 1.0)));
    float grain = dlHash2(gp + 1.7);

    auto N = [&](float2 pt, float sc) -> float4 {
        return texNoise.sample(sRepeatMip, pt / sc + uSeed * 0.013);
    };

    float s0 = mix(fieldSample(texFA, p, uStep, uGrid), fieldSample(texFB, p, uStep, uGrid), uMix);
    float s = s0 + (N(p, 520.0).r - 0.5) * 14.0;

    float w1 = N(p, 1600.0).b, w2 = N(p + 233.0, 580.0).g;
    float3 col = mix(u.clearingMid.rgb, u.clearingLight.rgb, ss(0.28, 0.76, w1 * 0.65 + w2 * 0.35));
    col = mix(col, u.clearingMid.rgb * 0.86, ss(-28.0, 12.0, s) * 0.55);
    col *= 1.0 + 0.04 * (0.5 - (p.x + p.y) / max(uRes.x + uRes.y, 1.0));
    col = mix(col, u.grassInk.rgb, grassInkPattern(p, uSeed + 19.0, texNoise) * 0.62);

    if (s < 6.0) {
        float2 fcCell = floor(p / 29.0);
        float2 fcFrac = fract(p / 29.0);
        float h = dlHash2(fcCell + uSeed * 0.2);
        if (h < 0.09) {
            float2 ctr = 0.25 + 0.5 * float2(dlHash2(fcCell + 4.1), dlHash2(fcCell + 8.7));
            float fd = length((fcFrac - ctr) * 29.0);
            float3 petal = h < 0.045 ? float3(0.99, 0.96, 0.82) : float3(0.97, 0.78, 0.68);
            petal *= mix(float3(1.0), float3(0.45, 0.55, 0.75), nightW);
            col = mix(col, petal, (1.0 - ss(1.1, 2.2, fd)) * ss(6.0, -10.0, s));
        }
    }

    float2 shOff = float2(22.0 + sunsetW * 12.0, 30.0 + sunsetW * 10.0);
    float4 dummyPuff = float4(0.0);
    float3 shEval = forestCanopyEval(p - shOff, dummyPuff, u, texCirc);
    float deepForestFloor = ss(8.0, 52.0, s);
    col = mix(col, col * u.shadowTint.rgb, max(ss(3.0, -3.0, shEval.x) * 0.72, deepForestFloor * 0.55) * (1.0 - nightW * 0.25));

    float4 puff = float4(0.0, -1e9, 0.0, 0.5);
    float3 can = forestCanopyEval(p, puff, u, texCirc);
    if (can.x < 1.5) {
        float tone = fract(puff.w * 7.13);
        float3 baseTree = tone < 0.36 ? mix(u.canopy0.rgb, u.canopy1.rgb, tone / 0.36)
                                      : mix(u.canopy1.rgb, u.canopy2.rgb, (tone - 0.36) / 0.64);
        float2 localP = p - puff.xy;
        float sunDot = clamp(dot(localP / max(puff.z, 1.0), u.lighting.xy), -1.0, 1.0);
        float brush = (N(p * 2.4, 180.0).r - 0.5) * 0.12 + (grain - 0.5) * 0.06;
        float3 treeCol = baseTree * (1.0 + brush);
        treeCol = mix(treeCol, u.canopyRim.rgb, ss(0.15, 0.78, sunDot + brush * 1.4) * 0.58);
        treeCol = mix(treeCol, u.canopy0.rgb * 0.74, ss(0.10, 0.80, -sunDot) * 0.42);
        treeCol *= 1.0 - 0.08 * ss(-5.0, 0.0, can.x);
        col = mix(col, treeCol, ss(1.1, -1.1, can.x));
    }

    float3 birdTint = mix(mix(float3(1.0), float3(1.04, 0.78, 0.62), sunsetW), float3(0.42, 0.52, 0.70), nightW);
    for (int i = 0; i < 8; i++) {
        if (i >= birdN) break;
        float4 b = u.birds[i];
        float2 d0 = p - b.xy;
        if (dot(d0, d0) < 256.0) {
            float2 q = rot2D(d0, -b.z) * 1.35;
            float3 g = gullSD(q, b.w);
            float3 bodyCol = (i % 2 == 0 ? float3(0.95, 0.92, 0.82) : float3(0.42, 0.66, 0.78)) * birdTint;
            float3 wingCol = (i % 2 == 0 ? float3(0.32, 0.36, 0.34) : float3(0.24, 0.42, 0.54)) * birdTint;
            col = mix(col, wingCol, ss(0.7, -0.7, g.y));
            col = mix(col, bodyCol, ss(0.7, -0.7, g.x));
        }
    }

    if (nightW > 0.12) {
        for (int layer = 0; layer < 2; layer++) {
            float cs = layer == 0 ? 74.0 : 112.0;
            float2 q = rot2D(p, layer == 0 ? 0.35 : -0.82) / cs;
            float2 cell = floor(q), f = fract(q);
            float h = dlHash2(cell + float(layer) * 31.0 + uSeed * 0.17);
            if (h > 0.24) continue;
            float2 ctr = 0.22 + 0.56 * float2(dlHash2(cell + 1.9), dlHash2(cell + 6.3));
            ctr += 0.14 * float2(sin(t * 0.8 + h * 25.0), cos(t * 0.65 + h * 19.0));
            float blink = pow(0.5 + 0.5 * sin(t * (1.4 + h * 1.8) + h * 17.0), 3.0);
            float dist = length((f - ctr) * cs);
            float glow = (exp(-dist * 0.28) * 0.85 + exp(-dist * 0.08) * 0.22) * blink * nightW;
            col += float3(0.96, 0.90, 0.38) * glow;
        }
    }

    col *= 1.0 + (grain - 0.5) * 0.032;
    if (uDebug > 0.5) {
        col = mix(col, float3(0.9, 0.15, 0.15), 1.0 - ss(0.0, 1.5, abs(s0)));
    }
    return float4(col, 1.0);
}
