#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

#define MAX_SDF_TEXTURES 64
#define MAX_MESH_COUNT 256
#define MIN_TRACE_START_DISTANCE 0.5f
#define DEBUG_MESH_TRACE 0

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
    uint AtlasX;
    uint AtlasY;
    uint ResolutionX;
    uint ResolutionY;

    float3 Origin;
    float Padding0;

    float3 AxisX;
    float Padding1;

    float3 AxisY;
    float Padding2;

    float3 Normal;
    float Padding3;

    float WorldSizeX;
    float WorldSizeY;
    uint Direction;
    uint GlobalCardID;

    uint4 LightMask;
};

StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV);
StructuredBuffer<ImportanceSampleGPU> SampleDirections : register(REG_SAMPLE_DIR_SRV);

Texture2D<float>  GBufferDepth  : register(REG_DEPTH_BUFFER);
Texture2D<float4> GBufferNormal : register(REG_GBUFFER_NORMAL);

StructuredBuffer<MeshSDFInfoGPU> InstanceInfos : register(REG_INSTANCE_INFO_SRV);
Texture3D<float> g_SDFTextures[MAX_SDF_TEXTURES] : register(t0, space1);

Texture2DArray<float4> SurfaceCacheAtlas : register(REG_SURFACE_ATLAS_SRV);
StructuredBuffer<SurfaceCardMetadata> CardMetadata : register(REG_CARD_METADATA_SRV);

Texture3D<float2> GlobalSDF : register(REG_GLOBAL_SDF_SRV);

Buffer<uint> VoxelVisibilityBuffer : register(REG_VOXEL_VISIBILITY_SRV);

RWStructuredBuffer<TraceResult> MeshTraceResults : register(REG_MESH_TRACE_UAV);

SamplerState LinearSampler : register(s1);
SamplerState PointSampler  : register(s0);

// Voxel Visibility Helpers
uint GetVisibilityDirectionIndex(float3 direction)
{
    float3 absDir = abs(direction);
    if (absDir.x >= absDir.y && absDir.x >= absDir.z)
        return (direction.x > 0) ? 0 : 1;
    else if (absDir.y >= absDir.x && absDir.y >= absDir.z)
        return (direction.y > 0) ? 2 : 3;
    else
        return (direction.z > 0) ? 4 : 5;
}

float DecodeVisibilityHitDistance(uint visibility, uint dirIndex, float maxTraceDist)
{
    uint quantized = (visibility >> (dirIndex * 5)) & 0x1F;
    return (float(quantized) / 31.0) * maxTraceDist;
}

bool QueryVoxelVisibility(float3 worldPos, float3 rayDir,
                          out int hintMeshIndex, out float hintDistance)
{
    hintMeshIndex = -1;
    hintDistance = 0.0f;

    float3 localPos = (worldPos - VoxelGridMin) / (VoxelGridMax - VoxelGridMin);

    if (any(localPos < 0.0f) || any(localPos > 1.0f))
        return false;

    uint3 voxelCoord = uint3(localPos * float(VoxelResolution));
    voxelCoord = min(voxelCoord, uint3(VoxelResolution - 1, VoxelResolution - 1, VoxelResolution - 1));

    uint flatIndex = voxelCoord.x + voxelCoord.y * VoxelResolution +
                     voxelCoord.z * VoxelResolution * VoxelResolution;

    uint containingMesh = VoxelVisibilityBuffer[flatIndex * 3 + 0];
    uint visibilityData = VoxelVisibilityBuffer[flatIndex * 3 + 1];

    if (containingMesh == 0xFFFFFFFF || containingMesh == 0xFFFFFFFE)
        return false;

    hintMeshIndex = int(containingMesh);

    uint dirIndex = GetVisibilityDirectionIndex(rayDir);
    float maxTraceDist = VoxelSize * 10.0f;
    hintDistance = DecodeVisibilityHitDistance(visibilityData, dirIndex, maxTraceDist);

    return true;
}

// SDF Sampling and Tracing
float SampleMeshSDF(MeshSDFInfoGPU instance, float3 localPos)
{
    float3 bmin = instance.LocalBoundsMin;
    float3 bmax = instance.LocalBoundsMax;
    float3 uvw = (localPos - bmin) / (bmax - bmin);

    if (any(uvw < 0.0f) || any(uvw > 1.0f))
        return 1000.0f;

    float sdfDist = g_SDFTextures[instance.SDFTextureIndex].SampleLevel(LinearSampler, uvw, 0);

    return sdfDist * instance.LocalToWorldScale;
}

bool TraceSingleMeshSDF(
    float3 rayOrigin,
    float3 rayDir,
    float maxDist,
    float minStartDist,
    MeshSDFInfoGPU instance,
    out float hitDist,
    out float3 hitNormal,
    out uint hitCardIndex)
{
    hitDist = maxDist;
    hitNormal = float3(0, 1, 0);
    hitCardIndex = 0xFFFFFFFF;

    float3 localOrigin = mul(instance.WorldToLocal, float4(rayOrigin, 1.0f)).xyz;
    float3 localDir = normalize(mul((float3x3)instance.WorldToLocal, rayDir));

    float3 bmin = instance.LocalBoundsMin;
    float3 bmax = instance.LocalBoundsMax;

    float3 invDir = 1.0f / localDir;
    float3 t0 = (bmin - localOrigin) * invDir;
    float3 t1 = (bmax - localOrigin) * invDir;

    float3 tMin = min(t0, t1);
    float3 tMax = max(t0, t1);

    float tEnter = max(max(tMin.x, tMin.y), tMin.z);
    float tExit = min(min(tMax.x, tMax.y), tMax.z);

    if (tEnter > tExit || tExit < 0.0f)
        return false;

    float t = max(minStartDist, max(0.0f, tEnter));

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

            hitCardIndex = FindBestCard(instance, hitNormal);

            return true;
        }

        t += max(dist, 0.01f);

        if (t > min(tExit, maxDist))
            break;
    }

    return false;
}

