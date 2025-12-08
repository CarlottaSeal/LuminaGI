//=============================================================================
// MeshSDFTrace.hlsl
// Pass 6.5: Mesh SDF Trace
// 追踪 Mesh SDF (近距离)，命中后采样 Surface Cache Final Lighting
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

#define MAX_SDF_TEXTURES 64
#define MAX_MESH_COUNT 256

//=============================================================================
// 结构体定义 (应与 C++ 完全匹配)
//=============================================================================

struct MeshSDFInfoGPU
{
    float4x4 WorldToLocal;
    float4x4 LocalToWorld;
    float3   LocalBoundsMin;
    float    LocalToWorldScale;
    float3   LocalBoundsMax;
    uint     SDFTextureIndex;
    uint     CardStartIndex;
    uint     CardCount;
    uint     Padding0;
    uint     Padding1;
};

struct SurfaceCardMetadata
{
    float3 WorldOrigin;
    float  WorldSizeX;
    float3 WorldAxisX;
    float  WorldSizeY;
    float3 WorldAxisY;
    uint   AtlasOffsetX;
    float3 WorldNormal;
    uint   AtlasOffsetY;
    uint   AtlasSizeX;
    uint   AtlasSizeY;
    uint   MeshIndex;
    uint   CardDirection;
};


// 输入 - Screen Probe 资源
StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV);         // t401
StructuredBuffer<ImportanceSampleGPU> SampleDirections : register(REG_SAMPLE_DIR_SRV); // t410

// Mesh SDF 相关 - 使用 Bindless 数组 (与 BuildGlobalSDF 相同)
StructuredBuffer<MeshSDFInfoGPU> InstanceInfos : register(REG_INSTANCE_INFO_SRV);  // t380
Texture3D<float> g_SDFTextures[MAX_SDF_TEXTURES] : register(t0, space1);  // Bindless SDF

// Surface Cache - 多层纹理
Texture2DArray<float4> SurfaceCacheAtlas : register(REG_SURFACE_ATLAS_SRV);      // t381
StructuredBuffer<SurfaceCardMetadata> CardMetadata : register(REG_CARD_METADATA_SRV); // t382

// Global SDF (用于加速剔除) - R=距离, G=实例索引
Texture3D<float2> GlobalSDF : register(REG_GLOBAL_SDF_SRV);  // t378

// 输出
RWStructuredBuffer<TraceResult> MeshTraceResults : register(REG_MESH_TRACE_UAV);  // u411

// Samplers
SamplerState LinearSampler : register(s1);
SamplerState PointSampler  : register(s0);

uint FindBestCard(MeshSDFInfoGPU instance, float3 worldNormal);
float3 SampleSurfaceCacheLighting(float3 worldPos, uint cardIndex);

float SampleMeshSDF(MeshSDFInfoGPU instance, float3 localPos)
{
    float3 bmin = instance.LocalBoundsMin;
    float3 bmax = instance.LocalBoundsMax;
    float3 uvw = (localPos - bmin) / (bmax - bmin);
    
    // 边界检查
    if (any(uvw < 0.0f) || any(uvw > 1.0f))
        return 1000.0f;
    
    // 采样 Bindless SDF 纹理
    float sdfDist = g_SDFTextures[instance.SDFTextureIndex].SampleLevel(LinearSampler, uvw, 0);
    
    return sdfDist * instance.LocalToWorldScale;
}

//=============================================================================
// Mesh SDF 追踪
//=============================================================================

bool TraceSingleMeshSDF(
    float3 rayOrigin, 
    float3 rayDir, 
    float maxDist,
    MeshSDFInfoGPU instance,
    out float hitDist,
    out float3 hitNormal,
    out uint hitCardIndex)
{
    hitDist = maxDist;
    hitNormal = float3(0, 1, 0);
    hitCardIndex = 0xFFFFFFFF;
    
    // 变换光线到局部空间
    float3 localOrigin = mul(instance.WorldToLocal, float4(rayOrigin, 1.0f)).xyz;
    float3 localDir = normalize(mul((float3x3)instance.WorldToLocal, rayDir));
    
    float3 bmin = instance.LocalBoundsMin;
    float3 bmax = instance.LocalBoundsMax;
    
    // AABB 相交测试
    float3 invDir = 1.0f / localDir;
    float3 t0 = (bmin - localOrigin) * invDir;
    float3 t1 = (bmax - localOrigin) * invDir;
    
    float3 tMin = min(t0, t1);
    float3 tMax = max(t0, t1);
    
    float tEnter = max(max(tMin.x, tMin.y), tMin.z);
    float tExit = min(min(tMax.x, tMax.y), tMax.z);
    
    if (tEnter > tExit || tExit < 0.0f)
        return false;
    
    // Sphere tracing
    float t = max(0.0f, tEnter);
    
    [loop]
    for (uint step = 0; step < TraceMaxSteps; step++)
    {
        float3 localPos = localOrigin + localDir * t;
        float dist = SampleMeshSDF(instance, localPos);
        
        if (dist < TraceHitThreshold)
        {
            hitDist = t;
            
            // 计算法线 (中心差分)
            float eps = 0.01f;
            float3 grad = float3(
                SampleMeshSDF(instance, localPos + float3(eps, 0, 0)) - 
                SampleMeshSDF(instance, localPos - float3(eps, 0, 0)),
                SampleMeshSDF(instance, localPos + float3(0, eps, 0)) - 
                SampleMeshSDF(instance, localPos - float3(0, eps, 0)),
                SampleMeshSDF(instance, localPos + float3(0, 0, eps)) - 
                SampleMeshSDF(instance, localPos - float3(0, 0, eps))
            );
            hitNormal = normalize(mul((float3x3)instance.LocalToWorld, normalize(grad)));
            
            // 找最佳 Card
            hitCardIndex = FindBestCard(instance, hitNormal);
            
            return true;
        }
        
        t += max(dist, 0.01f);
        
        if (t > min(tExit, maxDist))
            break;
    }
    
    return false;
}

