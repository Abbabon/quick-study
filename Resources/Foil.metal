// Foil shaders for the card image (SwiftUI `.layerEffect`, macOS 14).
// Compiled to Foil.metallib by scripts/compile-shaders.sh and loaded from the app bundle.
//
// Model: a foil card is ink printed over a mirror-like substrate. What you see is the substrate's
// reflection filtered by the ink, so the foil colour is MULTIPLIED into the art: black ink, the
// black border and text stay dark and crisp; light areas (sky, text box, frame) carry the colour.
// A specular band and a soft glare follow the pointer like a light source.
//
// Size independence: every pattern is defined in card-relative coordinates (uv 0...1, or q =
// width-normalised so circles stay round), never in points, so a 330pt and a 900pt card look the same.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

namespace {

struct Card {
    float2 uv;      // 0...1 across the card
    float2 q;       // x 0...1, y 0...height/width (isotropic)
    float2 light;   // pointer in q space
    float3 base;    // un-premultiplied art colour
    float alpha;
    float L;        // luminance of the art
    float px;       // one point, in q units (antialiasing only)
};

Card makeCard(float2 pos, SwiftUI::Layer layer, float2 size, float2 pointer) {
    Card c;
    half4 s = layer.sample(pos);
    c.alpha = s.a;
    c.base = s.a > 0.001h ? float3(s.rgb / s.a) : float3(0.0);
    c.uv = pos / size;
    float aspect = size.y / size.x;
    c.q = float2(c.uv.x, c.uv.y * aspect);
    c.light = float2(0.5 + pointer.x * 0.5, (0.5 + pointer.y * 0.5) * aspect);
    c.L = dot(c.base, float3(0.2126, 0.7152, 0.0722));
    c.px = 1.0 / size.x;
    return c;
}

float3 spectrum(float t) { return 0.5 + 0.5 * cos(6.2831853 * (t + float3(0.0, 0.33, 0.67))); }

float hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), u.x),
               mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
}

float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { v += a * vnoise(p); p = p * 2.03 + 17.1; a *= 0.5; }
    return v;
}

/// Diagonal specular streak through the light point: 1 on its axis, falling off with `width`.
float streak(Card c, float width) {
    float d = dot(c.q - c.light, normalize(float2(0.8, 0.6)));
    return exp(-d * d / (width * width));
}

/// Round soft glare centred on the light point.
float glare(Card c, float radius) {
    float2 d = c.q - c.light;
    return exp(-dot(d, d) / (radius * radius));
}

/// How much substrate shows through the ink: none under black/near-black ink.
float inkWindow(Card c, float lo, float hi) { return smoothstep(lo, hi, c.L); }

half4 finish(Card c, float3 col) {
    // soft shoulder instead of a hard clip, so bright foil rolls off like a photo rather than blowing out
    const float k = 0.8;
    col = max(col, 0.0);
    col = select(col, k + (1.0 - k) * tanh((col - k) / (1.0 - k)), col > k);
    return half4(half3(col * c.alpha), half(c.alpha));
}

/// Sparse star field in card units; each star flashes at its own pointer angle.
float stars(Card c, float2 pointer, float density, float coverage) {
    float2 g = c.q * density;
    float2 id = floor(g);
    float pxCell = c.px * density;
    float s = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 cell = id + float2(i, j);
            if (hash(cell) > coverage) continue;
            float2 d = g - (cell + 0.15 + 0.7 * float2(hash(cell + 7.1), hash(cell + 3.3)));
            float big = hash(cell + 1.7);
            float r = 0.05 + 0.09 * big;
            float flash = pow(max(0.0, cos(6.2831853 * hash(cell + 9.2) + pointer.x * 4.5 - pointer.y * 3.5)), 4.0);
            float dist = length(d);
            float core = 1.0 - smoothstep(r - pxCell * 0.5, r + pxCell * 0.5, dist);
            float halo = exp(-dist * dist / (r * r * 5.0)) * 0.6;
            float w = max(r * 0.16, pxCell * 0.35);
            float spikes = (exp(-abs(d.y) / w) + exp(-abs(d.x) / w)) * exp(-dist / (r * 4.0)) * step(0.55, big);
            s += flash * (core + halo + spikes * 0.6);
        }
    }
    return s;
}

} // namespace

/// Traditional foil: a rainbow that slides diagonally with the tilt, brightest in a specular streak.
[[ stitchable ]] half4 foilHolo(float2 pos, SwiftUI::Layer layer, float2 size, float2 pointer) {
    Card c = makeCard(pos, layer, size, pointer);
    float diag = dot(c.q, float2(0.8, 0.6));
    float3 rb = spectrum(diag * 1.8 - pointer.x * 0.5 - pointer.y * 0.35);
    float s = streak(c, 0.22);
    float ink = inkWindow(c, 0.04, 0.55);
    float3 refl = 0.9 + rb * (0.18 + 0.7 * s) - 0.12 * (1.0 - s);
    float3 col = c.base * mix(float3(1.0), refl, ink);
    col += rb * s * 0.08 * ink + glare(c, 0.3) * 0.1 * c.L;
    return finish(c, col);
}