uint FindBestCard(MeshSDFInfoGPU instance, float3 worldNormal)
{
    float bestDot = 1.0f;
    uint bestCard = 0xFFFFFFFF;

    [loop]
    for (uint i = 0; i < instance.CardCount; i++)
    {
        uint cardIndex = instance.CardStartIndex + i;
        SurfaceCardMetadata card = CardMetadata[cardIndex];

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

    float3 toPos = worldPos - card.Origin;
    float u = dot(toPos, card.AxisX) / card.WorldSizeX + 0.5f;
    float v = dot(toPos, card.AxisY) / card.WorldSizeY + 0.5f;

    if (u < 0.0f || u > 1.0f || v < 0.0f || v > 1.0f)
        return float3(0, 0, 0);

    float atlasWidth = float(AtlasWidth);
    float atlasHeight = float(AtlasHeight);

    float2 atlasUV = float2(
        (float(card.AtlasX) + u * float(card.ResolutionX)) / atlasWidth,
        (float(card.AtlasY) + v * float(card.ResolutionY)) / atlasHeight
    );

    return SurfaceCacheAtlas.SampleLevel(LinearSampler, float3(atlasUV, 5), 0).rgb;
}

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

    TraceResult result = (TraceResult)0;
    result.HitDistance = MeshSDFTraceDistance;
    result.HitNormal = float3(0, 1, 0);
    result.HitCardIndex = 0xFFFFFFFF;

    uint2 probeCoord = uint2(probeIndex % ProbeGridWidth, probeIndex / ProbeGridWidth);
    uint2 localRayCoord = uint2(rayIndex % 8, rayIndex / 8);
    uint2 screenCoord = probeCoord * ProbeSpacing + localRayCoord;

    screenCoord = min(screenCoord, uint2(ScreenWidth - 1, ScreenHeight - 1));

    float pixelDepth = GBufferDepth[screenCoord];

    if (pixelDepth <= 0.0f || pixelDepth >= 0.9999f)
    {
        MeshTraceResults[globalIndex] = result;
        return;
    }

    float2 screenUV = (float2(screenCoord) + 0.5f) / float2(ScreenWidth, ScreenHeight);
    float3 rayWorldPos = ScreenUVToWorld(screenUV, pixelDepth);

    float3 pixelNormal = GBufferNormal[screenCoord].xyz * 2.0f - 1.0f;
    pixelNormal = SafeNormalize(pixelNormal);

    ImportanceSampleGPU sampleData = SampleDirections[globalIndex];

    float effectiveBias = max(RayBias, 1.0f);
    float3 rayOrigin = rayWorldPos + pixelNormal * effectiveBias;
    float3 rayDir = sampleData.Direction;

    if (length(rayDir) < 0.001f)
    {
        MeshTraceResults[globalIndex] = result;
        return;
    }

    rayDir = normalize(rayDir);

#if DEBUG_MESH_TRACE
    if (globalIndex == 643587)
    {
        result.HitPosition = rayOrigin;
        result.HitNormal = rayDir;
        result.HitDistance = effectiveBias;
        result.Validity = 999.0f;
        MeshTraceResults[globalIndex] = result;
        return;
    }
#endif

    int hintMeshIndex = -1;
    float hintDistance = 0.0f;
    bool hasVisibilityHint = QueryVoxelVisibility(rayOrigin, rayDir, hintMeshIndex, hintDistance);

    float closestDist = MeshSDFTraceDistance;
    float3 closestHitPos = float3(0, 0, 0);
    float3 closestNormal = float3(0, 1, 0);
    uint closestCard = 0xFFFFFFFF;
    bool anyHit = false;

    float minStartDistance = MIN_TRACE_START_DISTANCE;

    if (hasVisibilityHint && hintMeshIndex >= 0 && uint(hintMeshIndex) < MeshInstanceCount)
    {
        MeshSDFInfoGPU instance = InstanceInfos[hintMeshIndex];

        if (instance.SDFTextureIndex < MAX_SDF_TEXTURES)
        {
            float hitDist;
            float3 hitNormal;
            uint hitCardIndex;

            if (TraceSingleMeshSDF(rayOrigin, rayDir, closestDist, minStartDistance,
                                   instance, hitDist, hitNormal, hitCardIndex))
            {
                closestDist = hitDist;
                closestHitPos = rayOrigin + rayDir * hitDist;
                closestNormal = hitNormal;
                closestCard = hitCardIndex;
                anyHit = true;
            }
        }
    }

    [loop]
    for (uint meshIndex = 0; meshIndex < MeshInstanceCount; meshIndex++)
    {
        if (hasVisibilityHint && int(meshIndex) == hintMeshIndex)
            continue;

        MeshSDFInfoGPU instance = InstanceInfos[meshIndex];

        if (instance.SDFTextureIndex >= MAX_SDF_TEXTURES)
            continue;

        float hitDist;
        float3 hitNormal;
        uint hitCardIndex;

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
