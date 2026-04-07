//=============================================================================
// SDFShadow.hlsli
// SDF-based soft shadows using Global SDF
//=============================================================================

#ifndef SDF_SHADOW_HLSLI
#define SDF_SHADOW_HLSLI

//-----------------------------------------------------------------------------
// Configuration
//-----------------------------------------------------------------------------

#ifndef SDF_SHADOW_MAX_STEPS
#define SDF_SHADOW_MAX_STEPS 32
#endif

#ifndef SDF_SHADOW_MAX_DISTANCE
#define SDF_SHADOW_MAX_DISTANCE 100.0f
#endif

#ifndef SDF_SHADOW_MIN_DISTANCE
#define SDF_SHADOW_MIN_DISTANCE 0.1f
#endif

#ifndef SDF_SHADOW_SOFTNESS
#define SDF_SHADOW_SOFTNESS 8.0f  // Higher = harder shadow, lower = softer
#endif

#ifndef SDF_SHADOW_BIAS
#define SDF_SHADOW_BIAS 1.0f  // Start offset to avoid self-shadowing
#endif

#ifndef SDF_SHADOW_HIT_THRESHOLD
#define SDF_SHADOW_HIT_THRESHOLD 0.01f  // Hit threshold
#endif

//-----------------------------------------------------------------------------
// Coordinate conversion — consistent with VoxelSDFTrace.hlsl
//-----------------------------------------------------------------------------

float3 WorldToSDFUV_Shadow(float3 worldPos, float3 sdfCenter, float sdfExtent)
{
    // Formula: (worldPos - center) / extent + 0.5
    // extent is the half-size; UV [0,1] maps to [center-extent, center+extent]
    return (worldPos - sdfCenter) / sdfExtent + 0.5f;
}

float SampleSDFDistance(Texture3D<float2> globalSDF, SamplerState sdfSampler,
                        float3 worldPos, float3 sdfCenter, float sdfExtent)
{
    float3 sdfUV = WorldToSDFUV_Shadow(worldPos, sdfCenter, sdfExtent);

    if (any(sdfUV < 0.0f) || any(sdfUV > 1.0f))
        return 1000.0f;

    // SDF texture stores normalized distance; multiply by extent for world-space distance
    float normalizedDist = globalSDF.SampleLevel(sdfSampler, sdfUV, 0).r;
    return normalizedDist * sdfExtent;
}

//-----------------------------------------------------------------------------
// SDF soft shadow trace
// Based on Inigo Quilez's soft shadow algorithm
// https://iquilezles.org/articles/rmshadows/
//-----------------------------------------------------------------------------

float TraceSDFSoftShadow(
    Texture3D<float2> globalSDF,
    SamplerState sdfSampler,
    float3 sdfCenter,
    float sdfExtent,
    float3 rayOrigin,
    float3 rayDir,
    float maxDist,
    float softness)
{
    float shadow = 1.0f;
    float t = SDF_SHADOW_BIAS;

    [loop]
    for (int i = 0; i < SDF_SHADOW_MAX_STEPS && t < maxDist; i++)
    {
        float3 pos = rayOrigin + rayDir * t;

        float dist = SampleSDFDistance(globalSDF, sdfSampler, pos, sdfCenter, sdfExtent);

        // Out of range
        if (dist >= 999.0f)
            break;

        // Surface hit
        if (dist < SDF_SHADOW_HIT_THRESHOLD)
            return 0.0f;

        // Soft shadow
        float penumbra = softness * dist / t;
        shadow = min(shadow, penumbra);

        // Step (world-space distance)
        t += max(dist * 0.9f, 0.1f);
    }

    return saturate(shadow);
}

