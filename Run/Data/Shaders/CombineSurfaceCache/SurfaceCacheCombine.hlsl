// Must match C++ SurfaceCardMetadata (112 bytes)
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

StructuredBuffer<SurfaceCardMetadata> CardMetadata : register(t0);
RWTexture2DArray<float4> SurfaceCacheAtlas : register(u0);

#define TILE_SIZE 8
#define LAYER_ALBEDO          0
#define LAYER_DIRECT_LIGHT    3
#define LAYER_INDIRECT_LIGHT  4
#define LAYER_COMBINED_LIGHT  5

[numthreads(TILE_SIZE, TILE_SIZE, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID, uint3 groupID : SV_GroupID)
{
    uint cardIndex = groupID.z;
    SurfaceCardMetadata card = CardMetadata[cardIndex];

    uint2 localPixel = dispatchThreadID.xy;
    if (localPixel.x >= card.ResolutionX || localPixel.y >= card.ResolutionY)
        return;

    int2 atlasPixel = int2(card.AtlasX + localPixel.x,
                           card.AtlasY + localPixel.y);

    float3 albedo = SurfaceCacheAtlas[int3(atlasPixel, LAYER_ALBEDO)].rgb;
    float3 directLight = SurfaceCacheAtlas[int3(atlasPixel, LAYER_DIRECT_LIGHT)].rgb;
    float3 indirectLight = SurfaceCacheAtlas[int3(atlasPixel, LAYER_INDIRECT_LIGHT)].rgb;

    float3 combined = (directLight + indirectLight) * albedo * (1.0 / 3.14159265359);

    SurfaceCacheAtlas[int3(atlasPixel, LAYER_COMBINED_LIGHT)] = float4(combined, 1.0);
}
