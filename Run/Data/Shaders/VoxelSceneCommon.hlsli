#ifndef VOXEL_SCENE_COMMON_HLSLI
#define VOXEL_SCENE_COMMON_HLSLI

// SDF是在 [boundsMin, boundsMax] 范围内生成的
struct MeshSDFInfoGPU
{
    float4x4 WorldToLocal;
    float4x4 LocalToWorld;
    float3   LocalBoundsMin;
    float    LocalToWorldScale;
    float3   LocalBoundsMax;
    uint     SDFTextureIndex;   // 4 bytes  - Index into bindless SDF texture array
    uint     CardStartIndex;
    uint     CardCount;
    uint     Padding0;
    uint     Padding1;
};

struct SurfaceCardGPU
{
    uint AtlasX, AtlasY;           // Atlas像素坐标
    uint ResolutionX, ResolutionY; // 分辨率
    float OriginX, OriginY, OriginZ; float Padding0;
    float AxisXx, AxisXy, AxisXz;    float Padding1;
    float AxisYx, AxisYy, AxisYz;    float Padding2;
    float NormalX, NormalY, NormalZ; float Padding3;
    float WorldSizeX, WorldSizeY;
    uint Direction, GlobalCardID;
    uint LightMask0, LightMask1, LightMask2, LightMask3;
};

struct VoxelVisibilityGPU
{
    uint HitInstanceIndex;
    float HitDistance;
};

cbuffer VoxelSceneConstants : register(b0)
{
    float3 SceneBoundsMin;       // offset 0
    uint VoxelResolution;        // offset 12
    
    float3 SceneBoundsMax;       // offset 16
    uint InstanceCount;          // offset 28 (或CardCount，取决于哪个Pass)
    
    float3 VoxelSize;            // offset 32 
    float SDFThreshold;          // offset 44
    
    uint MaxTraceSteps;          // offset 48
    float MaxTraceDistance;      // offset 52
    uint CardCount;            // offset 60 (仅InjectVoxelLighting使用)
    uint _padding;              // offset 56 (对齐到 64 bytes)

    float AtlasWidth;            // offset 64
    float AtlasHeight;           // offset 68
    float _padding2[2];  
};

static const float3 VoxelDirections[6] = 
{
    float3( 1,  0,  0),  // +X
    float3(-1,  0,  0),  // -X
    float3( 0,  1,  0),  // +Y
    float3( 0, -1,  0),  // -Y
    float3( 0,  0,  1),  // +Z
    float3( 0,  0, -1)   // -Z
};

float3 VoxelToWorld(uint3 voxelCoord)
{
    return SceneBoundsMin + (float3(voxelCoord) + 0.5) * VoxelSize;
}

uint3 WorldToVoxel(float3 worldPos)
{
    float3 localPos = (worldPos - SceneBoundsMin) / VoxelSize;
    return uint3(clamp(localPos, float3(0, 0, 0), float3(VoxelResolution - 1, VoxelResolution - 1, VoxelResolution - 1)));
}

float3 WorldToVoxelUVW(float3 worldPos)
{
    return (worldPos - SceneBoundsMin) / (SceneBoundsMax - SceneBoundsMin);
}

uint GetVoxelIndex(uint3 voxelCoord)
{
    return voxelCoord.x + voxelCoord.y * VoxelResolution + 
           voxelCoord.z * VoxelResolution * VoxelResolution;
}

uint GetCardDirectionIndex(float3 direction)
{
    float3 absDir = abs(direction);
    
    if (absDir.x >= absDir.y && absDir.x >= absDir.z)
        return (direction.x > 0) ? 0 : 1;
    else if (absDir.y >= absDir.x && absDir.y >= absDir.z)
        return (direction.y > 0) ? 2 : 3;
    else
        return (direction.z > 0) ? 4 : 5;
}

float3 GetCardOrigin(SurfaceCardGPU card)
{
    return float3(card.OriginX, card.OriginY, card.OriginZ);
}

float3 GetCardAxisX(SurfaceCardGPU card)
{
    return float3(card.AxisXx, card.AxisXy, card.AxisXz);
}

float3 GetCardAxisY(SurfaceCardGPU card)
{
    return float3(card.AxisYx, card.AxisYy, card.AxisYz);
}

float3 GetCardNormal(SurfaceCardGPU card)
{
    return float3(card.NormalX, card.NormalY, card.NormalZ);
}

