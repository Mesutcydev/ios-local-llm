#include <metal_stdlib>
using namespace metal;

constant float orbPi = 3.14159265359;

struct ThinkingOrbUniforms {
    float4 state;
    float4 presentation;
    float4 geometry;
};

struct OrbPoint {
    float3 position;
    float size;
    float shade;
    float opacity;
};

struct OrbVertexOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 color;
};

float orbHash(float value) {
    return fract(sin(value * 12.9898 + 78.233) * 43758.5453);
}

float3 orbRotateY(float3 point, float angle) {
    float sine = sin(angle);
    float cosine = cos(angle);
    return float3(
        point.x * cosine + point.z * sine,
        point.y,
        -point.x * sine + point.z * cosine
    );
}

float3 orbRotateX(float3 point, float angle) {
    float sine = sin(angle);
    float cosine = cos(angle);
    return float3(
        point.x,
        point.y * cosine - point.z * sine,
        point.y * sine + point.z * cosine
    );
}

float orbShortestAngle(float lhs, float rhs) {
    return atan2(sin(lhs - rhs), cos(lhs - rhs));
}

float2 orbTriangle(float position) {
    float segment = position * 3.0;
    float local = fract(segment);
    float2 a = float2(0.0, 0.78);
    float2 b = float2(0.72, -0.48);
    float2 c = float2(-0.72, -0.48);
    if (segment < 1.0) return mix(a, b, local);
    if (segment < 2.0) return mix(b, c, local);
    return mix(c, a, local);
}

float2 orbSquare(float position) {
    float segment = position * 4.0;
    float local = fract(segment);
    float2 a = float2(-0.62, 0.62);
    float2 b = float2(0.62, 0.62);
    float2 c = float2(0.62, -0.62);
    float2 d = float2(-0.62, -0.62);
    if (segment < 1.0) return mix(a, b, local);
    if (segment < 2.0) return mix(b, c, local);
    if (segment < 3.0) return mix(c, d, local);
    return mix(d, a, local);
}

float2 orbShape(int shape, float position) {
    if (shape == 0) {
        float angle = -orbPi * 0.5 + position * 2.0 * orbPi;
        return float2(cos(angle), sin(angle)) * 0.68;
    }
    if (shape == 1) return orbTriangle(position);
    return orbSquare(position);
}

OrbPoint orbWorking(uint index, float time) {
    uint orbit = (index / 43u) % 12u;
    uint item = index % 43u;
    float randomA = orbHash(float(orbit) + 1.7);
    float randomB = orbHash(float(orbit) + 5.2);
    float randomC = orbHash(float(orbit) + 8.9);
    float azimuth = randomA * 2.0 * orbPi;
    float polar = acos(2.0 * randomB - 1.0);
    float3 normal = float3(
        sin(polar) * cos(azimuth),
        cos(polar),
        sin(polar) * sin(azimuth)
    );
    float3 tangent = normalize(float3(-normal.y, normal.x, 0.001));
    float3 bitangent = normalize(cross(normal, tangent));
    bool particle = item % 14u == 0u;
    float direction = randomC > 0.5 ? 1.0 : -1.0;
    float angle = float(item) / 43.0 * 2.0 * orbPi;
    angle += time * (particle ? direction * (0.25 + 0.55 * randomC) : 0.045);
    float radius = 0.36 + 0.38 * randomA;
    float3 point = (tangent * cos(angle) + bitangent * sin(angle)) * radius;
    point = orbRotateY(orbRotateX(point, 0.28), time * 0.12);
    float depth = clamp(point.z * 0.7 + 0.5, 0.0, 1.0);
    OrbPoint result;
    result.position = point;
    result.size = particle ? mix(4.2, 7.0, depth) : 2.15;
    result.shade = particle ? mix(0.28, 0.07, depth) : 0.68;
    result.opacity = particle ? 1.0 : mix(0.22, 0.52, depth);
    return result;
}

