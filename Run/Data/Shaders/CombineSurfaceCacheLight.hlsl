//=============================================================================
// CombineSurfaceCacheLight.hlsl
// 合并 Surface Cache 的 DirectLight + IndirectLight → CombinedLight
// 用于多次反弹 GI：Combined 会被注入到 VoxelLighting，供下一次 Radiosity 使用
//=============================================================================

#include "SurfaceRadiosity/RadiosityCacheCommon.hlsli"

// Surface Cache Atlas (读取) - 已经绑定在 t0
Texture2DArray<float4> SurfaceCacheAtlas : register(t0);

// Surface Cache Atlas (写入) - 绑定在 u0
RWTexture2DArray<float4> SurfaceCacheOutput : register(u0);

// DirectIntensity 不在 cbuffer 中，直接使用 1.0
static const float DirectIntensity = 1.0f;

#define LAYER_ALBEDO    0
#define LAYER_DIRECT    3
#define LAYER_INDIRECT  4
#define LAYER_COMBINED  5

[numthreads(8, 8, 1)]
void CSMain(uint3 DispatchThreadID : SV_DispatchThreadID)
{
    uint2 coord = DispatchThreadID.xy;

    if (coord.x >= AtlasWidth || coord.y >= AtlasHeight)
        return;

    // 读取 Albedo 检查像素有效性
    float4 albedo = SurfaceCacheAtlas.Load(int4(coord, LAYER_ALBEDO, 0));
    if (albedo.a < 0.1)
    {
        SurfaceCacheOutput[uint3(coord, LAYER_COMBINED)] = float4(0, 0, 0, 0);
        return;
    }

    // 读取直接光 (layer 3)
    float4 direct = SurfaceCacheAtlas.Load(int4(coord, LAYER_DIRECT, 0));

    // 读取间接光 (layer 4) - 来自上一帧的 Radiosity
    float4 indirect = SurfaceCacheAtlas.Load(int4(coord, LAYER_INDIRECT, 0));

    // 合并光照
    // 首帧时 indirect 可能为空，这是正常的
    float3 combined = direct.rgb * DirectIntensity;

    // 只有当 indirect 有效时才添加 (alpha > 0 表示已计算)
    if (indirect.a > 0.01)
    {
        combined += indirect.rgb * IndirectIntensity;
    }

    // 写入 Combined 层 (layer 5)
    SurfaceCacheOutput[uint3(coord, LAYER_COMBINED)] = float4(combined, direct.a);
}
