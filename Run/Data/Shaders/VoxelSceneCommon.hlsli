#ifndef VOXEL_SCENE_COMMON_HLSLI
#define VOXEL_SCENE_COMMON_HLSLI

// SDF is generated within [boundsMin, boundsMax]
struct MeshSDFInfoGPU
{
    float4x4 WorldToLocal;
    float4x4 LocalToWorld;
    float3   LocalBoundsMin;
    float    LocalToWorldScale;
    float3   LocalBoundsMax;
    uint     SDFTextureIndex;
    float3   WorldBoundsMin;
    uint     CardStartIndex;
    float3   WorldBoundsMax;
    uint     CardCount;
};

struct SurfaceCardGPU
{
    uint AtlasX, AtlasY;
    uint ResolutionX, ResolutionY;
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
    float3 SceneBoundsMin;
    uint VoxelResolution;

    float3 SceneBoundsMax;
    uint InstanceCount;

    float3 VoxelSize;
    float SDFThreshold;

    uint MaxTraceSteps;
    float MaxTraceDistance;
    uint CardCount;
    uint _padding;

    float AtlasWidth;
    float AtlasHeight;
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

// World position -> Card local position
float3 WorldToCardLocal(float3 worldPos, SurfaceCardGPU card)
{
    float3 origin = GetCardOrigin(card);
    float3 axisX = GetCardAxisX(card);
    float3 axisY = GetCardAxisY(card);
    float3 normal = GetCardNormal(card);

    float3 offset = worldPos - origin;

    float3 localPos;
    localPos.x = dot(offset, axisX);
    localPos.y = dot(offset, axisY);
    localPos.z = dot(offset, normal);

    return localPos;
}

// Card local position -> Card UV [0, 1]
float2 CardLocalToCardUV(float3 localPos, SurfaceCardGPU card)
{
    float2 worldSize = GetCardWorldSize(card);
    float2 halfSize = worldSize * 0.5;

    float2 ndc;
    ndc.x = localPos.x / halfSize.x;
    ndc.y = -localPos.y / halfSize.y;  // Y flip to match CardCapture

    float2 cardUV = ndc * 0.5 + 0.5;

    return cardUV;
}

// Card UV -> Atlas UV
float2 CardUVToAtlasUV(float2 cardUV, SurfaceCardGPU card, float atlasWidth, float atlasHeight)
{
    float2 atlasPixel;
    atlasPixel.x = card.AtlasX + cardUV.x * card.ResolutionX;
    atlasPixel.y = card.AtlasY + cardUV.y * card.ResolutionY;

    float2 atlasUV;
    atlasUV.x = atlasPixel.x / atlasWidth;
    atlasUV.y = atlasPixel.y / atlasHeight;

    return atlasUV;
}

// Direct conversion from localPos to atlasUV
float2 CardLocalToAtlasUV(float3 localPos, SurfaceCardGPU card, float atlasWidth, float atlasHeight)
{
    // 1. localPos → cardUV
    float2 cardUV = CardLocalToCardUV(localPos, card);
    
    // 2. cardUV → atlasUV
    return CardUVToAtlasUV(cardUV, card, atlasWidth, atlasHeight);
}

// Check if Card UV is valid
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

    if (abs(localPos.x) > halfSizeX || abs(localPos.y) > halfSizeY)
        return false;

    if (depthTolerance > 0 && (localPos.z < 0 || localPos.z > depthTolerance))
        return false;

    return true;
}

// Max number of SDF textures in bindless array
#define MAX_SDF_TEXTURES 128

#endif
