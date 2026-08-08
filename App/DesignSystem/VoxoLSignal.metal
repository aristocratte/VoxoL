#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// The VoxoL dither, evaluated per pixel on the GPU.
//
// The CPU version accumulated tens of thousands of rectangles into a `Canvas` every frame, which
// capped the signal at a few frames per second before it cost a visible slice of a core. Here each
// pixel resolves its own cell independently, so the field can run at display rate for free.
//
// Modes: 0 idle, 1 voice, 2 processing, 3 insights, 4 meeting,
//        5 transformation, 6 permissions, 7 engines, 8 ready.

namespace {

float voxolSquared(float value) {
    return value * value;
}

// The target is compiled with `-fmetal-math-mode=fast`, whose `sin` is only dependable over a
// small range. The clock reaches the hundreds, so every angle is reduced to one turn first —
// without this the field quietly stops advancing.
float voxolWrap(float angle) {
    const float turn = 2.0 * M_PI_F;
    return angle - turn * floor(angle / turn);
}

float voxolSin(float angle) {
    return sin(voxolWrap(angle));
}

float voxolCos(float angle) {
    return cos(voxolWrap(angle));
}

// Integer-style value noise. The usual `fract(sin(dot(p, k)) * 43758.5453)` hash relies on sin far
// outside the range fast math handles, and collapses into visible banding here.
float voxolHash(float2 cell, float seed) {
    float3 p = fract(float3(cell.x, cell.y, seed) * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

float voxolSeed(float mode) {
    if (mode < 0.5) { return 4.0; }
    if (mode < 1.5) { return 5.0; }
    if (mode < 2.5) { return 7.0; }
    if (mode < 3.5) { return 8.0; }
    if (mode < 4.5) { return 7.0; }
    if (mode < 5.5) { return 15.0; }
    if (mode < 6.5) { return 16.0; }
    if (mode < 7.5) { return 17.0; }
    return 21.0;
}

float voxolBlob(float2 uv, float2 center, float spread) {
    float2 delta = uv - center;
    return exp(-dot(delta, delta) / spread);
}

// Returns the cobalt / coral / ink weights of the signal at a normalized point.
float3 voxolField(float2 uv, float mode, float time) {
    float x = uv.x;
    float y = uv.y;

    if (mode < 1.5) {
        // idle and voice share the two-wave form; voice simply carries more energy.
        float energy = mode < 0.5 ? 0.66 : 1.0;
        float waveA = 0.3 + voxolSin(x * 8.0 + time * 4.0) * 0.13;
        float waveB = 0.72 + voxolSin(x * 6.0 - time * 3.0 + 1.8) * 0.12;
        return float3(
            exp(-voxolSquared(y - waveA) / 0.014) * energy * (0.38 + x * 0.5),
            exp(-voxolSquared(y - waveB) / 0.012) * energy * (0.82 - x * 0.3),
            exp(-voxolSquared(y - 0.51) / 0.02) * 0.12
        );
    }

    if (mode < 2.5) {
        float radius = length(float2(x - 0.5, y - 0.5));
        float ring = 0.24 - voxolSin(time * 2.4) * 0.05;
        return float3(
            exp(-voxolSquared(radius - ring) / 0.005) * 0.64,
            exp(-voxolSquared(radius - 0.12) / 0.004) * 0.54,
            exp(-radius * 8.0) * 0.24
        );
    }

    if (mode < 3.5) {
        float trend = 0.72 - x * 0.38 + voxolSin(x * 12.0 + 0.8 + time * 0.8) * 0.07;
        float echo = 0.82 - x * 0.2 + voxolSin(x * 8.0 + 2.1 - time * 0.6) * 0.05;
        return float3(
            exp(-voxolSquared(y - trend) / 0.008) * (0.46 + x * 0.38),
            exp(-voxolSquared(y - echo) / 0.006) * (0.42 - x * 0.18),
            exp(-voxolSquared(y - 0.78) / 0.018) * 0.08
        );
    }

    if (mode < 4.5) {
        float upper = 0.33 + voxolSin(x * 8.0 + 0.4 + time * 0.9) * 0.08;
        float lower = 0.7 + voxolSin(x * 11.0 + 1.7 - time * 0.7) * 0.06;
        return float3(
            exp(-voxolSquared(y - upper) / 0.012) * (0.42 + x * 0.36),
            exp(-voxolSquared(y - lower) / 0.01) * (0.76 - x * 0.24),
            exp(-voxolSquared(y - 0.53) / 0.02) * 0.15
        );
    }

    if (mode < 5.5) {
        // Transformation: two diffuse fields converging on a ring at the centre.
        float radius = length(float2(x - 0.5, y - 0.5));
        float convergence =
            exp(-voxolSquared(radius - (0.17 + voxolSin(time * 1.6) * 0.02)) / 0.005);
        return float3(
            voxolBlob(uv, float2(0.1, 0.2), 0.16) * 0.42 + convergence * 0.18,
            voxolBlob(uv, float2(0.9, 0.8), 0.18) * 0.44 + convergence * 0.14,
            voxolBlob(uv, float2(0.5, 0.5), 0.24) * 0.09
        );
    }

    if (mode < 6.5) {
        // Permissions: three nodes orbiting the Seuil core.
        float cobalt = 0.0;
        float coral = 0.0;
        for (int node = 0; node < 3; node++) {
            float angle = time * 0.7 + float(node) * (2.0 * M_PI_F / 3.0);
            float2 center = float2(0.5 + voxolCos(angle) * 0.27, 0.42 + voxolSin(angle) * 0.27);
            float blob = voxolBlob(uv, center, 0.02);
            if (node == 1) {
                coral += blob * 0.5;
            } else {
                cobalt += blob * 0.42;
            }
        }
        float halo = exp(-voxolSquared(length(float2(x - 0.5, y - 0.42)) - 0.27) / 0.004);
        return float3(cobalt, coral, halo * 0.12);
    }

    if (mode < 7.5) {
        // Engines: two poles joined by a bridge, with a packet travelling across it.
        float bridgeY = 0.5 + voxolSin(x * 12.0 + time * 2.4) * 0.02;
        float bridge = exp(-voxolSquared(y - bridgeY) / 0.0026);
        float packetX = 0.26 + fmod(time * 0.18, 0.48);
        float packet = voxolBlob(uv, float2(packetX, 0.5), 0.0035);
        return float3(
            voxolBlob(uv, float2(0.22, 0.5), 0.055) * 0.34 + bridge * 0.24 + packet * 0.6,
            voxolBlob(uv, float2(0.78, 0.5), 0.055) * 0.38 + bridge * 0.16,
            bridge * 0.08
        );
    }

    // Ready: the signal resolves into a single concentric ring.
    float radius = length(float2(x - 0.5, y - 0.5));
    float ring = exp(-voxolSquared(radius - (0.22 + voxolSin(time * 1.2) * 0.015)) / 0.0045);
    return float3(
        ring * (x < 0.54 ? 0.54 : 0.18),
        ring * (x >= 0.46 ? 0.52 : 0.16),
        exp(-radius * 8.0) * 0.22
    );
}

}  // namespace

[[ stitchable ]] half4 voxolDither(
    float2 position,
    half4 currentColor,
    float2 size,
    float time,
    float modeA,
    float modeB,
    float blend,
    float pan,
    float focus,
    float focusSpread,
    float2 pointer,
    float pointerEnergy,
    float cellSize,
    half4 cobalt,
    half4 coral,
    half4 ink
) {
    if (size.x <= 0.0 || size.y <= 0.0) {
        return currentColor;
    }

    float2 cell = floor(position / cellSize);
    float2 origin = cell * cellSize;
    // `uv` is where the cell sits on screen; `sample` is where it reads the field from. Keeping
    // them apart means the pointer and the envelope stay anchored to the window while the field
    // itself travels with the thread.
    float2 uv = (origin + cellSize * 0.5) / size;
    float2 sample = float2(uv.x + pan, uv.y);

    // Two fields are always evaluated and crossed. The signal therefore morphs continuously
    // between acts instead of switching, which is the whole premise of the composition.
    float3 field;

    // The field answers the pointer: cells lean towards it and gain amplitude, so the whole page
    // feels like a material under the hand rather than a printed backdrop.
    float swell = 1.0;
    if (pointerEnergy > 0.001) {
        float2 toPointer = uv - pointer;
        toPointer.y *= 1.6;
        float halo = exp(-dot(toPointer, toPointer) / 0.012);
        sample -= toPointer * halo * 0.45;
        swell += halo * 2.4 * pointerEnergy;
    }

    field = voxolField(sample, modeA, time);
    if (blend > 0.001) {
        field = mix(field, voxolField(sample, modeB, time), blend);
    }
    field *= swell;

    // An optional vertical envelope gathers the signal onto a band. It is what keeps a full-bleed
    // field from turning into wallpaper behind the type: the dither belongs to the thread, and the
    // page stays ivory everywhere else.
    if (focusSpread > 0.0001) {
        float offset = uv.y - focus;
        field *= exp(-(offset * offset) / focusSpread);
    }
    float peak = max(field.x, max(field.y, field.z));
    if (peak <= 0.02) {
        return currentColor;
    }

    // A cell's grain decides which hue it can carry. The comparison is widened by the fade band
    // below so a dot has somewhere to fade from.
    // The grain keeps the leaving act's seed until the cross is past halfway, so the stipple does
    // not reshuffle underneath the fade.
    float grain = voxolHash(cell, voxolSeed(blend < 0.5 ? modeA : modeB));
    const float fade = 0.06;

    half4 tint;
    float strength;
    bool quiet;
    if (grain < field.x + fade) {
        tint = cobalt;
        strength = field.x;
        quiet = false;
    } else if (grain < field.y + fade) {
        tint = coral;
        strength = field.y;
        quiet = false;
    } else if (grain < field.z + fade) {
        tint = ink;
        strength = field.z;
        quiet = true;
    } else {
        return currentColor;
    }

    // Fade a dot in as the field rises past this cell's grain rather than switching it on: a
    // binary test makes a slow field read as sparse popping instead of flow.
    float presence = smoothstep(grain - fade, grain + fade, strength);
    if (presence <= 0.001) {
        return currentColor;
    }

    // Continuous size, so dots grow and shrink with the field instead of stepping between three
    // fixed sizes, and a soft edge so that growth is sub-pixel rather than jumping a whole point.
    float dotSize = mix(1.6, 4.0, saturate(strength / 0.7));
    float2 offset = abs(position - origin - cellSize * 0.5);
    float2 edge = saturate(dotSize * 0.5 - offset + 0.5);
    float coverage = edge.x * edge.y;
    if (coverage <= 0.001) {
        return currentColor;
    }

    // Ink is the quiet channel; it never reaches the weight of the two signal hues.
    float weight = saturate(strength);
    float alpha = (quiet ? mix(0.16, 0.5, weight) : mix(0.3, 0.92, weight)) * presence * coverage;

    half4 premultiplied = half4(tint.rgb * half(alpha), half(alpha));
    return premultiplied + currentColor * half(1.0 - alpha);
}

// The materialization effect.
//
// Any view can be handed to this and it stops being drawn: it is rebuilt out of the same dot grid
// as the signal. Cells fly in from the field, each on its own grain-driven delay, and only sharpen
// back into real pixels once they have landed. Running it as a layer effect means it works on type,
// panels, icons — anything — so the whole preflight is made of one material.
[[ stitchable ]] half4 voxolMaterialize(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float progress,
    float cellSize,
    float scatter,
    float seed,
    float2 origin,
    float originPull
) {
    if (progress >= 0.998) {
        return layer.sample(position);
    }
    if (progress <= 0.002) {
        return half4(0.0);
    }

    float2 cell = floor(position / cellSize);
    float2 centre = cell * cellSize + cellSize * 0.5;
    float grain = voxolHash(cell, seed);

    // A wave crosses the element while the grain scatters the arrivals around it, so the shape
    // assembles as a sweep rather than a uniform fade.
    float wave = clamp(centre.x / max(size.x, 1.0), 0.0, 1.0);
    float threshold = grain * 0.62 + wave * 0.38;
    float arrival = smoothstep(threshold - 0.22, threshold + 0.22, progress);
    if (arrival <= 0.002) {
        return half4(0.0);
    }

    float away = 1.0 - arrival;

    // Everything on the page is drawn out of a single point — the mark — and collapses back into
    // it. Content that belongs at L is currently at L*(1-k) + origin*k, so the pixel being shaded
    // has to read the layer at the inverse of that map.
    float pull = min(originPull * away, 0.86);
    float2 source = (centre - origin * pull) / max(1.0 - pull, 0.14);

    // A little jitter on top, so it reads as a swarm rather than a zoom.
    float angle = grain * 2.0 * M_PI_F;
    float2 jitter = float2(voxolCos(angle), voxolSin(angle)) * scatter * away;
    jitter.y *= 0.55;
    source += jitter;

    half4 sampled = layer.sample(source);
    if (sampled.a <= 0.002) {
        return half4(0.0);
    }

    // Each cell is a dot that grows into its square as it lands.
    float reach = cellSize * 0.5 * (0.22 + 0.78 * arrival);
    float2 delta = abs(position - centre);
    float cover = clamp(reach - max(delta.x, delta.y) + 0.5, 0.0, 1.0);

    half4 dotted = sampled * half(cover);
    half4 crisp = layer.sample(position);
    return mix(dotted, crisp, half(smoothstep(0.72, 1.0, arrival)));
}
