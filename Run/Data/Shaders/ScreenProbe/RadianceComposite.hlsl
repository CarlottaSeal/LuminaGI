#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

struct SurfaceCardMetadata
{
    uint AtlasX;
    uint AtlasY;
    uint ResolutionX;
    uint ResolutionY;

    float3 Origin;
    float Padding0;

    float3 AxisX;
    float Padding1;

    float3 AxisY;
    float Padding2;

    float3 Normal;
    float Padding3;

    float WorldSizeX;
    float WorldSizeY;
    uint Direction;
    uint GlobalCardID;

    uint4 LightMask;
};

StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV);
StructuredBuffer<ImportanceSampleGPU> SampleDirections : register(REG_SAMPLE_DIR_SRV);
StructuredBuffer<TraceResult> VoxelTraceResults : register(REG_VOXEL_TRACE_SRV);
StructuredBuffer<TraceResult> MeshTraceResults : register(REG_MESH_TRACE_SRV);
Texture3D<float4> VoxelLighting : register(REG_VOXEL_LIGHTING_SRV);
Texture2DArray<float4> SurfaceCacheAtlas : register(REG_SURFACE_ATLAS_SRV);
StructuredBuffer<SurfaceCardMetadata> CardMetadata : register(REG_CARD_METADATA_SRV);

RWTexture2D<float4> ProbeRadiance : register(REG_PROBE_RAD_UAV);

SamplerState LinearSampler : register(s1);

#define SURFACE_CACHE_COMBINED_LAYER 5

float3 ClampSourceRadiance(float3 color)
{
    const float MAX_SOURCE_LUM = 5.0f;
    float lum = max(max(color.r, color.g), color.b);
    if (lum > MAX_SOURCE_LUM)
        return color * (MAX_SOURCE_LUM / lum);

    if (any(isnan(color)) || any(isinf(color)))
        return float3(0, 0, 0);

    return color;
}

float3 SampleSurfaceCacheLighting(float3 worldPos, uint cardIndex)
{
    if (cardIndex == 0xFFFFFFFF)
        return float3(0, 0, 0);

    SurfaceCardMetadata card = CardMetadata[cardIndex];

    float3 toPos = worldPos - card.Origin;
    float u = dot(toPos, card.AxisX) / card.WorldSizeX + 0.5f;
    float v = dot(toPos, card.AxisY) / card.WorldSizeY + 0.5f;

    if (u < 0.0f || u > 1.0f || v < 0.0f || v > 1.0f)
        return float3(0, 0, 0);

    float2 atlasUV = float2(
        (float(card.AtlasX) + u * float(card.ResolutionX)) / float(AtlasWidth),
        (float(card.AtlasY) + v * float(card.ResolutionY)) / float(AtlasHeight)
    );

    float3 result = SurfaceCacheAtlas.SampleLevel(LinearSampler, float3(atlasUV, SURFACE_CACHE_COMBINED_LAYER), 0).rgb;
    return ClampSourceRadiance(result);
}

float3 SampleVoxelLighting(float3 worldPos)
{
    float3 voxelUV = (worldPos - VoxelGridMin) / (VoxelGridMax - VoxelGridMin);

    if (any(voxelUV < 0.0f) || any(voxelUV > 1.0f))
        return float3(0, 0, 0);

    float3 result = VoxelLighting.SampleLevel(LinearSampler, voxelUV, 0).rgb;
    return ClampSourceRadiance(result);
}

uint2 OctUVToTexelWithBorder(float2 octUV, uint2 probeCoord)
{
    uint2 localTexel = uint2(octUV * float(OctahedronSize));
    localTexel = clamp(localTexel, uint2(0, 0), uint2(OctahedronSize - 1, OctahedronSize - 1));
    localTexel += uint2(OctahedronBorder, OctahedronBorder);
    uint2 probeBase = probeCoord * BorderedOctSize;
    return probeBase + localTexel;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 rayTexCoord = dispatchThreadID.xy;

    if (rayTexCoord.x >= RaysTexWidth || rayTexCoord.y >= RaysTexHeight)
        return;

    uint2 probeCoord = uint2(rayTexCoord.x / OctahedronWidth, rayTexCoord.y / OctahedronHeight);
    uint2 localRayCoord = uint2(rayTexCoord.x % OctahedronWidth, rayTexCoord.y % OctahedronHeight);
    uint rayIndex = localRayCoord.y * 8 + localRayCoord.x;

    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
        return;

    uint probeIndex = probeCoord.y * ProbeGridWidth + probeCoord.x;
    uint globalRayIndex = probeIndex * RaysPerProbe + rayIndex;

    ScreenProbeGPU probe = ProbeBuffer[probeIndex];

    if (probe.Validity < 0.001f || rayIndex >= RaysPerProbe)
    {
        ProbeRadiance[rayTexCoord] = float4(0, 0, 0, 0);
        return;
    }

    ImportanceSampleGPU sampleData = SampleDirections[globalRayIndex];
    float3 rayDir = sampleData.Direction;

    if (length(rayDir) < 0.001f)
    {
        ProbeRadiance[rayTexCoord] = float4(0, 0, 0, 0);
        return;
    }

    TraceResult meshResult = MeshTraceResults[globalRayIndex];
    TraceResult voxelResult = VoxelTraceResults[globalRayIndex];

    float3 voxelRadiance = float3(0, 0, 0);

    if (meshResult.Validity > 0.0f && meshResult.HitDistance > 0.001f)
    {
        voxelRadiance = SampleVoxelLighting(meshResult.HitPosition);
    }
    else if (voxelResult.Validity > 0.0f && voxelResult.HitDistance > 0.001f)
    {
        voxelRadiance = SampleVoxelLighting(voxelResult.HitPosition);
    }

    float3 radiance = float3(0.02f, 0.02f, 0.02f);
    if (Luminance(voxelRadiance) > 0.001f)
    {
        radiance = voxelRadiance;
    }

    // Probe-based AO: derive occlusion from ray hit distance
    float closestHitDist = TraceMaxDistance;
    if (meshResult.Validity > 0.0f && meshResult.HitDistance > 0.001f)
        closestHitDist = min(closestHitDist, meshResult.HitDistance);
    if (voxelResult.Validity > 0.0f && voxelResult.HitDistance > 0.001f)
        closestHitDist = min(closestHitDist, voxelResult.HitDistance);

    // Closer hits = more occlusion (0 = fully occluded, 1 = open)
    const float AO_RADIUS = 3.0f;
    float aoValue = saturate(closestHitDist / AO_RADIUS);

    ProbeRadiance[rayTexCoord] = float4(radiance, aoValue);
}
