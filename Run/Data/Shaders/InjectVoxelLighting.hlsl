#include "VoxelSceneCommon.hlsli"

// UAV
RWTexture3D<float4> VoxelLighting : register(u1);

// SRVs
StructuredBuffer<MeshSDFInfoGPU> InstanceInfos : register(t1, space0);
Texture2DArray<float4> SurfaceAtlas : register(t2, space0);
StructuredBuffer<SurfaceCardGPU> CardMetadata : register(t3, space0);
Buffer<uint> VoxelVisibilityBuffer : register(t4, space0);

// GlobalSDF SRV
Texture3D<float2> GlobalSDF : register(t0, space0);

SamplerState LinearSampler : register(s0);

// 采样层 - 使用DirectLight层(3)进行测试，正常应该用Combined层(5)
static const uint SAMPLE_LAYER = 3;  // DirectLight

// 直接使用 VoxelSceneCommon.hlsli 中定义的 VoxelDirections

// 从visibility数据中解码hit_distance (每方向5bits)
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

    // 无效voxel
    if (containingMesh == 0xFFFFFFFF || containingMesh == 0xFFFFFFFE)
    {
        VoxelLighting[voxelCoord] = float4(0, 0, 0, 0);
        return;
    }

    float maxTraceDist = VoxelSize.x * 10.0;

    // 获取mesh的Card起始索引
    MeshSDFInfoGPU meshInfo = InstanceInfos[containingMesh];
    uint cardStartIndex = meshInfo.CardStartIndex;
    uint cardCount = meshInfo.CardCount;

    float3 totalLight = float3(0, 0, 0);
    float totalWeight = 0.0;

    // 遍历6个方向
    for (uint dir = 0; dir < 6 && dir < cardCount; ++dir)
    {
        float hitDist = DecodeHitDistance(visibilityData, dir, maxTraceDist);

        if (hitDist < 0.001)
            continue;

        // 计算hit位置
        float3 hitWorldPos = voxelWorldPos + VoxelDirections[dir] * hitDist;

        // 获取对应方向的Card (SimLumen方式: card_start_index + direction)
        uint cardIndex = cardStartIndex + dir;
        if (cardIndex >= CardCount)
            continue;

        SurfaceCardGPU card = CardMetadata[cardIndex];

        // 计算Card UV (参照SimLumen的GetCardUVFromWorldPos)
        float3 localPos = WorldToCardLocal(hitWorldPos, card);
        float2 cardUV = CardLocalToCardUV(localPos, card);

        // UV有效性检查
        if (cardUV.x < 0.0 || cardUV.x > 1.0 || cardUV.y < 0.0 || cardUV.y > 1.0)
            continue;

        // 计算Atlas UV
        float2 atlasUV = CardUVToAtlasUV(cardUV, card, AtlasWidth, AtlasHeight);

        // 采样光照
        float3 lighting = SurfaceAtlas.SampleLevel(LinearSampler, float3(atlasUV, SAMPLE_LAYER), 0).rgb;

        totalLight += lighting;
        totalWeight += 1.0;
    }

    // Debug: 显示有多少方向被成功采样
    // 黄色越亮 = 越多方向有效
    // 黑色 = 所有方向都被跳过了
    if (totalWeight > 0.0)
    {
        totalLight /= totalWeight;
        VoxelLighting[voxelCoord] = float4(totalLight, 1.0);
    }
    else
    {
        // 没有任何方向被采样成功，输出青色便于识别
        VoxelLighting[voxelCoord] = float4(0.0, 1.0, 1.0, 1.0);
    }
}
