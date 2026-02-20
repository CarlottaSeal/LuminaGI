//=============================================================================
// FinalGather.hlsl - 5-probe averaging, Diffuse GI only
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

Texture2D<float>  DepthBuffer   : register(REG_DEPTH_BUFFER);
Texture2D<float4> NormalBuffer  : register(REG_GBUFFER_NORMAL);
Texture2D<float4> AlbedoBuffer  : register(REG_GBUFFER_ALBEDO);
Texture2D<float4> ProbeIrradiance : register(REG_PROBE_RAD_SRV);
Texture2D<float4> MaterialBuffer : register(REG_GBUFFER_MATERIAL);
Texture3D<float4> VoxelLighting : register(REG_VOXEL_LIGHTING_SRV);

RWTexture2D<float4> ScreenIndirectRaw : register(REG_INDIRECT_RAW_UAV);

SamplerState LinearSampler : register(s1);

float3 GetScreenProbeIrradiance(uint2 probeCoord, float2 probeUV)
{
    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
        return float3(0, 0, 0);

    float2 probeSize = float2(OctahedronWidth, OctahedronHeight);
    float2 subPos = probeUV * (probeSize - 1.0f) + 1.0f;
    float2 texelUV = (float2(probeCoord) * probeSize + subPos) / float2(RaysTexWidth, RaysTexHeight);

    float3 result = ProbeIrradiance.SampleLevel(LinearSampler, texelUV, 0).rgb;

    float lum = max(max(result.r, result.g), result.b);
    const float MAX_LUM = 2.0f;
    if (lum > MAX_LUM)
        result *= MAX_LUM / lum;

    return result;
}

float3 SampleVoxelLightingSimple(float3 worldPos, float3 normal)
{
    float3 uvScale = 1.0f / (VoxelGridMax - VoxelGridMin);
    float3 voxelUV = (worldPos - VoxelGridMin) * uvScale;

    if (any(voxelUV < 0.0f) || any(voxelUV > 1.0f))
        return float3(0.05f, 0.05f, 0.05f);

    float3 irradiance = float3(0, 0, 0);
    float3 offsets[3] = { float3(0,0,0), normal * VoxelSize * 2.0f, normal * VoxelSize * 5.0f };

    for (int i = 0; i < 3; i++)
    {
        float3 sampleUV = (worldPos + offsets[i] - VoxelGridMin) * uvScale;
        if (all(sampleUV >= 0.0f) && all(sampleUV <= 1.0f))
        {
            irradiance += VoxelLighting.SampleLevel(LinearSampler, sampleUV, 0).rgb;
        }
    }

    return irradiance / 3.0f;
}

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 screenCoord = dispatchThreadID.xy;

    if (screenCoord.x >= ScreenWidth || screenCoord.y >= ScreenHeight)
        return;

    float depth = DepthBuffer[screenCoord];

    if (depth <= 0.0f || depth >= 0.9999f)
    {
        ScreenIndirectRaw[screenCoord] = float4(0, 0, 0, 0);
        return;
    }

    float3 normal = SafeNormalize(NormalBuffer[screenCoord].xyz * 2.0f - 1.0f);
    float3 albedo = AlbedoBuffer[screenCoord].rgb;
    float metallic = MaterialBuffer[screenCoord].g;

    float2 screenUV = (float2(screenCoord) + 0.5f) / float2(ScreenWidth, ScreenHeight);
    float3 worldPos = ScreenUVToWorld(screenUV, depth);

    float2 probeUV = DirectionToOctahedronUV(normal);
    uint2 probeCoord = screenCoord / ProbeSpacing;

    // 5-probe averaging
    int2 offsets[5] = { int2(0, 0), int2(0, 1), int2(0, -1), int2(1, 0), int2(-1, 0) };

    float3 totalRadiance = float3(0, 0, 0);
    float validCount = 0.0f;

    [unroll]
    for (uint i = 0; i < 5; i++)
    {
        int2 pc = int2(probeCoord) + offsets[i];

        if (pc.x >= 0 && pc.x < (int)ProbeGridWidth &&
            pc.y >= 0 && pc.y < (int)ProbeGridHeight)
        {
            totalRadiance += GetScreenProbeIrradiance(uint2(pc), probeUV);
            validCount += 1.0f;
        }
    }

    float3 diffuseIrradiance;
    if (validCount > 0.5f)
    {
        diffuseIrradiance = totalRadiance / validCount / PI;
    }
    else
    {
        diffuseIrradiance = SampleVoxelLightingSimple(worldPos, normal);
    }

    float3 c_diff = albedo * (1.0f - metallic);
    float3 indirectLight = c_diff * diffuseIrradiance * IndirectIntensity;

    float indirectLum = max(max(indirectLight.r, indirectLight.g), indirectLight.b);
    const float MAX_INDIRECT = 1.0f;
    if (indirectLum > MAX_INDIRECT)
        indirectLight *= MAX_INDIRECT / indirectLum;

    if (any(isnan(indirectLight)) || any(isinf(indirectLight)))
        indirectLight = float3(0, 0, 0);

    ScreenIndirectRaw[screenCoord] = float4(indirectLight, 1.0f);
}
