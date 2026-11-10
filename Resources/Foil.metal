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

/// Etched foil: metallic paint rather than a laminate, so it reads as matte, granular metal: the
/// frame and text box keep their own colour but turn metallic (a broad light/dark sheen that slides
/// with the tilt, like a sheet of brushed metal), covered in fine metal flecks that glint one by one.
/// The art window stays non-foil and black ink stays black, the way real etched cards are printed.
[[ stitchable ]] half4 foilEtched(float2 pos, SwiftUI::Layer layer, float2 size, float2 pointer) {
    Card c = makeCard(pos, layer, size, pointer);
    float2 uv = c.uv;
    float art = smoothstep(0.07, 0.085, uv.x) * (1.0 - smoothstep(0.915, 0.93, uv.x))
              * smoothstep(0.10, 0.115, uv.y) * (1.0 - smoothstep(0.55, 0.565, uv.y));
    float paint = (1.0 - 0.9 * art) * inkWindow(c, 0.03, 0.22);

    // broad metallic reflection: bright and dark zones along the diagonal, sliding with the pointer
    float diag = dot(c.q, float2(0.8, 0.6));
    float sheen = 0.5 + 0.5 * cos(6.2831853 * (diag * 1.1 - pointer.x * 0.45 - pointer.y * 0.3));
    sheen = 0.5 + 0.8 * sheen * sheen + streak(c, 0.16) * 0.3;

    // flecks: a round fleck in some cells of a fine card-relative grid, each glinting at its own
    // tilt angle; between them a soft, smooth grain (no per-cell blocks, which read as pixels)
    float2 g = c.q * 170.0;
    float2 id = floor(g);
    float2 f = fract(g) - 0.5 - 0.6 * (float2(hash(id + 1.3), hash(id + 4.7)) - 0.5);
    float rad = (0.12 + 0.12 * hash(id + 2.3)) * step(hash(id + 8.8), 0.55);
    float px = c.px * 170.0;
    float fleck = 1.0 - smoothstep(rad - px * 0.6, rad + px * 0.6, length(f));
    float glint = pow(max(0.0, cos(6.2831853 * hash(id) + pointer.x * 6.0 - pointer.y * 5.0)), 8.0);
    float grain = (vnoise(c.q * 380.0) - 0.5) * 0.3 + (vnoise(c.q * 140.0 + 9.0) - 0.5) * 0.14;

    // the paint keeps the frame's hue (red frame -> copper, white -> silver) but loses some colour
    float3 metal = mix(float3(c.L), c.base, 0.6);
    float3 tint = mix(float3(1.0), c.base / max(max(c.base.r, max(c.base.g, c.base.b)), 0.05), 0.3);
    float3 painted = metal * (sheen + grain) + tint * fleck * glint * (0.35 + 0.5 * sheen) * 0.8;
    float3 col = mix(c.base, painted, paint);
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

/// Surge foil: over the whole card (frame and art), a field of parallel streaks that all run one way,
/// up-right on the diagonal, like light combed through grass: near-white highlights on a silver
/// ground, tinted by pastel rainbow zones that drift across the streaks. Each streak flashes at its
/// own tilt angle and the hues sweep with the pointer, while the streaks themselves stay put.
[[ stitchable ]] half4 foilSurge(float2 pos, SwiftUI::Layer layer, float2 size, float2 pointer) {
    Card c = makeCard(pos, layer, size, pointer);
    const float2 along = normalize(float2(0.55, -0.83));
    const float2 across = float2(-along.y, along.x);
    float a = dot(c.q, across), b = dot(c.q, along);
    a += (vnoise(float2(b * 2.5, a * 3.0)) - 0.5) * 0.035;   // a gentle surge, lines stay parallel
    float st = vnoise(float2(a * 62.0, b * 4.5)) * 0.65 + vnoise(float2(a * 170.0 + 11.0, b * 9.0)) * 0.35;
    float lines = smoothstep(0.42, 0.78, st);
    // hue drifts slowly across the streaks (zones of pink, peach, cyan), the streaks themselves are
    // near-white highlights on a silver ground
    float3 rb = spectrum(vnoise(float2(a * 9.0, b * 1.5)) * 1.2 + vnoise(float2(a * 24.0 + 3.0, b * 2.0)) * 0.5
                         + a * 2.2 - pointer.x * 0.6 - pointer.y * 0.45);
    float flash = 0.4 + 0.6 * pow(0.5 + 0.5 * cos(6.2831853 * (vnoise(float2(a * 20.0 + 5.0, b * 2.0)) * 1.5
                                                                + a * 2.0 - pointer.x * 0.7 + pointer.y * 0.55)), 2.0);
    float hi = lines * flash;
    float3 pastel = mix(float3(1.0), rb, 0.52 - 0.35 * hi * hi);
    float s = streak(c, 0.32);
    float ink = inkWindow(c, 0.03, 0.5);
    float3 refl = mix(float3(0.74), pastel * (1.2 + 0.3 * s), hi) * mix(float3(1.0), rb, 0.15);
    float3 col = c.base * mix(float3(1.0), refl, ink);
    col += pastel * hi * (0.05 + 0.12 * s) * ink + glare(c, 0.3) * 0.08 * c.L;
    return finish(c, col);
}