OrbPoint orbSearching(uint index, float time) {
    uint latitudeIndex = index / 32u;
    uint longitudeIndex = index % 32u;
    float latitude = -orbPi * 0.5 + float(latitudeIndex) / 15.0 * orbPi;
    float longitude = float(longitudeIndex) / 32.0 * 2.0 * orbPi;
    float horizontal = cos(latitude);
    float3 point = float3(
        horizontal * cos(longitude),
        sin(latitude),
        horizontal * sin(longitude)
    ) * 0.72;
    point = orbRotateY(orbRotateX(point, 0.38), time * 0.5);
    float scan = time * 1.45;
    float delta = orbShortestAngle(longitude + time * 0.5, scan);
    float highlight = exp(-(delta * delta) / 0.18) * max(0.0, point.z + 0.25);
    float depth = clamp(point.z * 0.7 + 0.5, 0.0, 1.0);
    OrbPoint result;
    result.position = point;
    result.size = mix(2.1, 5.0, depth) + highlight * 2.2;
    result.shade = clamp(0.64 - depth * 0.55 - highlight * 0.18, 0.04, 0.8);
    result.opacity = 0.42 + min(highlight, 0.58);
    return result;
}

OrbPoint orbSolving(uint index, float time) {
    uint latitudeIndex = index / 32u;
    uint longitudeIndex = index % 32u;
    float latitude = -orbPi * 0.5 + float(latitudeIndex) / 15.0 * orbPi;
    float longitude = float(longitudeIndex) / 32.0 * 2.0 * orbPi;
    float horizontal = cos(latitude);
    float3 point = float3(
        horizontal * cos(longitude),
        sin(latitude),
        horizontal * sin(longitude)
    );

    float sequence = time * 0.72;
    float completed = floor(sequence);
    float fraction = smoothstep(0.0, 0.72, fract(sequence));
    float band = floor((point.y + 1.0) * 4.0);
    float direction = fmod(band, 2.0) < 1.0 ? 1.0 : -1.0;
    float bandPhase = (completed + fraction) * direction * orbPi * 0.5;
    point = orbRotateY(point, bandPhase + time * 0.18);
    point = orbRotateX(point, 0.34);
    point *= 0.72;
    float depth = clamp(point.z * 0.7 + 0.5, 0.0, 1.0);
    OrbPoint result;
    result.position = point;
    result.size = mix(2.1, 5.1, depth);
    result.shade = mix(0.64, 0.07, depth);
    result.opacity = 0.92;
    return result;
}

OrbPoint orbListening(uint index, float time, float activity) {
    uint ring = (index / 43u) % 12u;
    uint longitudeIndex = index % 43u;
    float latitude = -orbPi * 0.5 + float(ring) / 11.0 * orbPi;
    float longitude = float(longitudeIndex) / 43.0 * 2.0 * orbPi;
    float response = 0.35 + 1.05 * clamp(activity * 1.8, 0.0, 1.0);
    float wave = response * (
        0.62 * sin(time * 2.1 - float(ring) * 0.52)
        + 0.38 * sin(time * 1.27 + float(ring) * 0.83)
    );
    float radius = 0.67 * (0.88 + 0.115 * wave);
    float horizontal = cos(latitude);
    float3 point = float3(
        horizontal * cos(longitude) * radius,
        sin(latitude) * radius,
        horizontal * sin(longitude) * radius
    );
    point = orbRotateY(orbRotateX(point, 0.36), time * 0.18);
    float depth = clamp(point.z * 0.75 + 0.5, 0.0, 1.0);
    float crest = max(wave, 0.0);
    OrbPoint result;
    result.position = point;
    result.size = mix(2.0, 5.2, depth) * (1.0 + 0.34 * crest);
    result.shade = clamp(0.68 - depth * 0.58 - crest * 0.08, 0.04, 0.82);
    result.opacity = 0.95;
    return result;
}

