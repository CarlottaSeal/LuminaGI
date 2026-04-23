#include "VoxelSceneCommon.hlsli"

RWTexture3D<float4> VoxelLighting : register(u1);

StructuredBuffer<MeshSDFInfoGPU> InstanceInfos : register(t1, space0);
Texture2DArray<float4> SurfaceAtlas : register(t2, space0);
StructuredBuffer<SurfaceCardGPU> CardMetadata : register(t3, space0);
Buffer<uint> VoxelVisibilityBuffer : register(t4, space0);
Texture3D<float2> GlobalSDF : register(t0, space0);

SamplerState LinearSampler : register(s0);

static const uint SAMPLE_LAYER = 5;  // CombinedLight layer

float DecodeHitDistance(uint visibility, uint dirIndex, float maxTraceDist)
{
    uint quantized = (visibility >> (dirIndex * 5)) & 0x1F;
    return (float(quantized) / 31.0) * maxTraceDist;
}

[numthreads(8, 8, 8)]
void CSMain(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint3 voxelCoord = dispatchThreadID;

    if (any(voxelCoord >= VoxelResolution))
        return;

    float3 voxelWorldPos = SceneBoundsMin + (float3(voxelCoord) + 0.5) * VoxelSize;

    uint flatIndex = voxelCoord.x + voxelCoord.y * VoxelResolution + voxelCoord.z * VoxelResolution * VoxelResolution;
    uint containingMesh = VoxelVisibilityBuffer[flatIndex * 3 + 0];
    uint visibilityData = VoxelVisibilityBuffer[flatIndex * 3 + 1];

    if (containingMesh == 0xFFFFFFFF || containingMesh == 0xFFFFFFFE)
    {
        VoxelLighting[voxelCoord] = float4(0, 0, 0, 0);
        return;
    }

    float maxTraceDist = VoxelSize.x * 10.0;

    MeshSDFInfoGPU meshInfo = InstanceInfos[containingMesh];
    uint cardStartIndex = meshInfo.CardStartIndex;
    uint cardCount = meshInfo.CardCount;

    float3 totalLight = float3(0, 0, 0);
    float totalWeight = 0.0;

    for (uint dir = 0; dir < 6 && dir < cardCount; ++dir)
    {
        float hitDist = DecodeHitDistance(visibilityData, dir, maxTraceDist);

        if (hitDist < 0.001)
            continue;

        float3 hitWorldPos = voxelWorldPos + VoxelDirections[dir] * hitDist;

        uint cardIndex = cardStartIndex + dir;
        if (cardIndex >= CardCount)
            continue;

        SurfaceCardGPU card = CardMetadata[cardIndex];

        float3 localPos = WorldToCardLocal(hitWorldPos, card);
        float2 cardUV = CardLocalToCardUV(localPos, card);

        if (cardUV.x < 0.0 || cardUV.x > 1.0 || cardUV.y < 0.0 || cardUV.y > 1.0)
            continue;

        float2 atlasUV = CardUVToAtlasUV(cardUV, card, AtlasWidth, AtlasHeight);
        float3 lighting = SurfaceAtlas.SampleLevel(LinearSampler, float3(atlasUV, SAMPLE_LAYER), 0).rgb;

        totalLight += lighting;
        totalWeight += 1.0;
    }

    if (totalWeight > 0.0)
    {
        totalLight /= totalWeight;

        float4 prev = VoxelLighting[voxelCoord];
        float blend = (prev.a > 0.0) ? 0.02 : 1.0;
        float3 blended = lerp(prev.rgb, totalLight, blend);
        VoxelLighting[voxelCoord] = float4(blended, 1.0);
    }
    else
    {
        VoxelLighting[voxelCoord] = float4(0.0, 0.0, 0.0, 0.0);
    }
}
