#ifndef SHADOW_PCF_HLSLI
#define SHADOW_PCF_HLSLI

#include "ShadowCommon.hlsli"

float SampleShadowHard(
    Texture2D<float> shadowMap,
    SamplerComparisonState shadowSampler,
    float3 worldPos,
    float3 worldNormal,
    float NdotL,
    float4x4 lightViewProj)
{
    float3 shadowCoord = WorldToShadowUV(worldPos, worldNormal, NdotL, lightViewProj);
    
    if (!IsValidShadowUV(shadowCoord.xy))
        return 1.0f;
    
    float bias = CalculateAdaptiveBias(NdotL, shadowCoord.z);
    float depth = shadowCoord.z - bias;
    
    return shadowMap.SampleCmpLevelZero(shadowSampler, shadowCoord.xy, depth);
}

//-----------------------------------------------------------------------------
// PCF 3x3
//-----------------------------------------------------------------------------

float SampleShadowPCF3x3(
    Texture2D<float> shadowMap,
    SamplerComparisonState shadowSampler,
    float3 worldPos,
    float3 worldNormal,
    float NdotL,
    float4x4 lightViewProj,
    float shadowMapSize)
{
    float3 shadowCoord = WorldToShadowUV(worldPos, worldNormal, NdotL, lightViewProj);
    
    if (!IsValidShadowUV(shadowCoord.xy))
        return 1.0f;
    
    float bias = CalculateAdaptiveBias(NdotL, shadowCoord.z);
    float depth = shadowCoord.z - bias;
    float texelSize = 1.0f / shadowMapSize;
    
    float shadow = 0.0f;
    
    [unroll]
    for (int x = -1; x <= 1; ++x)
    {
        [unroll]
        for (int y = -1; y <= 1; ++y)
        {
            float2 offset = float2(x, y) * texelSize;
            shadow += shadowMap.SampleCmpLevelZero(
                shadowSampler, 
                shadowCoord.xy + offset, 
                depth
            );
        }
    }
    
    return shadow / 9.0f;
}

//-----------------------------------------------------------------------------
// PCF 5x5 (recommended default)
//-----------------------------------------------------------------------------

float SampleShadowPCF5x5(
    Texture2D<float> shadowMap,
    SamplerComparisonState shadowSampler,
    float3 worldPos,
    float3 worldNormal,
    float NdotL,
    float4x4 lightViewProj,
    float shadowMapSize)
{
    float3 shadowCoord = WorldToShadowUV(worldPos, worldNormal, NdotL, lightViewProj);
    
    if (!IsValidShadowUV(shadowCoord.xy))
        return 1.0f;
    
    float bias = CalculateAdaptiveBias(NdotL, shadowCoord.z);
    float depth = shadowCoord.z - bias;
    float texelSize = 1.0f / shadowMapSize;
    
    float shadow = 0.0f;
    
    [unroll]
    for (int x = -2; x <= 2; ++x)
    {
        [unroll]
        for (int y = -2; y <= 2; ++y)
        {
            float2 offset = float2(x, y) * texelSize;
            shadow += shadowMap.SampleCmpLevelZero(
                shadowSampler, 
                shadowCoord.xy + offset, 
                depth
            );
        }
    }
    
    return shadow / 25.0f;
}

//-----------------------------------------------------------------------------
// PCF 7x7 (high quality)
//-----------------------------------------------------------------------------

float SampleShadowPCF7x7(
    Texture2D<float> shadowMap,
    SamplerComparisonState shadowSampler,
    float3 worldPos,
    float3 worldNormal,
    float NdotL,
    float4x4 lightViewProj,
    float shadowMapSize)
{
    float3 shadowCoord = WorldToShadowUV(worldPos, worldNormal, NdotL, lightViewProj);
    
    if (!IsValidShadowUV(shadowCoord.xy))
        return 1.0f;
    
    float bias = CalculateAdaptiveBias(NdotL, shadowCoord.z);
    float depth = shadowCoord.z - bias;
    float texelSize = 1.0f / shadowMapSize;
    
    float shadow = 0.0f;
    
    [unroll]
    for (int x = -3; x <= 3; ++x)
    {
        [unroll]
        for (int y = -3; y <= 3; ++y)
        {
            float2 offset = float2(x, y) * texelSize;
            shadow += shadowMap.SampleCmpLevelZero(
                shadowSampler, 
                shadowCoord.xy + offset, 
                depth
            );
        }
    }
    
    return shadow / 49.0f;
}

//-----------------------------------------------------------------------------
// Poisson Disk PCF (high quality, more natural soft edges)
//-----------------------------------------------------------------------------

