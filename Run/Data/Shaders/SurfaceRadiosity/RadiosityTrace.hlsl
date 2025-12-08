//=============================================================================
// RadiosityTrace.hlsl
// Surface Radiosity Pass 5.1: Radiosity Trace
// 
// 在 Probe Grid (1024x1024) 上追踪光线，采样 Surface Cache 或天空
//=============================================================================

#include "RadiosityCacheCommon.hlsli"

//=============================================================================
// 资源绑定 - 与 Root Signature 匹配
//=============================================================================

// Root Parameter [1]: Surface Cache SRVs (t0-t5)
Texture2DArray<float4>              SurfaceCacheAtlas   : register(t0);  // 6 layers
StructuredBuffer<SurfaceCardMetadata> CardMetadataBuffer : register(t1);

// Root Parameter [2]: Global SDF + Voxel Lighting (t10-t11)
Texture3D<float>    GlobalSDF       : register(t10);
Texture3D<float4>   VoxelLighting   : register(t11);

// Root Parameter [3]: Radiosity SRVs (t20-t25)
Texture2D<float4>   RadiosityHistory : register(t21);

// Root Parameter [4]: Radiosity UAVs (u0-u5)
RWTexture2D<float4> RadiosityTraceResult : register(u0);

// Samplers
SamplerState PointSampler   : register(s0);
SamplerState LinearSampler  : register(s1);

//=============================================================================
// 常量
//=============================================================================

#define LAYER_ALBEDO        0
#define LAYER_NORMAL        1
#define LAYER_MATERIAL      2
#define LAYER_DIRECT_LIGHT  3
#define LAYER_INDIRECT_LIGHT 4
#define LAYER_COMBINED      5

//=============================================================================
// Global SDF 追踪
//=============================================================================

float SampleGlobalSDF(float3 worldPos)
{
    // 世界坐标转 SDF UV
    float3 sdfUV = (worldPos - GlobalSDFCenter) / (GlobalSDFExtent * 2.0f) + 0.5f;
    
    if (any(sdfUV < 0.0f) || any(sdfUV > 1.0f))
        return TraceMaxDistance;
    
    return GlobalSDF.SampleLevel(LinearSampler, sdfUV, 0);
}

bool TraceGlobalSDF(
    float3 origin,
    float3 direction,
    float maxDist,
    out float hitDist,
    out float3 hitPos)
{
    float t = RayBias;
    
    [loop]
    for (uint i = 0; i < TraceMaxSteps; i++)
    {
        float3 pos = origin + direction * t;
        float dist = SampleGlobalSDF(pos);
        
        if (dist < TraceHitThreshold)
        {
            hitDist = t;
            hitPos = pos;
            return true;
        }
        
        t += max(dist, 0.1f);
        
        if (t > maxDist)
            break;
    }
    
    hitDist = maxDist;
    hitPos = origin + direction * maxDist;
    return false;
}

//=============================================================================
// 从 Voxel Lighting 采样
//=============================================================================

float3 SampleVoxelLightingAtPosition(float3 worldPos)
{
    float3 voxelUV = (worldPos - GlobalSDFCenter) / (GlobalSDFExtent * 2.0f) + 0.5f;
    
    if (any(voxelUV < 0.0f) || any(voxelUV > 1.0f))
        return float3(0, 0, 0);
    
    return VoxelLighting.SampleLevel(LinearSampler, voxelUV, 0).rgb;
}

//=============================================================================
// Card 查找和采样
//=============================================================================

uint FindCardAtAtlasPixel(uint2 atlasPixel)
{
    // 线性搜索 (可以用空间数据结构优化)
    [loop]
    for (uint i = 0; i < ActiveCardCount; i++)
    {
        SurfaceCardMetadata card = CardMetadataBuffer[i];
        
        if (atlasPixel.x >= card.AtlasX && 
            atlasPixel.x < card.AtlasX + card.ResolutionX &&
            atlasPixel.y >= card.AtlasY && 
            atlasPixel.y < card.AtlasY + card.ResolutionY)
        {
            return i;
        }
    }
    return 0xFFFFFFFF;
}

