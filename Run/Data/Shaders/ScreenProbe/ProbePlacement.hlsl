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
    // Smooth transition via smoothstep; avoids hard-threshold popping
    // validity smoothly decreases from 1 to 0 as variance goes from 0 to DepthThreshold*2
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
    // Multi-sample depth; select most representative value to avoid edge popping
    // Sample 3x3 region; use median depth
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

    // Simple sort to find median (bubble sort on small array)
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

    // Use median depth
    float depth = (validDepthCount > 0) ? depths[validDepthCount / 2] : DepthBuffer[screenCoord];

    // Find pixel closest to median depth to obtain its normal
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

    // [DEBUG] Use center pixel normal directly
    float4 normalData = NormalBuffer[screenCoord];
    float3 normal = SafeNormalize(normalData.xyz * 2.0f - 1.0f);

    // Read world position directly from GBuffer (avoids inverse-projection precision loss)
    float3 worldPos = WorldPosBuffer[screenCoord].xyz;

    // World-space quantization: snap to fixed grid to reduce micro-jitter
    const float GRID_SIZE = 0.5f;  // Quantization grid size (world units)
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
