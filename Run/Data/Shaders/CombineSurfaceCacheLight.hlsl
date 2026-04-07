//=============================================================================
// CombineSurfaceCacheLight.hlsl
// Combines DirectLight + IndirectLight -> CombinedLight for multi-bounce GI
//=============================================================================

#include "SurfaceRadiosity/RadiosityCacheCommon.hlsli"

Texture2DArray<float4> SurfaceCacheAtlas : register(t0);
RWTexture2DArray<float4> SurfaceCacheOutput : register(u0);

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

    float4 albedo = SurfaceCacheAtlas.Load(int4(coord, LAYER_ALBEDO, 0));
    if (albedo.a < 0.1)
    {
        SurfaceCacheOutput[uint3(coord, LAYER_COMBINED)] = float4(0, 0, 0, 0);
        return;
    }

    float4 direct = SurfaceCacheAtlas.Load(int4(coord, LAYER_DIRECT, 0));
    float4 indirect = SurfaceCacheAtlas.Load(int4(coord, LAYER_INDIRECT, 0));

    // Direct layer already includes albedo (directLight * albedo)
    // Indirect is raw irradiance; multiply by surface albedo
    // Note: IndirectIntensity is applied once in FinalGather, not here
    float3 combined = direct.rgb * DirectIntensity + indirect.rgb * albedo.rgb;

    SurfaceCacheOutput[uint3(coord, LAYER_COMBINED)] = float4(combined, direct.a);
}
