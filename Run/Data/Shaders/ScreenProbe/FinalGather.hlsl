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

RWTexture2D<float4> ScreenIndirectRaw : register(REG_INDIRECT_RAW_UAV); // u433 - 写入原始输出，时间滤波前

SamplerState LinearSampler : register(s1);
SamplerState PointSampler  : register(s0);

//=============================================================================
// 辅助函数
//=============================================================================

//=============================================================================
// ★ Octahedron 采样：根据方向从 Probe 的 8x8 octahedron 纹理采样
//=============================================================================

// 将方向转换为 probe 纹理坐标（支持双线性插值）
float2 DirectionToProbeTexCoord(float3 dir, uint2 probeCoord)
{
    // 获取 octahedron UV [0,1]
    float2 octUV = DirectionToOctahedronUV(dir);

    // 转换到 probe 的 8x8 纹理区域内的坐标
    // octUV * 8 给出 [0,8] 范围的坐标
    float2 localCoord = octUV * float(OctahedronSize);

    // 加上 probe 的基础偏移
    float2 probeBase = float2(probeCoord * OctahedronSize);

    return probeBase + localCoord;
}

// 从 Probe Radiance 纹理采样（使用 Octahedron 映射）
float3 SampleProbeRadiance(uint2 probeCoord, float3 normal)
{
    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
        return float3(0, 0, 0);

    // ★ 使用 Octahedron 映射：根据法线方向采样
    float2 texCoord = DirectionToProbeTexCoord(normal, probeCoord);

    // 双线性插值采样
    int2 texel00 = int2(floor(texCoord - 0.5f));
    int2 texel10 = texel00 + int2(1, 0);
    int2 texel01 = texel00 + int2(0, 1);
    int2 texel11 = texel00 + int2(1, 1);

    float2 frac_coord = frac(texCoord - 0.5f);

    // 计算 probe 的纹理边界
    int2 probeMin = int2(probeCoord * OctahedronSize);
    int2 probeMax = probeMin + int2(OctahedronSize - 1, OctahedronSize - 1);

    // Clamp 到 probe 边界内
    texel00 = clamp(texel00, probeMin, probeMax);
    texel10 = clamp(texel10, probeMin, probeMax);
    texel01 = clamp(texel01, probeMin, probeMax);
    texel11 = clamp(texel11, probeMin, probeMax);

    // 采样四个角
    float4 s00 = ProbeRadianceFiltered[texel00];
    float4 s10 = ProbeRadianceFiltered[texel10];
    float4 s01 = ProbeRadianceFiltered[texel01];
    float4 s11 = ProbeRadianceFiltered[texel11];

    // 双线性插值权重
    float w00 = (1.0f - frac_coord.x) * (1.0f - frac_coord.y);
    float w10 = frac_coord.x * (1.0f - frac_coord.y);
    float w01 = (1.0f - frac_coord.x) * frac_coord.y;
    float w11 = frac_coord.x * frac_coord.y;

    // 只考虑有效样本
    float3 totalRadiance = float3(0, 0, 0);
    float totalWeight = 0.0f;

    if (s00.w > 0.0f) { totalRadiance += s00.rgb * w00; totalWeight += w00; }
    if (s10.w > 0.0f) { totalRadiance += s10.rgb * w10; totalWeight += w10; }
    if (s01.w > 0.0f) { totalRadiance += s01.rgb * w01; totalWeight += w01; }
    if (s11.w > 0.0f) { totalRadiance += s11.rgb * w11; totalWeight += w11; }

    if (totalWeight > 0.001f)
        return totalRadiance / totalWeight;

    // Fallback: 如果 octahedron 采样失败，用中心区域平均值
    uint2 rayTexBase = probeCoord * OctahedronSize;
    totalRadiance = float3(0, 0, 0);
    totalWeight = 0.0f;

    [unroll]
    for (uint y = 2; y < 6; y++)
    {
        [unroll]
        for (uint x = 2; x < 6; x++)
        {
            float4 sample = ProbeRadianceFiltered[rayTexBase + uint2(x, y)];
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
        ScreenIndirectRaw[screenCoord] = float4(0, 0, 0, 0);
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
    
    ScreenIndirectRaw[screenCoord] = float4(indirectLight, 1.0f);
}