float2 GetCardWorldSize(SurfaceCardGPU card)
{
    return float2(card.WorldSizeX, card.WorldSizeY);
}

// ============================================================
// 世界坐标 → Card 局部坐标
// 返回值：
//   localPos.x: 沿 CardAxisX 的距离，范围 [-WorldSizeX/2, +WorldSizeX/2]
//   localPos.y: 沿 CardAxisY 的距离，范围 [-WorldSizeY/2, +WorldSizeY/2]
//   localPos.z: 沿 CardNormal 的距离（深度）
// ============================================================
float3 WorldToCardLocal(float3 worldPos, SurfaceCardGPU card)
{
    float3 origin = GetCardOrigin(card);
    float3 axisX = GetCardAxisX(card);
    float3 axisY = GetCardAxisY(card);
    float3 normal = GetCardNormal(card);
    
    // 计算相对于 Card 原点的偏移
    float3 offset = worldPos - origin;
    
    // 投影到 Card 的三个轴上
    float3 localPos;
    localPos.x = dot(offset, axisX);
    localPos.y = dot(offset, axisY);
    localPos.z = dot(offset, normal);
    
    return localPos;
}

// Card 局部坐标 → Card UV [0, 1]
// 匹配 CardCapture.hlsl：
//   ndc.x = localPos.x / (CardSize.x * 0.5)  → [-1, 1]
//   ndc.y = -localPos.y / (CardSize.y * 0.5) → [-1, 1]，Y翻转
//   
// localPos 范围是 [-CardSize/2, +CardSize/2]
float2 CardLocalToCardUV(float3 localPos, SurfaceCardGPU card)
{
    float2 worldSize = GetCardWorldSize(card);
    float2 halfSize = worldSize * 0.5;
    
    // 局部坐标 → NDC [-1, 1]
    float2 ndc;
    ndc.x = localPos.x / halfSize.x;
    ndc.y = -localPos.y / halfSize.y;  // Y 翻转！匹配 CardCapture
    
    // NDC → UV [0, 1]
    float2 cardUV = ndc * 0.5 + 0.5;
    
    return cardUV;
}

// ============================================================
// Card UV → Atlas UV
// ============================================================
float2 CardUVToAtlasUV(float2 cardUV, SurfaceCardGPU card, float atlasWidth, float atlasHeight)
{
    // Card UV [0,1] → Atlas 像素坐标
    float2 atlasPixel;
    atlasPixel.x = card.AtlasX + cardUV.x * card.ResolutionX;
    atlasPixel.y = card.AtlasY + cardUV.y * card.ResolutionY;
    
    // 像素坐标 → 归一化 UV [0, 1]
    float2 atlasUV;
    atlasUV.x = atlasPixel.x / atlasWidth;
    atlasUV.y = atlasPixel.y / atlasHeight;
    
    return atlasUV;
}

// 旧函数保留（已修正）- 直接从 localPos 到 atlasUV
float2 CardLocalToAtlasUV(float3 localPos, SurfaceCardGPU card, float atlasWidth, float atlasHeight)
{
    // 1. localPos → cardUV
    float2 cardUV = CardLocalToCardUV(localPos, card);
    
    // 2. cardUV → atlasUV
    return CardUVToAtlasUV(cardUV, card, atlasWidth, atlasHeight);
}

// 检查 Card UV 是否有效
bool IsCardUVValid(float2 cardUV)
{
    return cardUV.x >= 0.0 && cardUV.x <= 1.0 &&
           cardUV.y >= 0.0 && cardUV.y <= 1.0;
}

bool IsPointInCardBounds(float3 localPos, SurfaceCardGPU card, float depthTolerance)
{
    float2 worldSize = GetCardWorldSize(card);
    float halfSizeX = worldSize.x * 0.5;
    float halfSizeY = worldSize.y * 0.5;
    
    // 检查 XY 平面上是否在 Card 范围内
    if (abs(localPos.x) > halfSizeX || abs(localPos.y) > halfSizeY)
        return false;
    
    // 检查深度（沿法线方向）
    if (depthTolerance > 0 && (localPos.z < 0 || localPos.z > depthTolerance))
        return false;
    
    return true;
}

// Max number of SDF textures in bindless array
#define MAX_SDF_TEXTURES 128

#endif
