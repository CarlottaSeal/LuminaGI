#include "VoxelSceneCommon.hlsli"

// UAV (Root Parameter 1 - UAV Table)
RWTexture3D<float4> VoxelLighting : register(u1);

// SRVs (Root Parameter 2 - SRV Table)
Texture2DArray<float4> SurfaceAtlas : register(t2, space0);
StructuredBuffer<SurfaceCardGPU> CardMetadata : register(t3, space0); 
Buffer<uint> VoxelVisibilityBuffer : register(t4, space0);

// GlobalSDF SRV (Root Parameter 3)
Texture3D<float2> GlobalSDF : register(t0, space0);

SamplerState LinearSampler : register(s0);

static const uint DIRECT_LIGHT_LAYER = 3;

// 采样 Surface Cache 的 DirectLight
float3 SampleCardLighting(SurfaceCardGPU card, float3 worldPos)
{
    // 1. 世界坐标 → Card 局部坐标
    float3 localPos = WorldToCardLocal(worldPos, card);
    
    // 2. Card 局部坐标 → Card UV [0, 1]
    float2 cardUV = CardLocalToCardUV(localPos, card);
    
    // 3. 检查 UV 是否有效
    if (!IsCardUVValid(cardUV))
        return float3(0, 0, 0);
    
    // 4. Card UV → Atlas UV
    float2 atlasUV = CardUVToAtlasUV(cardUV, card, AtlasWidth, AtlasHeight);
    
    // 5. 采样 DirectLight 层 (layer 3)
    float4 lighting = SurfaceAtlas.SampleLevel(LinearSampler, float3(atlasUV, DIRECT_LIGHT_LAYER), 0);
    
    return lighting.rgb;
}

[numthreads(8, 8, 8)]
void CSMain(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint3 voxelCoord = dispatchThreadID;
    
    if (any(voxelCoord >= VoxelResolution))
        return;
    
    float3 voxelCenter = SceneBoundsMin + (float3(voxelCoord) + 0.5) * VoxelSize;
    
    uint flatIndex = voxelCoord.x + voxelCoord.y * VoxelResolution + voxelCoord.z * VoxelResolution * VoxelResolution;
    uint containingMesh = VoxelVisibilityBuffer[flatIndex * 3 + 0];
    
    
    if (voxelCoord.x == 56 && voxelCoord.y == 38 && voxelCoord.z == 8)
    {
        uint cardBaseIndex = containingMesh * 6;
        SurfaceCardGPU card = CardMetadata[cardBaseIndex];
    
        float3 localPos = WorldToCardLocal(voxelCenter, card);
        float2 cardUV = CardLocalToCardUV(localPos, card);
        float2 atlasUV = CardUVToAtlasUV(cardUV, card, AtlasWidth, AtlasHeight);
    
        // 用不同的固定 UV 来测试 layer 是否工作
        float4 layer0 = SurfaceAtlas.SampleLevel(LinearSampler, float3(0.5, 0.5, 0), 0);
        float4 layer3 = SurfaceAtlas.SampleLevel(LinearSampler, float3(0.5, 0.5, 3), 0);
    
        // 如果 layer 工作正常，这两个值应该不同
        // R = layer0.r, G = layer3.r, B = 它们是否相等
        float diff = abs(layer0.r - layer3.r);
        VoxelLighting[voxelCoord] = float4(layer0.r, layer3.r, diff > 0.01 ? 1.0 : 0.0, 1.0);
        return;
    }
    
    // 检查是否有效
    if (containingMesh == 0xFFFFFFFF || containingMesh == 0xFFFFFFFE)
    {
        VoxelLighting[voxelCoord] = float4(0, 0, 0, 0);
        return;
    }
    
    // 正常处理...
    float3 accumulatedLight = float3(0, 0, 0);
    float totalWeight = 0.0;
    uint cardBaseIndex = containingMesh * 6;
    
    for (uint dir = 0; dir < 6; ++dir)
    {
        uint cardIndex = cardBaseIndex + dir;
        
        if (cardIndex >= CardCount)
            continue;
        
        SurfaceCardGPU card = CardMetadata[cardIndex];
        float3 cardLight = SampleCardLighting(card, voxelCenter);
        
        accumulatedLight += cardLight;
        totalWeight += 1.0;
    }
    
    if (totalWeight > 0.0)
        accumulatedLight /= totalWeight;
    
    VoxelLighting[voxelCoord] = float4(accumulatedLight, 1.0);
}