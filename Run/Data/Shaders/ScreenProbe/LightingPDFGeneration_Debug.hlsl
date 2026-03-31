//=============================================================================
// LightingPDFGeneration_Debug.hlsl
// Pass 6.3: Lighting PDF Generation
// 从 VoxelLighting 采样环境光分布，投影到 SH2
// 这比屏幕重投影更稳定，不会产生时间反馈抖动
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeSH.hlsli"
#include "ScreenProbeRegisters.hlsli"

StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV);
Texture3D<float4> VoxelLighting : register(REG_VOXEL_LIGHTING_SRV);

RWStructuredBuffer<SH2CoeffsGPU> LightingPDFOutput : register(REG_LIGHTING_PDF_UAV);

SamplerState LinearSampler : register(s1);

// 从 VoxelLighting 采样某方向的光照
float3 SampleVoxelLightingDirection(float3 worldPos, float3 direction, float distance)
{
    float3 samplePos = worldPos + direction * distance;

    // 转换到 voxel UV 空间
    float3 voxelUV = (samplePos - VoxelGridMin) / (VoxelGridMax - VoxelGridMin);

    // 边界检查
    if (any(voxelUV < 0.0f) || any(voxelUV > 1.0f))
        return float3(0.0f, 0.0f, 0.0f);

    return VoxelLighting.SampleLevel(LinearSampler, voxelUV, 0).rgb;
}

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 probeCoord = dispatchThreadID.xy;

    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
        return;

    uint probeIndex = probeCoord.y * ProbeGridWidth + probeCoord.x;
    ScreenProbeGPU probe = ProbeBuffer[probeIndex];

    // 无效探针：使用均匀分布
    if (probe.Validity <= 0.0f)
    {
        SH2CoeffsGPU result;
        result.R = float4(SH_L0, 0, 0, 0);
        result.G = float4(SH_L0, 0, 0, 0);
        result.B = float4(SH_L0, 0, 0, 0);
        LightingPDFOutput[probeIndex] = result;
        return;
    }

    float3 probeWorldPos = probe.WorldPosition;
    float3 probeNormal = SafeNormalize(probe.WorldNormal);

    // 从多个方向采样 VoxelLighting
    SH2RGB sh = InitSH();
    float totalWeight = 0.0f;

    // 使用 Fibonacci 球面分布采样 (全球面，不只是半球)
    const uint numSamples = 64;
    const float sampleDistance = VoxelSize * 4.0f; // 采样距离

    [loop]
    for (uint i = 0; i < numSamples; i++)
    {
        // Fibonacci 球面采样
        float phi = TWO_PI * frac(float(i) * 0.6180339887f);
        float cosTheta = 1.0f - (2.0f * float(i) + 1.0f) / (2.0f * float(numSamples));
        float sinTheta = sqrt(max(0.0f, 1.0f - cosTheta * cosTheta));

        float3 sampleDir = float3(
            sinTheta * cos(phi),
            sinTheta * sin(phi),
            cosTheta
        );

        // 采样 VoxelLighting
        float3 lighting = SampleVoxelLightingDirection(probeWorldPos, sampleDir, sampleDistance);
        float luminance = Luminance(lighting);

        if (luminance > 0.001f)
        {
            // 权重 = 光照亮度 (不乘 cosine，因为我们要的是入射光分布)
            float weight = luminance;

            ProjectToSHRGB(sampleDir, float3(weight, weight, weight), sh);
            totalWeight += weight;
        }
    }

    // 归一化
    if (totalWeight > 0.0f)
    {
        NormalizeSHRGB(sh, 1.0f / totalWeight);
    }
    else
    {
        // 没有光照数据：使用均匀分布
        sh = InitSH();
        sh.R.x = SH_L0;
        sh.G.x = SH_L0;
        sh.B.x = SH_L0;
    }

    SH2CoeffsGPU result;
    result.R = sh.R;
    result.G = sh.G;
    result.B = sh.B;
    LightingPDFOutput[probeIndex] = result;
}