/// Etched foil: metallic, partly desaturated sheen with a fine grain on the frame and text box;
/// the art window stays (almost) non-foil, the way real etched cards are printed.
[[ stitchable ]] half4 foilEtched(float2 pos, SwiftUI::Layer layer, float2 size, float2 pointer) {
    Card c = makeCard(pos, layer, size, pointer);
    float2 uv = c.uv;
    float art = smoothstep(0.07, 0.085, uv.x) * (1.0 - smoothstep(0.915, 0.93, uv.x))
              * smoothstep(0.10, 0.115, uv.y) * (1.0 - smoothstep(0.55, 0.565, uv.y));
    float frame = (1.0 - 0.85 * art) * inkWindow(c, 0.05, 0.2);
    float s = streak(c, 0.26);
    // brushed metal: fine horizontal streaks (low frequency across, high down the card) and an
    // anisotropic highlight stretched along the brushing, like light on a satin metal frame
    float brushed = vnoise(float2(c.q.x * 2.0, c.q.y * 240.0)) * 0.6 + vnoise(float2(c.q.x * 4.0 + 3.0, c.q.y * 70.0)) * 0.4;
    float2 d = (c.q - c.light) * float2(0.45, 1.8);
    float aniso = exp(-dot(d, d) / 0.04);
    float3 tint = mix(float3(1.0), spectrum(dot(c.q, float2(0.6, 0.8)) * 0.9 - pointer.x * 0.35) + 0.35, 0.14);
    float3 metal = mix(float3(c.L), c.base, 0.5);
    float sheen = 0.76 + 0.14 * brushed + s * 0.3 * (0.6 + 0.4 * brushed) + aniso * 0.5 * (0.4 + 0.6 * brushed);
    float3 col = mix(c.base, metal * sheen * tint, frame);
    return finish(c, col);
}

/// Galaxy foil: a soft nebula-tinted foil plus sparkles that flash as the card tilts.
[[ stitchable ]] half4 foilGalaxy(float2 pos, SwiftUI::Layer layer, float2 size, float2 pointer) {
    Card c = makeCard(pos, layer, size, pointer);
    float n = fbm(c.q * 3.2 + pointer * 0.12);
    float3 neb = mix(spectrum(n * 1.4 + dot(c.q, float2(0.5, 0.5)) * 0.6 - pointer.x * 0.35),
                     float3(0.55, 0.45, 1.0), 0.3);
    float s = streak(c, 0.3);
    float ink = inkWindow(c, 0.04, 0.55);
    float cloud = smoothstep(0.3, 0.75, n);
    float3 refl = 0.86 + neb * (0.2 + 0.55 * s) * (0.4 + 1.0 * cloud) - 0.08 * (1.0 - s);
    float3 col = c.base * mix(float3(1.0), refl, ink);
    float st = stars(c, pointer, 38.0, 0.42) * inkWindow(c, 0.05, 0.3);
    col += st * mix(float3(1.0), neb, 0.35) * 0.9;
    col += glare(c, 0.3) * 0.08 * c.L;
    return finish(c, col);
}

/// Surge foil: vivid rainbow in rippling wavy bands across the whole card, flowing with the tilt.
[[ stitchable ]] half4 foilSurge(float2 pos, SwiftUI::Layer layer, float2 size, float2 pointer) {
    Card c = makeCard(pos, layer, size, pointer);
    float2 q = c.q;
    float warp = fbm(q * 2.2);
    float w = (q.y + sin(q.x * 9.0 + warp * 4.0) * 0.035 + sin(q.x * 23.0 - q.y * 7.0 + warp * 6.0) * 0.012
               + warp * 0.12) * 24.0
            + pointer.y * 2.0 + pointer.x * 1.2;
    float ripple = 0.5 + 0.5 * sin(w * 6.2831853);
    float3 rb = spectrum(w * 0.045 + dot(q, float2(0.7, 0.7)) * 0.8 - pointer.x * 0.4);
    float s = streak(c, 0.35);
    float ink = inkWindow(c, 0.03, 0.5);
    float3 refl = 0.78 + rb * (0.4 + 0.6 * s) * (0.45 + 0.75 * ripple);
    float3 col = c.base * mix(float3(1.0), refl, ink);
    col += rb * ripple * s * 0.1 * ink + glare(c, 0.3) * 0.1 * c.L;
    return finish(c, col);
}
