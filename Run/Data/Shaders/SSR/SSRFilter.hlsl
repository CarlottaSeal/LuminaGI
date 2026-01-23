//=============================================================================
// SSRFilter.hlsl
// SSR 空间滤波和时间累积
//=============================================================================

#include "SSRCommon.hlsli"

//-----------------------------------------------------------------------------
// 常量缓冲区
//-----------------------------------------------------------------------------

cbuffer SSRConstantBuffer : register(b0)
{
    SSRConstants g_SSR;
};

//-----------------------------------------------------------------------------
// 资源
//-----------------------------------------------------------------------------

// GBuffer（用于边缘保持滤波）
Texture2D<float> g_Depth : register(t0);
Texture2D<float4> g_Normal : register(t1);
Texture2D<float4> g_WorldPos : register(t2);
Texture2D<float4> g_Albedo : register(t3);

// SSR结果
Texture2D<float4> g_SSRInput : register(t4);      // 追踪结果
Texture2D<float4> g_SSRFiltered : register(t5);   // 滤波后结果（用于temporal）
Texture2D<float4> g_History : register(t6);       // 历史帧

// Motion Vector（如果有的话）
Texture2D<float2> g_MotionVector : register(t7);

// 采样器
SamplerState g_PointSampler : register(s0);
SamplerState g_LinearSampler : register(s1);

// 输出
RWTexture2D<float4> g_OutputFiltered : register(u0);   // 空间滤波输出
RWTexture2D<float4> g_OutputTemporal : register(u1);   // 时间累积输出
RWTexture2D<float4> g_OutputHistory : register(u2);    // 新历史

//-----------------------------------------------------------------------------
// 空间滤波（边缘保持双边滤波）
//-----------------------------------------------------------------------------

float CalculateBilateralWeight(
    float3 centerNormal, float centerDepth,
    float3 sampleNormal, float sampleDepth,
    float spatialWeight)
{
    // 法线权重
    float normalWeight = pow(max(0.0f, dot(centerNormal, sampleNormal)), 32.0f);
    
    // 深度权重
    float depthDiff = abs(centerDepth - sampleDepth);
    float depthWeight = exp(-depthDiff * 100.0f);
    
    return spatialWeight * normalWeight * depthWeight;
}

[numthreads(8, 8, 1)]
void CSSpatialFilter(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pixelCoord = dispatchThreadID.xy;
    
    if (pixelCoord.x >= g_SSR.ScreenWidth || pixelCoord.y >= g_SSR.ScreenHeight)
        return;
    
    float2 uv = (float2(pixelCoord) + 0.5f) / float2(g_SSR.ScreenWidth, g_SSR.ScreenHeight);
    
    // 读取中心像素
    float4 centerSSR = g_SSRInput[pixelCoord];
    float centerDepth = g_Depth[pixelCoord];
    float3 centerNormal = normalize(g_Normal[pixelCoord].xyz * 2.0f - 1.0f);
    
    // 天空直接输出
    if (centerDepth >= 1.0f || centerSSR.a < 0.001f)
    {
        g_OutputFiltered[pixelCoord] = centerSSR;
        return;
    }
    
    // 双边滤波
    float4 accumSSR = float4(0, 0, 0, 0);
    float totalWeight = 0.0f;
    
    int radius = SPATIAL_FILTER_RADIUS;
    
    // 高斯核权重（预计算）
    float sigma = (float)radius / 2.0f;
    float sigmaSquared = sigma * sigma * 2.0f;
    
    [unroll]
    for (int y = -radius; y <= radius; ++y)
    {
        [unroll]
        for (int x = -radius; x <= radius; ++x)
        {
            int2 sampleCoord = (int2)pixelCoord + int2(x, y);
            
            // 边界检查
            if (sampleCoord.x < 0 || sampleCoord.x >= (int)g_SSR.ScreenWidth ||
                sampleCoord.y < 0 || sampleCoord.y >= (int)g_SSR.ScreenHeight)
                continue;
            
            // 读取采样点
            float4 sampleSSR = g_SSRInput[sampleCoord];
            float sampleDepth = g_Depth[sampleCoord];
            float3 sampleNormal = normalize(g_Normal[sampleCoord].xyz * 2.0f - 1.0f);
            
            // 计算空间权重（高斯）
            float distSquared = (float)(x * x + y * y);
            float spatialWeight = exp(-distSquared / sigmaSquared);
            
            // 计算双边权重
            float weight = CalculateBilateralWeight(
                centerNormal, centerDepth,
                sampleNormal, sampleDepth,
                spatialWeight
            );
            
            // 置信度加权
            weight *= sampleSSR.a;
            
            accumSSR += sampleSSR * weight;
            totalWeight += weight;
        }
    }
    
    // 归一化
    if (totalWeight > 0.001f)
    {
        accumSSR /= totalWeight;
    }
    else
    {
        accumSSR = centerSSR;
    }
    
    g_OutputFiltered[pixelCoord] = accumSSR;
}