// Improved soft shadow — smoother penumbra transition
float TraceSDFSoftShadowImproved(
    Texture3D<float2> globalSDF,
    SamplerState sdfSampler,
    float3 sdfCenter,
    float sdfExtent,
    float3 rayOrigin,
    float3 rayDir,
    float maxDist,
    float softness)
{
    float shadow = 1.0f;
    float t = SDF_SHADOW_BIAS;

    [loop]
    for (int i = 0; i < SDF_SHADOW_MAX_STEPS && t < maxDist; i++)
    {
        float3 pos = rayOrigin + rayDir * t;

        float dist = SampleSDFDistance(globalSDF, sdfSampler, pos, sdfCenter, sdfExtent);

        // Outside SDF bounds — assume unoccluded
        if (dist >= 999.0f)
            break;

        // Negative or near-zero: inside geometry or hit
        // Don't return full black; preserve some soft shadow
        if (dist < SDF_SHADOW_HIT_THRESHOLD)
        {
            shadow = min(shadow, 0.1f);  // Avoid full black to prevent acne
            break;
        }

        // Soft shadow (simplified, more stable)
        float penumbra = softness * dist / t;
        shadow = min(shadow, saturate(penumbra));

        // Step
        t += max(dist * 0.8f, 0.2f);
    }

    // Smooth output
    return smoothstep(0.0f, 1.0f, shadow);
}

//-----------------------------------------------------------------------------
// Convenience functions
//-----------------------------------------------------------------------------

// Directional (sun) SDF shadow
float SampleSDFSunShadow(
    Texture3D<float2> globalSDF,
    SamplerState sdfSampler,
    float3 sdfCenter,
    float sdfExtent,
    float3 worldPos,
    float3 worldNormal,
    float3 sunDir)  // Direction toward sun (opposite of SunNormal)
{
    // Offset start point along normal to avoid self-shadowing
    float3 rayOrigin = worldPos + worldNormal * SDF_SHADOW_BIAS;

    return TraceSDFSoftShadowImproved(
        globalSDF,
        sdfSampler,
        sdfCenter,
        sdfExtent,
        rayOrigin,
        sunDir,
        SDF_SHADOW_MAX_DISTANCE,
        SDF_SHADOW_SOFTNESS
    );
}

// Point light SDF shadow
float SampleSDFPointShadow(
    Texture3D<float2> globalSDF,
    SamplerState sdfSampler,
    float3 sdfCenter,
    float sdfExtent,
    float3 worldPos,
    float3 worldNormal,
    float3 lightPos)
{
    float3 toLight = lightPos - worldPos;
    float lightDist = length(toLight);
    float3 lightDir = toLight / lightDist;

    // Offset along normal
    float3 rayOrigin = worldPos + worldNormal * SDF_SHADOW_BIAS;

    // Softness scales with distance (softer near the light)
    float softness = SDF_SHADOW_SOFTNESS * (1.0f + 10.0f / lightDist);

    return TraceSDFSoftShadowImproved(
        globalSDF,
        sdfSampler,
        sdfCenter,
        sdfExtent,
        rayOrigin,
        lightDir,
        lightDist - SDF_SHADOW_BIAS,  // Do not exceed light distance
        softness
    );
}

//-----------------------------------------------------------------------------
// Blended shadow — Shadow Map + SDF
//-----------------------------------------------------------------------------

// Strategy 1: min (safer, prevents light leaking)
float CombineShadowMin(float shadowMap, float sdfShadow)
{
    return min(shadowMap, sdfShadow);
}

// Strategy 2: multiply (softer result)
float CombineShadowMultiply(float shadowMap, float sdfShadow)
{
    return shadowMap * sdfShadow;
}

// Strategy 3: distance blend (shadow map near, SDF far)
float CombineShadowDistanceBased(float shadowMap, float sdfShadow, float depth, float nearDist, float farDist)
{
    float blend = saturate((depth - nearDist) / (farDist - nearDist));
    return lerp(shadowMap, sdfShadow, blend);
}

// Recommended: adaptive blend
// Shadow map: accurate contact shadows at close range
// SDF: soft shadows at range, prevents peter-panning
float CombineShadowAdaptive(float shadowMap, float sdfShadow, float NdotL)
{
    // Grazing angles (small NdotL): rely more on SDF to avoid shadow acne
    // Front-facing (large NdotL): shadow map is reliable
    float sdfWeight = 1.0f - NdotL * NdotL;  // Higher SDF weight at grazing angles

    float combined = lerp(
        min(shadowMap, sdfShadow),      // Front-facing: take minimum
        sdfShadow,                       // Grazing: use SDF
        sdfWeight * 0.5f                 // Smooth transition
    );

    return combined;
}

#endif // SDF_SHADOW_HLSLI