float3 ReconstructWorldPosition(uint2 atlasPixel, uint cardIndex)
{
    SurfaceCardMetadata card = CardMetadataBuffer[cardIndex];
    
    float2 localPixel = float2(atlasPixel) - float2(card.AtlasX, card.AtlasY);
    float2 uv = (localPixel + 0.5f) / float2(card.ResolutionX, card.ResolutionY);
    
    return card.Origin 
         + card.AxisX * (uv.x - 0.5f) * card.WorldSize.x
         + card.AxisY * (uv.y - 0.5f) * card.WorldSize.y;
}

//=============================================================================
// 半球采样
//=============================================================================

float3 GetHemisphereDirection(uint rayIndex, uint probeIndex, float3 normal)
{
    // 添加时间抖动
    uint seed = probeIndex * RaysPerProbe + rayIndex + FrameIndex * 1337u;
    float jitterX = Random(seed);
    float jitterY = Random(seed + 7919u);
    
    // Fibonacci 分布 + 抖动
    float phi = TWO_PI * (frac(float(rayIndex) * 0.6180339887f) + jitterX * 0.1f);
    float cosTheta = 1.0f - (2.0f * rayIndex + 1.0f + jitterY * 0.5f) / (2.0f * RaysPerProbe);
    cosTheta = max(0.0f, cosTheta);
    float sinTheta = sqrt(1.0f - cosTheta * cosTheta);
    
    float3 localDir = float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
    
    // 变换到 Normal 空间
    float3 up = abs(normal.y) < 0.999f ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 tangent = normalize(cross(up, normal));
    float3 bitangent = cross(normal, tangent);
    
    return normalize(tangent * localDir.x + bitangent * localDir.y + normal * localDir.z);
}

//=============================================================================
// 主计算着色器
//=============================================================================

[numthreads(8, 8, 1)]
void main(uint3 DispatchThreadID : SV_DispatchThreadID)
{
    uint2 probeCoord = DispatchThreadID.xy;
    
    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
        return;
    
    // Probe 对应的 Atlas 中心像素
    uint probeSpacingInt = (uint)ProbeSpacing;
    uint2 atlasCenter = probeCoord * probeSpacingInt + probeSpacingInt / 2;
    
    // 查找 Probe 所在的 Card
    uint cardIndex = FindCardAtAtlasPixel(atlasCenter);
    
    if (cardIndex == 0xFFFFFFFF)
    {
        RadiosityTraceResult[probeCoord] = float4(0, 0, 0, 0);
        return;
    }
    
    // 重建世界坐标和法线
    float3 worldPos = ReconstructWorldPosition(atlasCenter, cardIndex);
    float3 normal = CardMetadataBuffer[cardIndex].Normal;
    float3 rayOrigin = worldPos + normal * RayBias;
    
    // 累积光照
    float3 totalRadiance = float3(0, 0, 0);
    float totalWeight = 0.0f;
    
    uint probeIndex = probeCoord.y * ProbeGridWidth + probeCoord.x;
    
    // 追踪多条光线
    [loop]
    for (uint rayIdx = 0; rayIdx < RaysPerProbe; rayIdx++)
    {
        float3 rayDir = GetHemisphereDirection(rayIdx, probeIndex, normal);
        float3 radiance = float3(0, 0, 0);
        
        // 追踪 Global SDF
        float hitDist;
        float3 hitPos;
        bool hit = TraceGlobalSDF(rayOrigin, rayDir, TraceMaxDistance, hitDist, hitPos);
        
        if (hit)
        {
            // 命中：采样 Voxel Lighting
            radiance = SampleVoxelLightingAtPosition(hitPos);
        }
        else
        {
            // 未命中：天空光
            radiance = SampleSkyLight(rayDir, SkyIntensity);
        }
        
        // Cosine 加权
        float cosWeight = max(0.0f, dot(rayDir, normal));
        totalRadiance += radiance * cosWeight;
        totalWeight += cosWeight;
    }
    
    // 归一化
    if (totalWeight > 0.001f)
        totalRadiance /= totalWeight;
    
    // 时间累积
    float4 history = RadiosityHistory[probeCoord];
    if (history.w > 0.0f)
    {
        totalRadiance = lerp(history.rgb, totalRadiance, TemporalBlendFactor);
    }
    
    RadiosityTraceResult[probeCoord] = float4(totalRadiance, 1.0f);
}
