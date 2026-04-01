//=============================================================================
// RadianceComposite.hlsl
// Pass 6.7: Radiance Composite
// 从追踪结果采样光照，组合成 Probe Radiance
// 
// 修改：采样 COMBINED 层（包含 Direct + Indirect * Albedo）
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

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

StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV);
StructuredBuffer<ImportanceSampleGPU> SampleDirections : register(REG_SAMPLE_DIR_SRV);
StructuredBuffer<TraceResult> VoxelTraceResults : register(REG_VOXEL_TRACE_SRV);
StructuredBuffer<TraceResult> MeshTraceResults : register(REG_MESH_TRACE_SRV);
Texture3D<float4> VoxelLighting : register(REG_VOXEL_LIGHTING_SRV);
Texture2DArray<float4> SurfaceCacheAtlas : register(REG_SURFACE_ATLAS_SRV);
StructuredBuffer<SurfaceCardMetadata> CardMetadata : register(REG_CARD_METADATA_SRV);

RWTexture2D<float4> ProbeRadiance : register(REG_PROBE_RAD_UAV);

SamplerState LinearSampler : register(s1);

//=============================================================================
// ★ 采样 COMBINED 层（索引 5）而不是 DIRECT_LIGHTING 层（索引 3）
//=============================================================================
#define SURFACE_CACHE_COMBINED_LAYER 5

float3 SampleSurfaceCacheLighting(float3 worldPos, uint cardIndex)
{
    if (cardIndex == 0xFFFFFFFF)
        return float3(0, 0, 0);
    
    SurfaceCardMetadata card = CardMetadata[cardIndex];
    
    // 世界坐标到 Card 局部 UV
    float3 toPos = worldPos - card.Origin;
    float u = dot(toPos, card.AxisX) / card.WorldSizeX + 0.5f;
    float v = dot(toPos, card.AxisY) / card.WorldSizeY + 0.5f;
    
    // 边界检查
    if (u < 0.0f || u > 1.0f || v < 0.0f || v > 1.0f)
        return float3(0, 0, 0);
    
    // 计算 Atlas 中的 UV
    float atlasWidth = float(AtlasWidth);
    float atlasHeight = float(AtlasHeight);
    
    float2 atlasUV = float2(
        (float(card.AtlasX) + u * float(card.ResolutionX)) / atlasWidth,
        (float(card.AtlasY) + v * float(card.ResolutionY)) / atlasHeight
    );
    
    // ★ 采样 COMBINED 层
    return SurfaceCacheAtlas.SampleLevel(LinearSampler, float3(atlasUV, SURFACE_CACHE_COMBINED_LAYER), 0).rgb;
}

float3 SampleVoxelLighting(float3 worldPos)
{
    float3 voxelUV = (worldPos - VoxelGridMin) / (VoxelGridMax - VoxelGridMin);
    
    if (any(voxelUV < 0.0f) || any(voxelUV > 1.0f))
        return float3(0, 0, 0);
    
    return VoxelLighting.SampleLevel(LinearSampler, voxelUV, 0).rgb;
}


//=============================================================================
// Octahedron 辅助函数
//=============================================================================

// 将 octahedron UV 转换为带 border 的纹理坐标
uint2 OctUVToTexelWithBorder(float2 octUV, uint2 probeCoord)
{
    // octUV 在 [0,1] 范围内
    // 内部区域是 OctahedronSize x OctahedronSize (8x8)
    // 加上 border 后是 BorderedOctSize x BorderedOctSize (10x10)

    // 计算在 probe 的 octahedron 纹理内的像素坐标 (跳过 border)
    uint2 localTexel = uint2(octUV * float(OctahedronSize));
    localTexel = clamp(localTexel, uint2(0, 0), uint2(OctahedronSize - 1, OctahedronSize - 1));

    // 加上 border 偏移
    localTexel += uint2(OctahedronBorder, OctahedronBorder);

    // 计算全局纹理坐标
    uint2 probeBase = probeCoord * BorderedOctSize;
    return probeBase + localTexel;
}

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    // 这个 pass 按 ray 索引 dispatch
    // dispatchThreadID.xy 对应 probeCoord 和 localRayIndex
    uint2 rayTexCoord = dispatchThreadID.xy;

    if (rayTexCoord.x >= RaysTexWidth || rayTexCoord.y >= RaysTexHeight)
        return;

    // 计算 Probe 和 Ray 索引
    uint2 probeCoord = rayTexCoord / 8;
    uint2 localRayCoord = rayTexCoord % 8;
    uint rayIndex = localRayCoord.y * 8 + localRayCoord.x;

    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
        return;

    uint probeIndex = probeCoord.y * ProbeGridWidth + probeCoord.x;
    uint globalRayIndex = probeIndex * RaysPerProbe + rayIndex;

    ScreenProbeGPU probe = ProbeBuffer[probeIndex];
    if (probe.Validity <= 0.0f || rayIndex >= RaysPerProbe)
    {
        // 仍然需要写入，使用原始坐标
        ProbeRadiance[rayTexCoord] = float4(0, 0, 0, 0);
        return;
    }

    ImportanceSampleGPU sampleData = SampleDirections[globalRayIndex];

    float3 rayDir = sampleData.Direction;
    float pdf = sampleData.PDF;

    // 跳过无效方向
    if (length(rayDir) < 0.001f)
    {
        ProbeRadiance[rayTexCoord] = float4(0, 0, 0, 0);
        return;
    }

    TraceResult meshResult = MeshTraceResults[globalRayIndex];
    TraceResult voxelResult = VoxelTraceResults[globalRayIndex];

    float3 radiance = float3(0, 0, 0);

    // 1. 优先 Mesh Trace
    if (meshResult.Validity > 0.0f && meshResult.HitDistance > 0.001f)
    {
        // 从 Surface Cache 采样 COMBINED lighting
        radiance = SampleSurfaceCacheLighting(meshResult.HitPosition, meshResult.HitCardIndex);

        // 如果采样失败，用固定颜色 fallback
        if (length(radiance) < 0.001f)
        {
            radiance = float3(0.3, 0.3, 0.3);
        }
    }
    // 2. Voxel Trace
    else if (voxelResult.Validity > 0.0f)
    {
        radiance = SampleVoxelLighting(voxelResult.HitPosition);
    }
    // 3. 天空光
    else
    {
        radiance = SampleSimpleSky(rayDir, SkyIntensity);

        if (SkyIntensity < 0.001f)
        {
            radiance = float3(0.3, 0.5, 0.7);
        }
    }

    // Cosine 加权和重要性采样校正
    float cosWeight = saturate(dot(rayDir, probe.WorldNormal));
    float weight = cosWeight / max(pdf, 0.001f);

    // ★ 使用 Octahedron 映射：根据 ray direction 计算写入位置
    float2 octUV = DirectionToOctahedronUV(rayDir);
    uint2 octTexel = OctUVToTexelWithBorder(octUV, probeCoord);

    // 原子累加到 octahedron 纹理位置
    // 注意：由于多条 ray 可能映射到同一个 texel，这里使用累加
    // 后续的 filter pass 会进行归一化
    float4 contribution = float4(radiance * weight, weight);

    // 写入 octahedron 位置（如果纹理尺寸匹配 OctTexWidth/Height）
    // 同时也写入原始位置作为 fallback
    ProbeRadiance[rayTexCoord] = contribution;
}