//-----------------------------------------------------------------------------
// 时间累积（带History Clamping）
//-----------------------------------------------------------------------------

// 计算邻域的AABB用于clamping
void CalculateNeighborhoodAABB(uint2 pixelCoord, out float3 minColor, out float3 maxColor)
{
    minColor = float3(1e10, 1e10, 1e10);
    maxColor = float3(-1e10, -1e10, -1e10);
    
    [unroll]
    for (int y = -1; y <= 1; ++y)
    {
        [unroll]
        for (int x = -1; x <= 1; ++x)
        {
            int2 sampleCoord = (int2)pixelCoord + int2(x, y);
            sampleCoord = clamp(sampleCoord, int2(0, 0), int2(g_SSR.ScreenWidth - 1, g_SSR.ScreenHeight - 1));
            
            float3 sampleColor = g_SSRFiltered[sampleCoord].rgb;
            
            minColor = min(minColor, sampleColor);
            maxColor = max(maxColor, sampleColor);
        }
    }
}

// Variance Clipping（更好的ghosting处理）
float3 ClipToAABB(float3 color, float3 minColor, float3 maxColor)
{
    float3 center = (minColor + maxColor) * 0.5f;
    float3 extents = (maxColor - minColor) * 0.5f + 0.001f;
    
    float3 offset = color - center;
    float3 ts = abs(offset / extents);
    float t = max(max(ts.x, ts.y), ts.z);
    
    if (t > 1.0f)
    {
        color = center + offset / t;
    }
    
    return color;
}

[numthreads(8, 8, 1)]
void CSTemporalAccum(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pixelCoord = dispatchThreadID.xy;
    
    if (pixelCoord.x >= g_SSR.ScreenWidth || pixelCoord.y >= g_SSR.ScreenHeight)
        return;
    
    float2 uv = (float2(pixelCoord) + 0.5f) / float2(g_SSR.ScreenWidth, g_SSR.ScreenHeight);
    
    // 读取当前帧
    float4 currentSSR = g_SSRFiltered[pixelCoord];
    float currentDepth = g_Depth[pixelCoord];
    
    // 天空直接输出
    if (currentDepth >= 1.0f)
    {
        g_OutputTemporal[pixelCoord] = float4(0, 0, 0, 0);
        g_OutputHistory[pixelCoord] = float4(0, 0, 0, 0);
        return;
    }
    
    // 计算重投影UV
    float3 worldPos = g_WorldPos[pixelCoord].xyz;
    float4 prevClipPos = mul(float4(worldPos, 1.0f), g_SSR.PrevViewProjMatrix);
    prevClipPos.xyz /= prevClipPos.w;
    
    float2 historyUV = prevClipPos.xy * 0.5f + 0.5f;
    historyUV.y = 1.0f - historyUV.y;
    
    // 检查重投影是否有效
    bool validHistory = IsValidUV(historyUV);
    
    // 读取历史
    float4 historySSR = float4(0, 0, 0, 0);
    if (validHistory)
    {
        historySSR = g_History.SampleLevel(g_LinearSampler, historyUV, 0);
    }
    
    // History Clamping
    float3 minColor, maxColor;
    CalculateNeighborhoodAABB(pixelCoord, minColor, maxColor);
    
    float3 clampedHistory = ClipToAABB(historySSR.rgb, minColor, maxColor);
    
    // 计算混合权重
    float blendWeight = g_SSR.TemporalBlend;
    
    // 无效历史时增加当前帧权重
    if (!validHistory)
    {
        blendWeight = 1.0f;
    }
    
    // Disocclusion检测
    // 如果历史被大幅clamp，说明可能是disocclusion，增加当前帧权重
    float clampAmount = length(historySSR.rgb - clampedHistory);
    if (clampAmount > 0.1f)
    {
        blendWeight = lerp(blendWeight, 0.5f, saturate(clampAmount * 2.0f));
    }
    
    // 混合
    float3 resultColor = lerp(clampedHistory, currentSSR.rgb, blendWeight);
    float resultConfidence = lerp(historySSR.a, currentSSR.a, blendWeight);
    
    float4 result = float4(resultColor, resultConfidence);
    
    g_OutputTemporal[pixelCoord] = result;
    g_OutputHistory[pixelCoord] = result;
}

