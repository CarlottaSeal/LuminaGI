//=============================================================================
// ProbePlacement.hlsl
// Pass 6.1: Screen Probe Placement
// 在屏幕空间放置 Probe，计算世界坐标和法线
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

Texture2D<float>  DepthBuffer  : register(REG_DEPTH_BUFFER);   // t218
Texture2D<float4> NormalBuffer : register(REG_GBUFFER_NORMAL); // t201

RWStructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_UAV); // u400

SamplerState PointSampler : register(s0);

float ComputeDepthConsistency(uint2 centerCoord, float centerDepth)
{
    if (centerDepth <= 0.0f || centerDepth >= 0.9999f)
        return 0.0f;
    
    float depthSum = 0.0f;
    int validCount = 0;
    const int radius = 2;
    
    [unroll]
    for (int dy = -radius; dy <= radius; dy++)
    {
        [unroll]
        for (int dx = -radius; dx <= radius; dx++)
        {
            int2 sampleCoord = int2(centerCoord) + int2(dx, dy);
            
            if (sampleCoord.x >= 0 && sampleCoord.x < (int)ScreenWidth &&
                sampleCoord.y >= 0 && sampleCoord.y < (int)ScreenHeight)
            {
                float sampleDepth = DepthBuffer[sampleCoord];
                if (sampleDepth > 0.0f && sampleDepth < 0.9999f)
                {
                    depthSum += sampleDepth;
                    validCount++;
                }
            }
        }
    }
    
    if (validCount < 5)
        return 0.0f;
    
    float avgDepth = depthSum / float(validCount);
    float variance = 0.0f;
    
    [unroll]
    for (int dy2 = -radius; dy2 <= radius; dy2++)
    {
        [unroll]
        for (int dx2 = -radius; dx2 <= radius; dx2++)
        {
            int2 sampleCoord = int2(centerCoord) + int2(dx2, dy2);
            
            if (sampleCoord.x >= 0 && sampleCoord.x < (int)ScreenWidth &&
                sampleCoord.y >= 0 && sampleCoord.y < (int)ScreenHeight)
            {
                float sampleDepth = DepthBuffer[sampleCoord];
                if (sampleDepth > 0.0f && sampleDepth < 0.9999f)
                {
                    float diff = sampleDepth - avgDepth;
                    variance += diff * diff;
                }
            }
        }
    }
    
    variance = sqrt(variance / float(validCount));
    return (variance > DepthThreshold) ? saturate(1.0f - variance / (DepthThreshold * 2.0f)) : 1.0f;
}

//=============================================================================
// 主计算着色器
//=============================================================================

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 probeCoord = dispatchThreadID.xy;
    
    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
        return;
    
    // Probe 中心的屏幕坐标
    uint2 screenCoord = probeCoord * ProbeSpacing + ProbeSpacing / 2;
    
    uint probeIndex = probeCoord.y * ProbeGridWidth + probeCoord.x;
    

    // 边界检查
    if (screenCoord.x >= ScreenWidth || screenCoord.y >= ScreenHeight)
    {
        ScreenProbeGPU probe;
        probe.ScreenX = screenCoord.x;
        probe.ScreenY = screenCoord.y;
        probe.WorldPosition = float3(0, 0, 0);
        probe.WorldNormal = float3(0, 1, 0);
        probe.Depth = 0.0f;
        probe.Validity = 0.0f;
        return;
    }
    
    // 读取深度和法线
    float depth = DepthBuffer[screenCoord];
    float4 normalData = NormalBuffer[screenCoord];
    float3 normal = SafeNormalize(normalData.xyz * 2.0f - 1.0f);
    
    // 计算屏幕 UV
    float2 screenUV = (float2(screenCoord) + 0.5f) / float2(ScreenWidth, ScreenHeight);
    
    // 重建世界坐标
    float3 worldPos = ScreenUVToWorld(screenUV, depth);
    
    // 计算有效性
    float validity = 1.0f;
    
    if (depth <= 0.0f || depth >= 0.9999f)
    {
        validity = 0.0f;
    }
    else
    {
        float depthConsistency = ComputeDepthConsistency(screenCoord, depth);
        validity *= depthConsistency;
    }
    
    // 输出 Probe 数据
    ScreenProbeGPU probe;
    probe.ScreenX = screenCoord.x;
    probe.ScreenY = screenCoord.y;
    probe.WorldPosition = worldPos;
    probe.WorldNormal = normal;
    probe.Depth = depth;
    probe.Validity = saturate(validity);
    ProbeBuffer[probeIndex] = probe;
    if (probeCoord.x == 120 && probeCoord.y == 38)
    {
        probe.WorldPosition.x = depth;      
        probe.WorldPosition.y = screenUV.x;
        probe.WorldPosition.z = screenUV.y;
    }
    ProbeBuffer[probeIndex] = probe;
}