//=============================================================================
// Card 和 Surface Cache 函数
//=============================================================================

uint FindBestCard(MeshSDFInfoGPU instance, float3 worldNormal)
{
    float bestDot = -1.0f;
    uint bestCard = 0xFFFFFFFF;
    
    [loop]
    for (uint i = 0; i < instance.CardCount; i++)
    {
        uint cardIndex = instance.CardStartIndex + i;
        SurfaceCardMetadata card = CardMetadata[cardIndex];
        
        float d = dot(worldNormal, card.WorldNormal);
        if (d > bestDot)
        {
            bestDot = d;
            bestCard = cardIndex;
        }
    }
    
    return bestCard;
}

float3 SampleSurfaceCacheLighting(float3 worldPos, uint cardIndex)
{
    if (cardIndex == 0xFFFFFFFF)
        return float3(0, 0, 0);
    
    SurfaceCardMetadata card = CardMetadata[cardIndex];
    
    // 世界坐标到 Card 局部 UV
    float3 toPos = worldPos - card.WorldOrigin;
    float u = dot(toPos, card.WorldAxisX) / card.WorldSizeX + 0.5f;
    float v = dot(toPos, card.WorldAxisY) / card.WorldSizeY + 0.5f;
    
    // 边界检查
    if (u < 0.0f || u > 1.0f || v < 0.0f || v > 1.0f)
        return float3(0, 0, 0);
    
    // 计算 Atlas 中的 UV
    float atlasWidth = float(AtlasWidth);
    float atlasHeight = float(AtlasHeight);
    
    float2 atlasUV = float2(
        (float(card.AtlasOffsetX) + u * float(card.AtlasSizeX)) / atlasWidth,
        (float(card.AtlasOffsetY) + v * float(card.AtlasSizeY)) / atlasHeight
    );
    
    // 采样 Surface Cache (layer 0 = final lighting)
    return SurfaceCacheAtlas.SampleLevel(LinearSampler, float3(atlasUV, 0), 0).rgb;
}

//=============================================================================
// 主计算着色器
//=============================================================================

[numthreads(64, 1, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint globalIndex = dispatchThreadID.x;
    
    uint probeCount = ProbeGridWidth * ProbeGridHeight;
    uint probeIndex = globalIndex / RaysPerProbe;
    uint rayIndex = globalIndex % RaysPerProbe;
    
    if (probeIndex >= probeCount)
        return;
    
    ScreenProbeGPU probe = ProbeBuffer[probeIndex];
    
    // 初始化输出
    TraceResult result;
    result.HitPosition = float3(0, 0, 0);
    result.HitDistance = MeshSDFTraceDistance;  // 近距离追踪最大距离
    result.HitNormal = float3(0, 1, 0);
    result.Validity = 0.0f;
    
    if (probe.Validity <= 0.0f)
    {
        MeshTraceResults[globalIndex] = result;
        return;
    }
    
    ImportanceSampleGPU sampleData = SampleDirections[globalIndex];
    
    float3 rayOrigin = probe.WorldPosition + probe.WorldNormal * RayBias;
    float3 rayDir = sampleData.Direction;
    
    if (length(rayDir) < 0.001f)
    {
        MeshTraceResults[globalIndex] = result;
        return;
    }
    
    // 使用 Global SDF 快速剔除
    // Global SDF 存储了最近的实例索引，可以优先追踪
    float3 sdfUV = (rayOrigin - GlobalSDFCenter) * GlobalSDFInvExtent + 0.5f;
    float2 globalSDFData = float2(1000.0f, -1.0f);
    
    if (all(sdfUV >= 0.0f) && all(sdfUV <= 1.0f))
    {
        globalSDFData = GlobalSDF.SampleLevel(LinearSampler, sdfUV, 0);
    }
    
    // 遍历 Mesh 追踪
    float closestDist = MeshSDFTraceDistance;
    float3 closestHitPos = float3(0, 0, 0);
    float3 closestNormal = float3(0, 1, 0);
    uint closestCard = 0xFFFFFFFF;
    bool anyHit = false;
    
    // 如果 Global SDF 有有效的实例索引，优先追踪那个
    int priorityInstance = int(globalSDFData.y);
    
    [loop]
    for (uint meshIndex = 0; meshIndex < MAX_MESH_COUNT; meshIndex++)
    {
        MeshSDFInfoGPU instance = InstanceInfos[meshIndex];
        
        // 检查是否有效
        if (instance.SDFTextureIndex >= MAX_SDF_TEXTURES)
            continue;
        
        float hitDist;
        float3 hitNormal;
        uint hitCardIndex;
        
        if (TraceSingleMeshSDF(rayOrigin, rayDir, closestDist, instance, hitDist, hitNormal, hitCardIndex))
        {
            if (hitDist < closestDist)
            {
                closestDist = hitDist;
                closestHitPos = rayOrigin + rayDir * hitDist;
                closestNormal = hitNormal;
                closestCard = hitCardIndex;
                anyHit = true;
            }
        }
    }
    
    if (anyHit)
    {
        result.HitPosition = closestHitPos;
        result.HitDistance = closestDist;
        result.HitNormal = closestNormal;
        result.Validity = 1.0f;
        
        // 可选：直接在这里采样 Surface Cache 光照
        // float3 radiance = SampleSurfaceCacheLighting(closestHitPos, closestCard);
    }
    
    MeshTraceResults[globalIndex] = result;
}