//-----------------------------------------------------------------------------
// 简化版时间累积（无motion vector，用于快速集成）
//-----------------------------------------------------------------------------

[numthreads(8, 8, 1)]
void CSTemporalAccumSimple(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pixelCoord = dispatchThreadID.xy;
    
    if (pixelCoord.x >= g_SSR.ScreenWidth || pixelCoord.y >= g_SSR.ScreenHeight)
        return;
    
    float2 uv = (float2(pixelCoord) + 0.5f) / float2(g_SSR.ScreenWidth, g_SSR.ScreenHeight);
    
    // 读取当前帧和历史
    float4 currentSSR = g_SSRFiltered[pixelCoord];
    float4 historySSR = g_History[pixelCoord];
    
    float currentDepth = g_Depth[pixelCoord];
    
    // 天空
    if (currentDepth >= 1.0f)
    {
        g_OutputTemporal[pixelCoord] = float4(0, 0, 0, 0);
        g_OutputHistory[pixelCoord] = float4(0, 0, 0, 0);
        return;
    }
    
    // 简单邻域clamping
    float3 minColor, maxColor;
    CalculateNeighborhoodAABB(pixelCoord, minColor, maxColor);
    float3 clampedHistory = clamp(historySSR.rgb, minColor, maxColor);
    
    // 混合
    float blendWeight = g_SSR.TemporalBlend;
    float3 resultColor = lerp(clampedHistory, currentSSR.rgb, blendWeight);
    float resultConfidence = lerp(historySSR.a, currentSSR.a, blendWeight);
    
    float4 result = float4(resultColor, resultConfidence);
    
    g_OutputTemporal[pixelCoord] = result;
    g_OutputHistory[pixelCoord] = result;
}

//-----------------------------------------------------------------------------
// 可选：联合双边上采样（用于半分辨率SSR）
//-----------------------------------------------------------------------------

Texture2D<float4> g_LowResSSR : register(t8);
Texture2D<float> g_LowResDepth : register(t9);

[numthreads(8, 8, 1)]
void CSBilateralUpsample(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pixelCoord = dispatchThreadID.xy;
    
    if (pixelCoord.x >= g_SSR.ScreenWidth || pixelCoord.y >= g_SSR.ScreenHeight)
        return;
    
    // 全分辨率深度和法线
    float fullResDepth = g_Depth[pixelCoord];
    float3 fullResNormal = normalize(g_Normal[pixelCoord].xyz * 2.0f - 1.0f);
    
    // 低分辨率采样坐标
    float2 lowResUV = (float2(pixelCoord) + 0.5f) / float2(g_SSR.ScreenWidth, g_SSR.ScreenHeight);
    uint2 lowResCoord = pixelCoord / 2;
    
    // 双线性采样4个低分辨率像素
    float4 accumSSR = float4(0, 0, 0, 0);
    float totalWeight = 0.0f;
    
    [unroll]
    for (int y = 0; y <= 1; ++y)
    {
        [unroll]
        for (int x = 0; x <= 1; ++x)
        {
            int2 sampleCoord = (int2)lowResCoord + int2(x, y);
            
            float4 sampleSSR = g_LowResSSR[sampleCoord];
            float sampleDepth = g_LowResDepth[sampleCoord];
            
            // 深度权重
            float depthDiff = abs(fullResDepth - sampleDepth);
            float weight = exp(-depthDiff * 50.0f);
            
            accumSSR += sampleSSR * weight;
            totalWeight += weight;
        }
    }
    
    if (totalWeight > 0.001f)
    {
        accumSSR /= totalWeight;
    }
    
    g_OutputFiltered[pixelCoord] = accumSSR;
}
