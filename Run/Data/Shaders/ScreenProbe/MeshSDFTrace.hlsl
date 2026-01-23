//=============================================================================
// MeshSDFTrace.hlsl
// Pass 6.5: Mesh SDF Trace
// 追踪 Mesh SDF (近距离)，命中后采样 Surface Cache Final Lighting
// [FIXED VERSION] - 添加最小步进距离防止自相交
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

#define MAX_SDF_TEXTURES 64
#define MAX_MESH_COUNT 256

// ===== 修复参数 =====
#define MIN_TRACE_START_DISTANCE 0.5f  // 最小起始距离，跳过自相交
#define DEBUG_MESH_TRACE 0              // 调试开关

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
// Mesh SDF 追踪 [FIXED]
//=============================================================================

bool TraceSingleMeshSDF(
    float3 rayOrigin, 
    float3 rayDir, 
    float maxDist,
    float minStartDist,    // ===== 新增：最小起始距离 =====
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
    
    // ===== 修复：确保起始距离不小于 minStartDist =====
    // 这样可以跳过自相交（ray 起点就在表面上的情况）
    float t = max(minStartDist, max(0.0f, tEnter));
    
    // 如果 minStartDist 已经超过了 AABB，跳过
    if (t > tExit || t > maxDist)
        return false;
    
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
    float bestDot = 1.0f;  // 找最小值（最负的dot）
    uint bestCard = 0xFFFFFFFF;

    [loop]
    for (uint i = 0; i < instance.CardCount; i++)
    {
        uint cardIndex = instance.CardStartIndex + i;
        SurfaceCardMetadata card = CardMetadata[cardIndex];

        // card.Normal现在是inward-facing（指向模型内部）
        // worldNormal是hit表面的法线（outward）
        // 对于匹配的card，两者应该是相反的，所以dot为负
        // 找最负的dot值（即最佳匹配）
        float d = dot(worldNormal, card.Normal);
        if (d < bestDot)
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

    // 采样 Surface Cache (layer 5 = Combined Light = Direct + Indirect)
    return SurfaceCacheAtlas.SampleLevel(LinearSampler, float3(atlasUV, 5), 0).rgb;
}

//=============================================================================
// 主计算着色器 [FIXED]
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
    TraceResult result = (TraceResult)0;  
    result.HitDistance = MeshSDFTraceDistance; 
    result.HitNormal = float3(0, 1, 0);        
    result.HitCardIndex = 0xFFFFFFFF;  
   
    if (probe.Validity <= 0.0f)
    {
        MeshTraceResults[globalIndex] = result;
        return;
    }
    
    ImportanceSampleGPU sampleData = SampleDirections[globalIndex];
    
    // ===== 修复：增大 RayBias =====
    float effectiveBias = max(RayBias, 1.0f);  // 确保至少 1.0
    float3 rayOrigin = probe.WorldPosition + probe.WorldNormal * effectiveBias;
    float3 rayDir = sampleData.Direction;
    
    if (length(rayDir) < 0.001f)
    {
        MeshTraceResults[globalIndex] = result;
        return;
    }
    
    rayDir = normalize(rayDir);
    
    // ===== DEBUG: 输出 ray 信息 =====
#if DEBUG_MESH_TRACE
    if (globalIndex == 643587)
    {
        result.HitPosition = rayOrigin;
        result.HitNormal = rayDir;
        result.HitDistance = effectiveBias;
        result.Validity = 999.0f;  // 标记为调试
        MeshTraceResults[globalIndex] = result;
        return;
    }
#endif
    
    // 使用 Global SDF 快速剔除
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
    
    // ===== 修复：最小起始距离，防止自相交 =====
    float minStartDistance = MIN_TRACE_START_DISTANCE;
    
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
        
        // ===== 传入 minStartDistance =====
        if (TraceSingleMeshSDF(rayOrigin, rayDir, closestDist, minStartDistance, 
                               instance, hitDist, hitNormal, hitCardIndex))
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
        result.HitCardIndex = closestCard;  
    }
    
    MeshTraceResults[globalIndex] = result;
}
