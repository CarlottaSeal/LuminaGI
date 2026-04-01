//=============================================================================
// IntegrateSH.hlsl
// Surface Radiosity Pass 5.4: Integrate SH to Surface Cache
//
// 在 Surface Cache Atlas 全分辨率运行，从周围 Probe 插值 SH
// 重建 Indirect Lighting 并写入 Surface Cache
//=============================================================================

#include "RadiosityCacheCommon.hlsli"
#include "RadiosityCacheSH.hlsli"

// Root Parameter [1]: Surface Cache SRVs (t0-t5)
Texture2DArray<float4> SurfaceCacheAtlas : register(t0);
StructuredBuffer<SurfaceCardMetadata> CardMetadataBuffer : register(t1);

// Root Parameter [3]: Radiosity SRVs (t20-t25)
Texture2D<float4> RadiositySH_R_In : register(t23);
Texture2D<float4> RadiositySH_G_In : register(t24);
Texture2D<float4> RadiositySH_B_In : register(t25);

// Root Parameter [4]: Radiosity UAVs (u0-u5)
// 直接写入 Surface Cache 的 Indirect Light 层
RWTexture2DArray<float4> SurfaceCacheAtlasOutput : register(u0);

// Samplers
SamplerState PointSampler  : register(s0);
SamplerState LinearSampler : register(s1);

//=============================================================================
// 常量
//=============================================================================

#define LAYER_INDIRECT_LIGHT 4

//=============================================================================
// 辅助函数
//=============================================================================

// 加载单个 Probe 的 SH
SH2RGB LoadProbeSH(uint2 probeCoord)
{
    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
    {
        return InitSH();
    }
    
    SH2RGB sh;
    sh.R = RadiositySH_R_In[probeCoord];
    sh.G = RadiositySH_G_In[probeCoord];
    sh.B = RadiositySH_B_In[probeCoord];
    return sh;
}

// 采样 Atlas 像素的属性
float SampleAtlasDepth(uint2 atlasCoord)
{
    // 假设深度存在某个位置，这里简化处理
    // 实际项目中可能从专门的深度纹理读取
    return 1.0f;  // 简化：假设所有像素都有效
}

float3 SampleAtlasNormal(uint2 atlasCoord)
{
    float4 normalData = SurfaceCacheAtlas.Load(int4(atlasCoord, 1, 0));  // Layer 1 = Normal
    float3 normal = normalData.xyz * 2.0f - 1.0f;
    return SafeNormalize(normal);
}

float3 SampleAtlasAlbedo(uint2 atlasCoord)
{
    return SurfaceCacheAtlas.Load(int4(atlasCoord, 0, 0)).rgb;  // Layer 0 = Albedo
}

// 采样 Probe 中心的属性（用于权重计算）
float SampleProbeDepth(uint2 probeCoord)
{
    uint probeSpacingInt = (uint)ProbeSpacing;
    uint2 atlasCoord = probeCoord * probeSpacingInt + probeSpacingInt / 2;
    return SampleAtlasDepth(atlasCoord);
}

float3 SampleProbeNormal(uint2 probeCoord)
{
    uint probeSpacingInt = (uint)ProbeSpacing;
    uint2 atlasCoord = probeCoord * probeSpacingInt + probeSpacingInt / 2;
    return SampleAtlasNormal(atlasCoord);
}


[numthreads(8, 8, 1)]
void main(uint3 DispatchThreadID : SV_DispatchThreadID)
{
    uint2 atlasCoord = DispatchThreadID.xy;
    
    if (atlasCoord.x >= AtlasWidth || atlasCoord.y >= AtlasHeight)
        return;
    
    // 读取当前像素属性
    float3 pixelNormal = SampleAtlasNormal(atlasCoord);
    float3 pixelAlbedo = SampleAtlasAlbedo(atlasCoord);
    
    // 检查是否是有效像素（通过检查 albedo 或其他方式）
    float albedoLum = Luminance(pixelAlbedo);
    if (albedoLum < 0.001f)
    {
        SurfaceCacheAtlasOutput[uint3(atlasCoord, LAYER_INDIRECT_LIGHT)] = float4(0, 0, 0, 0);
        return;
    }
    
    // 计算像素在 Probe Grid 中的位置 (浮点数)
    float2 probeUV = float2(atlasCoord) / ProbeSpacing;
    
    // 双线性插值的 4 个 Probe
    int2 probeCoord00 = int2(floor(probeUV - 0.5f));
    int2 probeCoord10 = probeCoord00 + int2(1, 0);
    int2 probeCoord01 = probeCoord00 + int2(0, 1);
    int2 probeCoord11 = probeCoord00 + int2(1, 1);
    
    // 双线性权重
    float2 bilinearWeights = frac(probeUV - 0.5f);
    float w00 = (1.0f - bilinearWeights.x) * (1.0f - bilinearWeights.y);
    float w10 = bilinearWeights.x * (1.0f - bilinearWeights.y);
    float w01 = (1.0f - bilinearWeights.x) * bilinearWeights.y;
    float w11 = bilinearWeights.x * bilinearWeights.y;
    
    // 累积 Radiance
    float3 totalRadiance = float3(0, 0, 0);
    float totalWeight = 0.0f;
    
    // 采样 4 个 Probe
    int2 probeCoords[4] = { probeCoord00, probeCoord10, probeCoord01, probeCoord11 };
    float bilinearW[4] = { w00, w10, w01, w11 };
    
    [unroll]
    for (int i = 0; i < 4; i++)
    {
        int2 pc = probeCoords[i];
        
        // 边界检查
        if (pc.x < 0 || pc.x >= (int)ProbeGridWidth || 
            pc.y < 0 || pc.y >= (int)ProbeGridHeight)
            continue;
        
        // 加载 Probe SH
        SH2RGB probeSH = LoadProbeSH(uint2(pc));
        
        // 计算法线权重
        float3 probeNormal = SampleProbeNormal(uint2(pc));
        float normalDot = saturate(dot(pixelNormal, probeNormal));
        float normalWeight = pow(normalDot, NormalWeightScale);
        
        // 最终权重
        float weight = bilinearW[i] * normalWeight;
        
        if (weight > 0.001f)
        {
            // 从 SH 评估法线方向的 Radiance
            float3 radiance = EvaluateSHRGB(probeSH, pixelNormal);
            
            totalRadiance += radiance * weight;
            totalWeight += weight;
        }
    }
    
    float3 finalRadiance = float3(0, 0, 0);
    if (totalWeight > 0.0f)
    {
        finalRadiance = totalRadiance / totalWeight;
    }
    
    // 应用强度
    float3 indirectLight = finalRadiance * IndirectIntensity;
    
    SurfaceCacheAtlasOutput[uint3(atlasCoord, LAYER_INDIRECT_LIGHT)] = float4(indirectLight, 1.0); 
}
