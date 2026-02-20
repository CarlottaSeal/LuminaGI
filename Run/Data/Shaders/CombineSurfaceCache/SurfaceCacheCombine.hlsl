//=============================================================================
// SurfaceCacheCombine.hlsl
// 合并 Surface Cache 的 Direct 和 Indirect 光照到 Combined 层
// Combined = Direct + Indirect * Albedo
//
// 全部使用 RWTexture2DArray 读写，避免 SRV/UAV 状态冲突
//
// Root Signature:
// [0] SRV Table (t0): CardMetadata
// [1] UAV Table (u0): SurfaceCacheAtlas (用于读取和写入)
//=============================================================================

#define TILE_SIZE 8

// Card Metadata 结构 - 与 C++ 端精确匹配 (112 bytes)
struct SurfaceCardMetadata
{
    uint AtlasX;             // Atlas像素坐标X
    uint AtlasY;             // Atlas像素坐标Y
    uint ResolutionX;        // Card分辨率X
    uint ResolutionY;        // Card分辨率Y   = 16 bytes

    float3 Origin;           // 世界原点
    float Padding0;          //               = 16 bytes

    float3 AxisX;            // X轴方向
    float Padding1;          //               = 16 bytes

    float3 AxisY;            // Y轴方向
    float Padding2;          //               = 16 bytes

    float3 Normal;           // 法线
    float Padding3;          //               = 16 bytes

    float WorldSizeX;        // 世界尺寸X
    float WorldSizeY;        // 世界尺寸Y
    uint Direction;          // 方向 0-5
    uint GlobalCardID;       //               = 16 bytes

    uint4 LightMask;         // 支持128个lights = 16 bytes
};                           // Total: 112 bytes

// Card Metadata Buffer
StructuredBuffer<SurfaceCardMetadata> CardMetadata : register(t0);

// Surface Cache Atlas - 用 RWTexture2DArray 同时读取和写入
RWTexture2DArray<float4> SurfaceCacheAtlas : register(u0);

// 层索引 - 与 SurfaceCacheLayerType 枚举对应
#define LAYER_ALBEDO          0
#define LAYER_DIRECT_LIGHT    3
#define LAYER_INDIRECT_LIGHT  4
#define LAYER_COMBINED_LIGHT  5

[numthreads(TILE_SIZE, TILE_SIZE, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID, uint3 groupID : SV_GroupID)
{
    uint cardIndex = groupID.z;
    SurfaceCardMetadata card = CardMetadata[cardIndex];
    
    // Card 内的局部像素坐标
    uint2 localPixel = dispatchThreadID.xy;
    
    // 检查是否在 Card 范围内
    if (localPixel.x >= card.ResolutionX || localPixel.y >= card.ResolutionY)
        return;
    
    // Atlas 中的全局像素坐标
    int2 atlasPixel = int2(card.AtlasX + localPixel.x, 
                           card.AtlasY + localPixel.y);
    
    // 用 RWTexture 读取各层数据
    float3 albedo = SurfaceCacheAtlas[int3(atlasPixel, LAYER_ALBEDO)].rgb;
    float3 directLight = SurfaceCacheAtlas[int3(atlasPixel, LAYER_DIRECT_LIGHT)].rgb;
    float3 indirectLight = SurfaceCacheAtlas[int3(atlasPixel, LAYER_INDIRECT_LIGHT)].rgb;
    
    // 合并光照: Direct 已包含 albedo，Indirect 需要乘 albedo
    float3 combined = directLight + indirectLight * albedo;
    
    // 写入 Combined 层
    SurfaceCacheAtlas[int3(atlasPixel, LAYER_COMBINED_LIGHT)] = float4(combined, 1.0);
}