float SampleShadowPCFPoisson16(
    Texture2D<float> shadowMap,
    SamplerComparisonState shadowSampler,
    float3 worldPos,
    float3 worldNormal,
    float NdotL,
    float4x4 lightViewProj,
    float shadowMapSize,
    float2 screenPos)  // Screen position for random rotation
{
    float3 shadowCoord = WorldToShadowUV(worldPos, worldNormal, NdotL, lightViewProj);
    
    if (!IsValidShadowUV(shadowCoord.xy))
        return 1.0f;
    
    float bias = CalculateAdaptiveBias(NdotL, shadowCoord.z);
    float depth = shadowCoord.z - bias;
    float texelSize = 1.0f / shadowMapSize;
    
    // Randomly rotate samples to reduce banding artifacts
    float rotation = GetRandomRotation(screenPos);
    
    float shadow = 0.0f;
    float radius = PENUMBRA_SIZE;  // Sample radius
    
    [unroll]
    for (int i = 0; i < 16; ++i)
    {
        float2 offset = RotateVector(PoissonDisk16[i], rotation) * radius * texelSize;
        shadow += shadowMap.SampleCmpLevelZero(
            shadowSampler, 
            shadowCoord.xy + offset, 
            depth
        );
    }
    
    return shadow / 16.0f;
}

//-----------------------------------------------------------------------------
// Weighted PCF (higher center weight, approximates Gaussian filter)
//-----------------------------------------------------------------------------

float SampleShadowPCFWeighted(
    Texture2D<float> shadowMap,
    SamplerComparisonState shadowSampler,
    float3 worldPos,
    float3 worldNormal,
    float NdotL,
    float4x4 lightViewProj,
    float shadowMapSize)
{
    float3 shadowCoord = WorldToShadowUV(worldPos, worldNormal, NdotL, lightViewProj);
    
    if (!IsValidShadowUV(shadowCoord.xy))
        return 1.0f;
    
    float bias = CalculateAdaptiveBias(NdotL, shadowCoord.z);
    float depth = shadowCoord.z - bias;
    float texelSize = 1.0f / shadowMapSize;
    
    // 5x5 Gaussian weights (approximate)
    static const float weights[5][5] = 
    {
        { 1,  4,  6,  4, 1 },
        { 4, 16, 24, 16, 4 },
        { 6, 24, 36, 24, 6 },
        { 4, 16, 24, 16, 4 },
        { 1,  4,  6,  4, 1 }
    };
    static const float weightSum = 256.0f;
    
    float shadow = 0.0f;
    
    [unroll]
    for (int x = -2; x <= 2; ++x)
    {
        [unroll]
        for (int y = -2; y <= 2; ++y)
        {
            float2 offset = float2(x, y) * texelSize;
            float w = weights[x + 2][y + 2];
            shadow += shadowMap.SampleCmpLevelZero(
                shadowSampler, 
                shadowCoord.xy + offset, 
                depth
            ) * w;
        }
    }
    
    return shadow / weightSum;
}

//-----------------------------------------------------------------------------
// PCSS (Percentage Closer Soft Shadows) — variable penumbra
//-----------------------------------------------------------------------------

// Search for average occluder depth
float FindBlockerDepth(
    Texture2D<float> shadowMap,
    SamplerState pointSampler,
    float2 shadowUV,
    float receiverDepth,
    float texelSize,
    float searchRadius,
    float2 screenPos)
{
    float blockerSum = 0.0f;
    int blockerCount = 0;
    float rotation = GetRandomRotation(screenPos);
    
    [unroll]
    for (int i = 0; i < 16; ++i)
    {
        float2 offset = RotateVector(PoissonDisk16[i], rotation) * searchRadius * texelSize;
        float sampleDepth = shadowMap.SampleLevel(pointSampler, shadowUV + offset, 0);
        
        if (sampleDepth < receiverDepth)
        {
            blockerSum += sampleDepth;
            blockerCount++;
        }
    }
    
    if (blockerCount == 0)
        return -1.0f;  // No occluder
    
    return blockerSum / (float)blockerCount;
}

