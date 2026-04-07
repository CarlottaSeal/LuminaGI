//=============================================================================
// SurfaceCacheCombine.hlsl
// Merges Surface Cache direct and indirect lighting into the Combined layer
// Combined = Direct + Indirect * Albedo
//
// All layers use RWTexture2DArray for read/write to avoid SRV/UAV state conflicts
//
// Root Signature:
// [0] SRV Table (t0): CardMetadata
// [1] UAV Table (u0): SurfaceCacheAtlas (read and write)
//=============================================================================

#define TILE_SIZE 8

// Card Metadata layout — must match C++ SurfaceCardMetadata exactly (112 bytes)
struct SurfaceCardMetadata
{
    uint AtlasX;             // Atlas pixel X
    uint AtlasY;             // Atlas pixel Y
    uint ResolutionX;        // Card resolution X
    uint ResolutionY;        // Card resolution Y  (= 16 bytes total)

    float3 Origin;           // World-space origin
    float Padding0;          //               = 16 bytes

    float3 AxisX;            // X axis direction
    float Padding1;          //               = 16 bytes

    float3 AxisY;            // Y axis direction
    float Padding2;          //               = 16 bytes

    float3 Normal;           // Surface normal
    float Padding3;          //               = 16 bytes

    float WorldSizeX;        // World size X
    float WorldSizeY;        // World size Y
    uint Direction;          // Face direction 0-5
    uint GlobalCardID;       //               = 16 bytes

    uint4 LightMask;         // 128-bit light mask (= 16 bytes)
};                           // Total: 112 bytes

// Card Metadata Buffer
StructuredBuffer<SurfaceCardMetadata> CardMetadata : register(t0);

// Surface Cache Atlas — RWTexture2DArray for simultaneous read and write
RWTexture2DArray<float4> SurfaceCacheAtlas : register(u0);

// Layer indices — matches SurfaceCacheLayerType enum
#define LAYER_ALBEDO          0
#define LAYER_DIRECT_LIGHT    3
#define LAYER_INDIRECT_LIGHT  4
#define LAYER_COMBINED_LIGHT  5

[numthreads(TILE_SIZE, TILE_SIZE, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID, uint3 groupID : SV_GroupID)
{
    uint cardIndex = groupID.z;
    SurfaceCardMetadata card = CardMetadata[cardIndex];
    
    // Local pixel coordinate within card
    uint2 localPixel = dispatchThreadID.xy;
    
    // Check if within card bounds
    if (localPixel.x >= card.ResolutionX || localPixel.y >= card.ResolutionY)
        return;
    
    // Global pixel coordinate in atlas
    int2 atlasPixel = int2(card.AtlasX + localPixel.x, 
                           card.AtlasY + localPixel.y);
    
    // Read each layer via RWTexture
    float3 albedo = SurfaceCacheAtlas[int3(atlasPixel, LAYER_ALBEDO)].rgb;
    float3 directLight = SurfaceCacheAtlas[int3(atlasPixel, LAYER_DIRECT_LIGHT)].rgb;
    float3 indirectLight = SurfaceCacheAtlas[int3(atlasPixel, LAYER_INDIRECT_LIGHT)].rgb;
    
    // Merge lighting: Direct already contains albedo; Indirect must be multiplied by albedo
    float3 combined = directLight + indirectLight * albedo;
    
    // Write Combined layer
    SurfaceCacheAtlas[int3(atlasPixel, LAYER_COMBINED_LIGHT)] = float4(combined, 1.0);
}