OrbPoint orbComposing(uint index, float time, float activity) {
    uint lane = (index / 43u) % 12u;
    uint segment = index % 43u;
    float angle = float(segment) / 43.0 * 2.0 * orbPi;
    float offset = (float(lane) - 5.5) * 0.075;
    float edge = abs(float(lane) - 5.5) / 5.5;
    float response = 0.52 + 1.05 * clamp(activity * 1.6, 0.0, 1.0);
    float wobble = response * (
        0.16 * sin(angle * 3.0 - time * 1.7 + float(lane) * 0.22)
        + 0.07 * sin(angle * 5.0 + time * 1.1)
    );
    float3 normal = float3(1.0, 0.0, 0.0);
    float3 tangent = float3(0.0, cos(0.55), sin(0.55));
    float3 bitangent = cross(normal, tangent);
    float3 point = normalize(
        normal * cos(angle)
        + tangent * sin(angle)
        + bitangent * (offset + wobble)
    ) * 0.7;
    point = orbRotateX(point, 0.28);
    float depth = clamp(point.z * 0.72 + 0.5, 0.0, 1.0);
    OrbPoint result;
    result.position = point;
    result.size = mix(2.7, 5.6, depth) * (1.0 - 0.22 * edge);
    result.shade = clamp(0.54 - depth * 0.46 + edge * 0.16, 0.05, 0.8);
    result.opacity = mix(0.4, 1.0, depth);
    return result;
}

OrbPoint orbShaping(uint index, float time) {
    bool visible = index % 8u == 0u;
    float position = float(index / 8u) / 64.0;
    float cycle = fmod(time, 6.9);
    int shape = int(floor(cycle / 2.3));
    float within = cycle - float(shape) * 2.3;
    float blend = smoothstep(1.4, 2.3, within);
    float2 from = orbShape(shape, position);
    float2 to = orbShape((shape + 1) % 3, position);
    float pulse = 1.0 + 0.018 * sin(within * 3.1);
    float2 point2D = mix(from, to, blend) * pulse;
    OrbPoint result;
    result.position = float3(point2D, 0.0);
    result.size = 5.8;
    result.shade = 0.1;
    result.opacity = visible ? 1.0 : 0.0;
    return result;
}

OrbPoint orbPointForMode(int mode, uint index, float time, float activity) {
    switch (mode) {
        case 0: return orbWorking(index, time * 1.885);
        case 1: return orbSearching(index, time * 2.015);
        case 2: return orbSolving(index, time * 1.82);
        case 3: return orbListening(index, time * 2.15, activity);
        case 4: return orbComposing(index, time * 2.34, activity);
        default: return orbShaping(index, time * 2.405);
    }
}

vertex OrbVertexOut thinkingOrbVertex(
    uint vertexID [[vertex_id]],
    constant ThinkingOrbUniforms &uniforms [[buffer(0)]]
) {
    uint stride = uint(max(uniforms.presentation.w, 1.0));
    uint logicalIndex = vertexID * stride;
    float time = uniforms.state.x;
    float activity = uniforms.state.y;
    int currentMode = int(uniforms.state.z + 0.5);
    int previousMode = int(uniforms.state.w + 0.5);
    float transition = uniforms.presentation.x;
    OrbPoint previous = orbPointForMode(previousMode, logicalIndex, time, activity);
    OrbPoint current = orbPointForMode(currentMode, logicalIndex, time, activity);

    OrbPoint point;
    point.position = mix(previous.position, current.position, transition);
    point.size = mix(previous.size, current.size, transition);
    point.shade = mix(previous.shade, current.shade, transition);
    point.opacity = mix(previous.opacity, current.opacity, transition);

    float aspect = max(uniforms.geometry.x, 0.001);
    float2 clipPosition = point.position.xy;
    if (aspect > 1.0) clipPosition.x /= aspect;
    else clipPosition.y *= aspect;

    float component = uniforms.presentation.y > 0.5
        ? 1.0 - point.shade
        : point.shade;
    OrbVertexOut output;
    output.position = float4(clipPosition, 0.0, 1.0);
    output.pointSize = max(1.0, point.size * uniforms.presentation.z);
    output.color = float4(component, component, component, point.opacity);
    return output;
}

fragment float4 thinkingOrbFragment(
    OrbVertexOut input [[stage_in]],
    float2 pointCoordinate [[point_coord]]
) {
    float2 centered = pointCoordinate * 2.0 - 1.0;
    float distanceFromCenter = length(centered);
    float coverage = 1.0 - smoothstep(0.78, 1.0, distanceFromCenter);
    if (coverage <= 0.001 || input.color.a <= 0.001) discard_fragment();
    return float4(input.color.rgb, input.color.a * coverage);
}