float SampleShadowPCSS(
    Texture2D<float> shadowMap,
    SamplerComparisonState shadowSampler,
    SamplerState pointSampler,
    float3 worldPos,
    float3 worldNormal,
    float NdotL,
    float4x4 lightViewProj,
    float shadowMapSize,
    float lightSize,
    float2 screenPos)
{
    float3 shadowCoord = WorldToShadowUV(worldPos, worldNormal, NdotL, lightViewProj);
    
    if (!IsValidShadowUV(shadowCoord.xy))
        return 1.0f;
    
    float bias = CalculateAdaptiveBias(NdotL, shadowCoord.z);
    float depth = shadowCoord.z - bias;
    float texelSize = 1.0f / shadowMapSize;
    
    // Step 1: Search for occluders
    float searchRadius = lightSize * 10.0f;  // Search radius
    float blockerDepth = FindBlockerDepth(
        shadowMap, pointSampler,
        shadowCoord.xy, depth,
        texelSize, searchRadius, screenPos
    );
    
    if (blockerDepth < 0.0f)
        return 1.0f;  // No occluder — fully lit
    
    // Step 2: Compute penumbra size
    float penumbraWidth = (depth - blockerDepth) / blockerDepth * lightSize;
    penumbraWidth = clamp(penumbraWidth, 1.0f, 20.0f);
    
    // Step 3: Variable-radius PCF
    float shadow = 0.0f;
    float rotation = GetRandomRotation(screenPos);
    
    [unroll]
    for (int i = 0; i < 32; ++i)
    {
        float2 offset = RotateVector(PoissonDisk32[i], rotation) * penumbraWidth * texelSize;
        shadow += shadowMap.SampleCmpLevelZero(
            shadowSampler,
            shadowCoord.xy + offset,
            depth
        );
    }
    
    return shadow / 32.0f;
}

//-----------------------------------------------------------------------------
// Convenience wrapper (default PCF 5x5)
//-----------------------------------------------------------------------------

float SampleShadowPCF(
    Texture2D<float> shadowMap,
    SamplerComparisonState shadowSampler,
    float3 worldPos,
    float3 worldNormal,
    float NdotL,
    float4x4 lightViewProj,
    float shadowMapSize)
{
    return SampleShadowPCF5x5(shadowMap, shadowSampler, worldPos, worldNormal, NdotL, lightViewProj, shadowMapSize);
}

//-----------------------------------------------------------------------------
// Cascaded Shadow Map sampling
//-----------------------------------------------------------------------------

int SelectCascade(float viewDepth, float4 cascadeSplits)
{
    int cascade = 0;
    if (viewDepth > cascadeSplits.x) cascade = 1;
    if (viewDepth > cascadeSplits.y) cascade = 2;
    if (viewDepth > cascadeSplits.z) cascade = 3;
    return min(cascade, CASCADE_COUNT - 1);
}

float SampleShadowCSM(
    Texture2DArray<float> shadowMapArray,
    SamplerComparisonState shadowSampler,
    float3 worldPos,
    float NdotL,
    float viewDepth,
    float4x4 cascadeViewProj[CASCADE_COUNT],
    float4 cascadeSplits,
    float shadowMapSize)
{
    int cascade = SelectCascade(viewDepth, cascadeSplits);
    
    // Column-vector form
    float4 lightSpacePos = mul(cascadeViewProj[cascade], float4(worldPos, 1.0f));
    lightSpacePos.xyz /= lightSpacePos.w;
    
    float2 shadowUV = lightSpacePos.xy * 0.5f + 0.5f;
    shadowUV.y = 1.0f - shadowUV.y;
    
    if (!IsValidShadowUV(shadowUV))
        return 1.0f;
    
    // Scale bias by cascade level (distant cascades need larger bias)
    float cascadeBias = SHADOW_BIAS * (1.0f + cascade * 0.5f);
    float bias = CalculateAdaptiveBias(NdotL, lightSpacePos.z) + cascadeBias;
    float depth = lightSpacePos.z - bias;
    
    float texelSize = 1.0f / shadowMapSize;
    float shadow = 0.0f;
    
    // 3x3 PCF (smaller kernel per cascade for performance)
    [unroll]
    for (int x = -1; x <= 1; ++x)
    {
        [unroll]
        for (int y = -1; y <= 1; ++y)
        {
            float3 uvw = float3(shadowUV + float2(x, y) * texelSize, (float)cascade);
            shadow += shadowMapArray.SampleCmpLevelZero(shadowSampler, uvw, depth);
        }
    }
    
    return shadow / 9.0f;
}

//-----------------------------------------------------------------------------
// Debug visualization
//-----------------------------------------------------------------------------

float3 VisualizeShadowCascade(float viewDepth, float4 cascadeSplits)
{
    int cascade = SelectCascade(viewDepth, cascadeSplits);
    
    // Different color per cascade
    static const float3 cascadeColors[4] = 
    {
        float3(1, 0, 0),  // Red   — nearest
        float3(0, 1, 0),  // Green
        float3(0, 0, 1),  // Blue
        float3(1, 1, 0)   // Yellow — farthest
    };
    
    return cascadeColors[cascade];
}

#endif // SHADOW_PCF_HLSLI
