//=============================================================================
// ProbePlacement.hlsl
// Pass 6.1: Screen Probe Placement - place probes and compute world pos/normal
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

Texture2D<float>  DepthBuffer  : register(REG_DEPTH_BUFFER);   // t218
Texture2D<float4> NormalBuffer : register(REG_GBUFFER_NORMAL); // t201
Texture2D<float4> WorldPosBuffer : register(REG_GBUFFER_WORLDPOS); 

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
    // 使用 smoothstep 平滑过渡，避免硬阈值导致的跳变
    // variance 从 0 到 DepthThreshold*2 时，validity 从 1 平滑降到 0
    return 1.0f - smoothstep(0.0f, DepthThreshold * 2.0f, variance);
}

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 probeCoord = dispatchThreadID.xy;

    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
        return;

    uint2 screenCoord = probeCoord * ProbeSpacing + ProbeSpacing / 2;
    uint probeIndex = probeCoord.y * ProbeGridWidth + probeCoord.x;

    ScreenProbeGPU probe = (ScreenProbeGPU)0;

    if (screenCoord.x >= ScreenWidth || screenCoord.y >= ScreenHeight)
    {
        probe.ScreenX = screenCoord.x;
        probe.ScreenY = screenCoord.y;
        probe.Padding0 = 0;
        probe.Padding1 = 0;
        probe.WorldPosition = float3(0, 0, 0);
        probe.Depth = 0.0f;
        probe.WorldNormal = float3(0, 1, 0);
        probe.Validity = 0.0f;
        ProbeBuffer[probeIndex] = probe;
        return;
    }

    // =========================================================================
    // 多点采样深度，选择最常见的深度值（避免边缘跳变）
    // 在 3x3 区域采样，选择中位数深度
    // =========================================================================
    float depths[9];
    int validDepthCount = 0;

    [unroll]
    for (int dy = -1; dy <= 1; dy++)
    {
        [unroll]
        for (int dx = -1; dx <= 1; dx++)
        {
            int2 sampleCoord = int2(screenCoord) + int2(dx, dy);
            sampleCoord = clamp(sampleCoord, int2(0, 0), int2(ScreenWidth - 1, ScreenHeight - 1));
            float d = DepthBuffer[sampleCoord];
            if (d > 0.0f && d < 0.9999f)
            {
                depths[validDepthCount++] = d;
            }
        }
    }

    // 简单排序找中位数（对于小数组直接冒泡）
    [unroll]
    for (int i = 0; i < 8; i++)
    {
        [unroll]
        for (int j = i + 1; j < 9; j++)
        {
            if (j < validDepthCount && depths[j] < depths[i])
            {
                float tmp = depths[i];
                depths[i] = depths[j];
                depths[j] = tmp;
            }
        }
    }

    // 使用中位数深度
    float depth = (validDepthCount > 0) ? depths[validDepthCount / 2] : DepthBuffer[screenCoord];

    // 找到与中位数深度最接近的像素来获取法线
    float minDepthDiff = 1000.0f;
    int2 bestCoord = int2(screenCoord);

    [unroll]
    for (int dy2 = -1; dy2 <= 1; dy2++)
    {
        [unroll]
        for (int dx2 = -1; dx2 <= 1; dx2++)
        {
            int2 sampleCoord = int2(screenCoord) + int2(dx2, dy2);
            sampleCoord = clamp(sampleCoord, int2(0, 0), int2(ScreenWidth - 1, ScreenHeight - 1));
            float d = DepthBuffer[sampleCoord];
            float diff = abs(d - depth);
            if (diff < minDepthDiff)
            {
                minDepthDiff = diff;
                bestCoord = sampleCoord;
            }
        }
    }

    // [DEBUG] 直接用中心点法线，不做复杂选择
    float4 normalData = NormalBuffer[screenCoord];
    float3 normal = SafeNormalize(normalData.xyz * 2.0f - 1.0f);

    // 使用 ScreenUVToWorld 从深度重建世界位置
    float2 screenUV = (float2(screenCoord) + 0.5f) / float2(ScreenWidth, ScreenHeight);
    float3 worldPos = ScreenUVToWorld(screenUV, depth);

    // 世界空间量化：将位置对齐到固定网格，减少微小抖动
    const float GRID_SIZE = 0.5f;  // 量化网格大小（世界单位）
    worldPos = round(worldPos / GRID_SIZE) * GRID_SIZE;

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

    probe.ScreenX = screenCoord.x;
    probe.ScreenY = screenCoord.y;
    probe.Padding0 = 0;
    probe.Padding1 = 0;
    probe.WorldPosition = worldPos;
    probe.Depth = depth;
    probe.WorldNormal = normal;
    probe.Validity = saturate(validity);
    
    ProbeBuffer[probeIndex] = probe;
}
