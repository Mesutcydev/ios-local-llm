//
//  VoiceOrbShaders.metal
//  VoiceOrb
//
//  A single, small stitchable distortion shader used for the orb's interior
//  light refraction. It is intentionally tiny: offsets stay within ±3 px so
//  `maxSampleOffset` can be 4 and sampling never smears the glass shell
//  (which lives on a separate, undistorted canvas).
//
//  The view only applies this on `.full` quality, on device builds, and
//  never with Reduce Motion. Every visual layer has a non-Metal fallback
//  (the same canvases render without the effect).
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// Gentle interior refraction.
/// - position: pixel position in the layer
/// - layer: the interior canvas contents
/// - time: continuous animation clock (seconds)
/// - intensity: 0...1 distortion strength (audio/energy reactive)
/// - viewSize: edge length of the square canvas in points
[[stitchable]] half4 voiceOrbRefraction(
    float2 position,
    SwiftUI::Layer layer,
    float time,
    float intensity,
    float viewSize
) {
    float2 uv = position / max(viewSize, 1.0);
    float2 centered = uv - 0.5;
    float r = length(centered) * 2.0; // 0 at center, 1 at orb boundary

    // Fade the effect out toward the rim so edges stay crisp.
    float falloff = smoothstep(1.0, 0.35, r);

    // Two low-frequency interference waves — calm, organic light bend.
    float wobble =
        sin(centered.y * 9.0 + time * 2.1) *
        sin(centered.x * 7.0 - time * 1.7);

    float magnitude = clamp(intensity, 0.0, 1.0) * falloff * 3.0; // ≤ 3 px
    float2 offset = float2(wobble, -wobble) * magnitude;

    return layer.sample(position + offset);
}
