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
// PCF 5x5（推荐默认使用）
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
// PCF 7x7（高质量）
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
// Poisson Disk PCF（高质量，更自然的软边缘）
//-----------------------------------------------------------------------------

float SampleShadowPCFPoisson16(
    Texture2D<float> shadowMap,
    SamplerComparisonState shadowSampler,
    float3 worldPos,
    float3 worldNormal,
    float NdotL,
    float4x4 lightViewProj,
    float shadowMapSize,
    float2 screenPos)  // 用于随机旋转
{
    float3 shadowCoord = WorldToShadowUV(worldPos, worldNormal, NdotL, lightViewProj);
    
    if (!IsValidShadowUV(shadowCoord.xy))
        return 1.0f;
    
    float bias = CalculateAdaptiveBias(NdotL, shadowCoord.z);
    float depth = shadowCoord.z - bias;
    float texelSize = 1.0f / shadowMapSize;
    
    // 随机旋转采样点（减少条纹artifact）
    float rotation = GetRandomRotation(screenPos);
    
    float shadow = 0.0f;
    float radius = PENUMBRA_SIZE;  // 采样半径
    
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
// 加权PCF（中心权重更高，模拟高斯滤波）
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
    
    // 5x5 高斯权重（近似）
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
// PCSS (Percentage Closer Soft Shadows) - 可变半影
//-----------------------------------------------------------------------------

// 搜索遮挡物平均深度
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
        return -1.0f;  // 无遮挡
    
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
    
    // 第一步：搜索遮挡物
    float searchRadius = lightSize * 10.0f;  // 搜索范围
    float blockerDepth = FindBlockerDepth(
        shadowMap, pointSampler,
        shadowCoord.xy, depth,
        texelSize, searchRadius, screenPos
    );
    
    if (blockerDepth < 0.0f)
        return 1.0f;  // 无遮挡，完全光照
    
    // 第二步：计算半影大小
    float penumbraWidth = (depth - blockerDepth) / blockerDepth * lightSize;
    penumbraWidth = clamp(penumbraWidth, 1.0f, 20.0f);
    
    // 第三步：使用可变半径的PCF
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
// 便捷接口（使用默认PCF 5x5）
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
// Cascaded Shadow Map 采样
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
    
    // 修复：使用列向量形式
    float4 lightSpacePos = mul(cascadeViewProj[cascade], float4(worldPos, 1.0f));
    lightSpacePos.xyz /= lightSpacePos.w;
    
    float2 shadowUV = lightSpacePos.xy * 0.5f + 0.5f;
    shadowUV.y = 1.0f - shadowUV.y;
    
    if (!IsValidShadowUV(shadowUV))
        return 1.0f;
    
    // 根据cascade级别调整bias（远处需要更大bias）
    float cascadeBias = SHADOW_BIAS * (1.0f + cascade * 0.5f);
    float bias = CalculateAdaptiveBias(NdotL, lightSpacePos.z) + cascadeBias;
    float depth = lightSpacePos.z - bias;
    
    float texelSize = 1.0f / shadowMapSize;
    float shadow = 0.0f;
    
    // 3x3 PCF（CSM每级用较小的核以提升性能）
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
// 调试可视化
//-----------------------------------------------------------------------------

float3 VisualizeShadowCascade(float viewDepth, float4 cascadeSplits)
{
    int cascade = SelectCascade(viewDepth, cascadeSplits);
    
    // 每级用不同颜色
    static const float3 cascadeColors[4] = 
    {
        float3(1, 0, 0),  // 红 - 最近
        float3(0, 1, 0),  // 绿
        float3(0, 0, 1),  // 蓝
        float3(1, 1, 0)   // 黄 - 最远
    };
    
    return cascadeColors[cascade];
}

#endif // SHADOW_PCF_HLSLI
