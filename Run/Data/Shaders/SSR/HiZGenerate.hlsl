//=============================================================================
// HiZGenerate.hlsl
// Hierarchical Z-Buffer 生成
// 用于加速SSR的屏幕空间追踪
//=============================================================================

#include "SSRCommon.hlsli"

//-----------------------------------------------------------------------------
// 常量
//-----------------------------------------------------------------------------

cbuffer HiZConstants : register(b0)
{
    uint SrcWidth;
    uint SrcHeight;
    uint DstWidth;
    uint DstHeight;
    uint MipLevel;
    float3 Padding;
};

//-----------------------------------------------------------------------------
// 资源
//-----------------------------------------------------------------------------

// 第一级从深度缓冲读取，之后从上一级Hi-Z读取
Texture2D<float> g_Source : register(t0);
SamplerState g_PointSampler : register(s0);

RWTexture2D<float> g_Dest : register(u0);

//-----------------------------------------------------------------------------
// Hi-Z生成
// 每个Mip存储2x2区域的最大深度（用于保守追踪）
//-----------------------------------------------------------------------------

[numthreads(8, 8, 1)]
void CSMain(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 dstCoord = dispatchThreadID.xy;
    
    if (dstCoord.x >= DstWidth || dstCoord.y >= DstHeight)
        return;
    
    // 计算源坐标（4个采样点）
    uint2 srcCoord = dstCoord * 2;
    
    float4 depths;
    
    if (MipLevel == 0)
    {
        // 第一级：从原始深度缓冲读取
        depths.x = g_Source[srcCoord + uint2(0, 0)];
        depths.y = g_Source[srcCoord + uint2(1, 0)];
        depths.z = g_Source[srcCoord + uint2(0, 1)];
        depths.w = g_Source[srcCoord + uint2(1, 1)];
    }
    else
    {
        // 后续级别：从上一级Hi-Z读取
        // 使用点采样确保精确读取
        float2 srcUV = (float2(srcCoord) + 0.5f) / float2(SrcWidth, SrcHeight);
        float2 texelSize = 1.0f / float2(SrcWidth, SrcHeight);
        
        depths.x = g_Source.SampleLevel(g_PointSampler, srcUV, 0);
        depths.y = g_Source.SampleLevel(g_PointSampler, srcUV + float2(texelSize.x, 0), 0);
        depths.z = g_Source.SampleLevel(g_PointSampler, srcUV + float2(0, texelSize.y), 0);
        depths.w = g_Source.SampleLevel(g_PointSampler, srcUV + texelSize, 0);
    }
    
    // 取最大值（保守追踪：确保不会错过任何遮挡物）
    float maxDepth = max(max(depths.x, depths.y), max(depths.z, depths.w));
    
    g_Dest[dstCoord] = maxDepth;
}

//-----------------------------------------------------------------------------
// 可选：生成Min-Max Hi-Z（用于更精确的追踪）
//-----------------------------------------------------------------------------

// RWTexture2D<float2> g_DestMinMax : register(u0);  // R=Min, G=Max

// [numthreads(8, 8, 1)]
// void CSMainMinMax(uint3 dispatchThreadID : SV_DispatchThreadID)
// {
//     uint2 dstCoord = dispatchThreadID.xy;
//     
//     if (dstCoord.x >= DstWidth || dstCoord.y >= DstHeight)
//         return;
//     
//     uint2 srcCoord = dstCoord * 2;
//     
//     float4 depths;
//     depths.x = g_Source[srcCoord + uint2(0, 0)];
//     depths.y = g_Source[srcCoord + uint2(1, 0)];
//     depths.z = g_Source[srcCoord + uint2(0, 1)];
//     depths.w = g_Source[srcCoord + uint2(1, 1)];
//     
//     float minDepth = min(min(depths.x, depths.y), min(depths.z, depths.w));
//     float maxDepth = max(max(depths.x, depths.y), max(depths.z, depths.w));
//     
//     g_DestMinMax[dstCoord] = float2(minDepth, maxDepth);
// }
