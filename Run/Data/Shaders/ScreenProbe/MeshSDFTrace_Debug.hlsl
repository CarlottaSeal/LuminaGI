//=============================================================================
// MeshSDFTrace_Clean.hlsl
// 简化版本，无调试代码
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

#define MAX_SDF_TEXTURES 64
#define MAX_MESH_COUNT 64  // 减少循环次数，14个物体足够

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
    uint   AtlasOffsetX;       // 16 bytes
    uint   AtlasOffsetY;
    uint   AtlasSizeX;
    uint   AtlasSizeY;

    float3 WorldOrigin;        
    float  Padding0;

    float3 WorldAxisX;         
    float  Padding1;

    float3 WorldAxisY;         
    float  Padding2;

    float3 WorldNormal;        
    float  Padding3;

    float  WorldSizeX;         
    float  WorldSizeY;
    uint   CardDirection;
    uint   GlobalCardID;

    uint4  LightMask;         
};      

// 输入
StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV);
StructuredBuffer<ImportanceSampleGPU> SampleDirections : register(REG_SAMPLE_DIR_SRV);
StructuredBuffer<MeshSDFInfoGPU> InstanceInfos : register(REG_INSTANCE_INFO_SRV);
Texture3D<float> g_SDFTextures[MAX_SDF_TEXTURES] : register(t0, space1);
StructuredBuffer<SurfaceCardMetadata> CardMetadata : register(REG_CARD_METADATA_SRV);

// 输出
RWStructuredBuffer<TraceResult> MeshTraceResults : register(REG_MESH_TRACE_UAV);

SamplerState LinearSampler : register(s1);

float SampleMeshSDF(MeshSDFInfoGPU instance, float3 localPos)
{
    float3 bmin = instance.LocalBoundsMin;
    float3 bmax = instance.LocalBoundsMax;
    float3 size = bmax - bmin;
    
    // 防止除零
    if (any(size < 0.001f))
        return 1000.0f;
    
    float3 uvw = (localPos - bmin) / size;
    
    if (any(uvw < 0.0f) || any(uvw > 1.0f))
        return 1000.0f;
    
    float sdfDist = g_SDFTextures[instance.SDFTextureIndex].SampleLevel(LinearSampler, uvw, 0);
    return sdfDist * instance.LocalToWorldScale;
}

uint FindBestCard(MeshSDFInfoGPU instance, float3 worldNormal)
{
    float bestDot = 1.0f;  // 找最小值（最负的dot）
    uint bestCard = 0xFFFFFFFF;

    for (uint i = 0; i < instance.CardCount && i < 6; i++)
    {
        uint cardIndex = instance.CardStartIndex + i;
        SurfaceCardMetadata card = CardMetadata[cardIndex];

        // WorldNormal现在是inward-facing（指向模型内部）
        // worldNormal是hit表面的法线（outward）
        // 对于匹配的card，两者应该是相反的，所以dot为负
        float d = dot(worldNormal, card.WorldNormal);
        if (d < bestDot)
        {
            bestDot = d;
            bestCard = cardIndex;
        }
    }

    return bestCard;
}

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
    hitNormal = float3(0, 0, 1);
    hitCardIndex = 0xFFFFFFFF;
    
    // 变换到局部空间
    float3 localOrigin = mul(instance.WorldToLocal, float4(rayOrigin, 1.0f)).xyz;
    float3 localDir = normalize(mul((float3x3)instance.WorldToLocal, rayDir));
    
    float3 bmin = instance.LocalBoundsMin;
    float3 bmax = instance.LocalBoundsMax;
    
    // AABB 相交测试
    float3 invDir = 1.0f / (localDir + 0.0001f);  // 防止除零
    float3 t0 = (bmin - localOrigin) * invDir;
    float3 t1 = (bmax - localOrigin) * invDir;
    
    float3 tMin = min(t0, t1);
    float3 tMax = max(t0, t1);
    
    float tEnter = max(max(tMin.x, tMin.y), tMin.z);
    float tExit = min(min(tMax.x, tMax.y), tMax.z);
    
    if (tEnter > tExit || tExit < 0.0f)
        return false;
    
    // Sphere tracing - 从 AABB 入口开始，但至少跳过一小段距离
    float t = max(0.1f, tEnter);  // 最小 0.1 防止自相交
    
    for (uint step = 0; step < 64; step++)  // 减少步数
    {
        if (t > min(tExit, maxDist))
            break;
            
        float3 localPos = localOrigin + localDir * t;
        float dist = SampleMeshSDF(instance, localPos);
        
        if (dist < 0.02f)  // 硬编码阈值
        {
            hitDist = t;
            
            // 计算法线
            float eps = 0.01f;
            float3 grad = float3(
                SampleMeshSDF(instance, localPos + float3(eps, 0, 0)) - 
                SampleMeshSDF(instance, localPos - float3(eps, 0, 0)),
                SampleMeshSDF(instance, localPos + float3(0, eps, 0)) - 
                SampleMeshSDF(instance, localPos - float3(0, eps, 0)),
                SampleMeshSDF(instance, localPos + float3(0, 0, eps)) - 
                SampleMeshSDF(instance, localPos - float3(0, 0, eps))
            );
            
            float gradLen = length(grad);
            if (gradLen > 0.001f)
            {
                hitNormal = normalize(mul((float3x3)instance.LocalToWorld, grad / gradLen));
            }
            
            hitCardIndex = FindBestCard(instance, hitNormal);
            return true;
        }
        
        t += max(dist, 0.02f);  // 最小步进
    }
    
    return false;
}

[numthreads(64, 1, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint globalIndex = dispatchThreadID.x;
    
    uint probeCount = ProbeGridWidth * ProbeGridHeight;
    uint probeIndex = globalIndex / RaysPerProbe;
    uint rayIndex = globalIndex % RaysPerProbe;
    
    // 初始化输出 - 明确设置每个字段
    TraceResult result;
    result.HitPosition = float3(0, 0, 0);
    result.HitDistance = 100.0f;  // 硬编码默认值
    result.HitNormal = float3(0, 0, 1);
    result.Validity = 0.0f;
    result.HitCardIndex = 0xFFFFFFFF;
    result.Padding0 = 0;
    result.Padding1 = 0;
    result.Padding2 = 0;
    
    if (probeIndex >= probeCount)
    {
        MeshTraceResults[globalIndex] = result;
        return;
    }
    
    ScreenProbeGPU probe = ProbeBuffer[probeIndex];
    
    if (probe.Validity <= 0.0f)
    {
        MeshTraceResults[globalIndex] = result;
        return;
    }
    
    ImportanceSampleGPU sampleData = SampleDirections[globalIndex];
    float3 rayDir = sampleData.Direction;
    
    if (length(rayDir) < 0.001f)
    {
        MeshTraceResults[globalIndex] = result;
        return;
    }
    
    rayDir = normalize(rayDir);
    float3 rayOrigin = probe.WorldPosition + probe.WorldNormal * 0.5f;  // 硬编码 bias
    
    // 遍历所有 mesh
    float closestDist = 100.0f;
    float3 closestHitPos = float3(0, 0, 0);
    float3 closestNormal = float3(0, 0, 1);
    uint closestCard = 0xFFFFFFFF;
    bool anyHit = false;
    
    for (uint meshIndex = 0; meshIndex < MAX_MESH_COUNT; meshIndex++)
    {
        MeshSDFInfoGPU instance = InstanceInfos[meshIndex];
        
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
        result.HitCardIndex = closestCard;
    }
    
    MeshTraceResults[globalIndex] = result;
}
