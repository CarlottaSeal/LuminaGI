//=============================================================================
// ConvertToSH.hlsl
// Surface Radiosity Pass 5.3: Convert to Spherical Harmonics
//
// 将滤波后的 Radiance 转换为 SH2 (L0+L1) 系数
//=============================================================================

#include "RadiosityCacheCommon.hlsli"
#include "RadiosityCacheSH.hlsli"

//=============================================================================
// 资源绑定
//=============================================================================

// Root Parameter [1]: Surface Cache SRVs (t0-t5)
Texture2DArray<float4> SurfaceCacheAtlas : register(t0);
StructuredBuffer<SurfaceCardMetadata> CardMetadataBuffer : register(t1);

// Root Parameter [3]: Radiosity SRVs (t20-t25)
Texture2D<float4>   RadiosityFiltered : register(t22);

// Root Parameter [4]: Radiosity UAVs (u0-u5)
RWTexture2D<float4> RadiositySH_R : register(u3);
RWTexture2D<float4> RadiositySH_G : register(u4);
RWTexture2D<float4> RadiositySH_B : register(u5);

//=============================================================================
// 从 Atlas 采样法线
//=============================================================================

float3 SampleProbeNormal(uint2 probeCoord)
{
    uint probeSpacingInt = (uint)ProbeSpacing;
    uint2 atlasCoord = probeCoord * probeSpacingInt + probeSpacingInt / 2;
    
    // 从法线层采样
    float4 normalData = SurfaceCacheAtlas.Load(int4(atlasCoord, 1, 0));  // Layer 1 = Normal
    float3 normal = normalData.xyz * 2.0f - 1.0f;
    return SafeNormalize(normal);
}

[numthreads(8, 8, 1)]
void main(uint3 DispatchThreadID : SV_DispatchThreadID)
{
    uint2 probeCoord = DispatchThreadID.xy;
    
    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
        return;
    
    // 读取滤波后的 Radiance
    float4 radianceData = RadiosityFiltered[probeCoord];

    float3 radiance = radianceData.rgb;
    float validity = radianceData.a;
    
    // 如果 Probe 无效，输出零 SH
    if (validity <= 0.0f)
    {
        RadiositySH_R[probeCoord] = float4(0, 0, 0, 0);
        RadiositySH_G[probeCoord] = float4(0, 0, 0, 0);
        RadiositySH_B[probeCoord] = float4(0, 0, 0, 0);
        return;
    }
    
    // 读取 Probe 法线
    float3 normal = SampleProbeNormal(probeCoord);
    // 将 Radiance 投影到 SH
    // 对于漫反射表面，主要方向是法线方向
    float4 shBasis = EvaluateSHBasis(normal);
    
    //RadiositySH_R[probeCoord] = shBasis * 3.0;  // 放大 shBasis
    //RadiositySH_G[probeCoord] = shBasis * radiance.r * 30.0;  // 放大最终结果
    //RadiositySH_B[probeCoord] = float4(radiance * 3.0, 1.0); 
    //return;
    
    float4 sh_R = shBasis * radiance.r;
    float4 sh_G = shBasis * radiance.g;
    float4 sh_B = shBasis * radiance.b;
    
    // 添加环境项 (L0) - 使一部分光照是均匀的
    float ambientScale = 0.1f;
    sh_R.x += radiance.r * ambientScale * SH_L0;
    sh_G.x += radiance.g * ambientScale * SH_L0;
    sh_B.x += radiance.b * ambientScale * SH_L0;
    
    // 输出
    RadiositySH_R[probeCoord] = sh_R;
    RadiositySH_G[probeCoord] = sh_G;
    RadiositySH_B[probeCoord] = sh_B;
}
