//=============================================================================
// FinalGather.hlsl
// Pass 6.10: Final Gather
// 最终整合：从 Probe 插值到每个屏幕像素
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

Texture2D<float>  DepthBuffer   : register(REG_DEPTH_BUFFER);        // t218
Texture2D<float4> NormalBuffer  : register(REG_GBUFFER_NORMAL);      // t201
Texture2D<float4> AlbedoBuffer  : register(REG_GBUFFER_ALBEDO);      // t203
Texture2D<float4> ProbeRadianceFiltered : register(REG_PROBE_RAD_FILT_SRV); // t420
StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV); // t401

RWTexture2D<float4> ScreenIndirectLighting : register(REG_INDIRECT_LIGHT_UAV); // u427

SamplerState LinearSampler : register(s1);
SamplerState PointSampler  : register(s0);

//=============================================================================
// 辅助函数
//=============================================================================

// 从 Probe Radiance 纹理采样（双线性插值 Probe 之间）
float3 SampleProbeRadiance(uint2 probeCoord, float3 normal)
{
    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
        return float3(0, 0, 0);
    
    // 简化：采样 Probe 中心的平均辐射度
    // 完整实现应该根据方向采样 Octahedron
    uint2 rayTexBase = probeCoord * 8;
    
    float3 totalRadiance = float3(0, 0, 0);
    float totalWeight = 0.0f;
    
    // 平均 8x8 区域（简化版）
    [unroll]
    for (uint y = 0; y < 8; y += 2)
    {
        [unroll]
        for (uint x = 0; x < 8; x += 2)
        {
            uint2 sampleCoord = rayTexBase + uint2(x, y);
            float4 sample = ProbeRadianceFiltered[sampleCoord];
            
            if (sample.w > 0.0f)
            {
                totalRadiance += sample.rgb;
                totalWeight += 1.0f;
            }
        }
    }
    
    if (totalWeight > 0.0f)
        return totalRadiance / totalWeight;
    
    return float3(0, 0, 0);
}

//=============================================================================
// 主计算着色器
//=============================================================================

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 screenCoord = dispatchThreadID.xy;
    
    if (screenCoord.x >= ScreenWidth || screenCoord.y >= ScreenHeight)
        return;
    
    float depth = DepthBuffer[screenCoord];
    
    // 天空像素
    if (depth <= 0.0f || depth >= 0.9999f)
    {
        ScreenIndirectLighting[screenCoord] = float4(0, 0, 0, 0);
        return;
    }
    
    float3 normal = NormalBuffer[screenCoord].xyz * 2.0f - 1.0f;
    normal = SafeNormalize(normal);
    
    float3 albedo = AlbedoBuffer[screenCoord].rgb;
    
    // 计算像素在 Probe Grid 中的位置
    float2 probeUV = float2(screenCoord) / float(ProbeSpacing);
    
    // 双线性插值的 4 个 Probe
    int2 probeCoord00 = int2(floor(probeUV - 0.5f));
    int2 probeCoord10 = probeCoord00 + int2(1, 0);
    int2 probeCoord01 = probeCoord00 + int2(0, 1);
    int2 probeCoord11 = probeCoord00 + int2(1, 1);
    
    float2 bilinearWeights = frac(probeUV - 0.5f);
    float w00 = (1.0f - bilinearWeights.x) * (1.0f - bilinearWeights.y);
    float w10 = bilinearWeights.x * (1.0f - bilinearWeights.y);
    float w01 = (1.0f - bilinearWeights.x) * bilinearWeights.y;
    float w11 = bilinearWeights.x * bilinearWeights.y;
    
    float3 totalRadiance = float3(0, 0, 0);
    float totalWeight = 0.0f;
    
    int2 probeCoords[4] = { probeCoord00, probeCoord10, probeCoord01, probeCoord11 };
    float bilinearW[4] = { w00, w10, w01, w11 };
    
    [unroll]
    for (int i = 0; i < 4; i++)
    {
        int2 pc = probeCoords[i];
        
        if (pc.x < 0 || pc.x >= (int)ProbeGridWidth ||
            pc.y < 0 || pc.y >= (int)ProbeGridHeight)
            continue;
        
        uint probeIndex = pc.y * ProbeGridWidth + pc.x;
        ScreenProbeGPU probe = ProbeBuffer[probeIndex];
        
        if (probe.Validity <= 0.0f)
            continue;
        
        // 深度权重
        float depthDiff = abs(depth - probe.Depth);
        float depthWeight = exp(-depthDiff * DepthWeightScale);
        
        // 法线权重
        float normalDot = saturate(dot(normal, probe.WorldNormal));
        float normalWeight = pow(normalDot, NormalWeightScale);
        
        float weight = bilinearW[i] * depthWeight * normalWeight;
        
        if (weight > 0.001f)
        {
            float3 radiance = SampleProbeRadiance(uint2(pc), normal);
            totalRadiance += radiance * weight;
            totalWeight += weight;
        }
    }
    
    float3 finalRadiance = float3(0, 0, 0);
    if (totalWeight > 0.0f)
    {
        finalRadiance = totalRadiance / totalWeight;
    }
    
    // 应用 Albedo 和强度
    float3 indirectLight = finalRadiance * albedo * IndirectIntensity;
    
    // 简单的 AO
    float ao = 1.0f - AOStrength * (1.0f - saturate(Luminance(finalRadiance)));
    indirectLight *= ao;
    
    ScreenIndirectLighting[screenCoord] = float4(indirectLight, 1.0f);
}
