//=============================================================================
// MeshSDFTrace.hlsl
// Per-mesh SDF sphere tracing with per-ray world position
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

#define MAX_SDF_TEXTURES 64
#define MAX_MESH_COUNT 64

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
    uint   AtlasOffsetX;
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

StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV);
StructuredBuffer<ImportanceSampleGPU> SampleDirections : register(REG_SAMPLE_DIR_SRV);
StructuredBuffer<MeshSDFInfoGPU> InstanceInfos : register(REG_INSTANCE_INFO_SRV);
Texture3D<float> g_SDFTextures[MAX_SDF_TEXTURES] : register(t0, space1);
StructuredBuffer<SurfaceCardMetadata> CardMetadata : register(REG_CARD_METADATA_SRV);

Texture2D<float>  GBufferDepth  : register(REG_DEPTH_BUFFER);
Texture2D<float4> GBufferNormal : register(REG_GBUFFER_NORMAL);

Buffer<uint> VoxelVisibilityBuffer : register(REG_VOXEL_VISIBILITY_SRV);

RWStructuredBuffer<TraceResult> MeshTraceResults : register(REG_MESH_TRACE_UAV);

SamplerState LinearSampler : register(s1);

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

bool QueryVoxelVisibility(float3 worldPos, float3 rayDir, out int hintMeshIndex, out float hintDistance)
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

float SampleMeshSDF(MeshSDFInfoGPU instance, float3 localPos)
{
    float3 bmin = instance.LocalBoundsMin;
    float3 bmax = instance.LocalBoundsMax;
    float3 size = bmax - bmin;

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
    float bestDot = 1.0f;
    uint bestCard = 0xFFFFFFFF;

    for (uint i = 0; i < instance.CardCount && i < 6; i++)
    {
        uint cardIndex = instance.CardStartIndex + i;
        SurfaceCardMetadata card = CardMetadata[cardIndex];

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

    float3 localOrigin = mul(instance.WorldToLocal, float4(rayOrigin, 1.0f)).xyz;
    float3 localDir = normalize(mul((float3x3)instance.WorldToLocal, rayDir));

    float3 bmin = instance.LocalBoundsMin;
    float3 bmax = instance.LocalBoundsMax;

    float3 invDir = 1.0f / (localDir + 0.0001f);
    float3 t0 = (bmin - localOrigin) * invDir;
    float3 t1 = (bmax - localOrigin) * invDir;

    float3 tMin = min(t0, t1);
    float3 tMax = max(t0, t1);

    float tEnter = max(max(tMin.x, tMin.y), tMin.z);
    float tExit = min(min(tMax.x, tMax.y), tMax.z);

    if (tEnter > tExit || tExit < 0.0f)
        return false;

    float t = max(0.1f, tEnter);

    for (uint step = 0; step < 64; step++)
    {
        if (t > min(tExit, maxDist))
            break;

        float3 localPos = localOrigin + localDir * t;
        float dist = SampleMeshSDF(instance, localPos);

        if (dist < 0.02f)
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

            float gradLen = length(grad);
            if (gradLen > 0.001f)
            {
                hitNormal = normalize(mul((float3x3)instance.LocalToWorld, grad / gradLen));
            }

            hitCardIndex = FindBestCard(instance, hitNormal);
            return true;
        }

        t += max(dist, 0.02f);
    }

    return false;
}

[numthreads(8, 8, 1)]
void main(uint3 groupID : SV_GroupID, uint3 groupThreadID : SV_GroupThreadID)
{
    uint2 probeCoord = groupID.xy;
    uint probeIndex = probeCoord.y * ProbeGridWidth + probeCoord.x;

    uint rayIndex = groupThreadID.y * 8 + groupThreadID.x;
    uint globalIndex = probeIndex * RaysPerProbe + rayIndex;

    TraceResult result;
    result.HitPosition = float3(0, 0, 0);
    result.HitDistance = 100.0f;
    result.HitNormal = float3(0, 0, 1);
    result.Validity = 0.0f;
    result.HitCardIndex = 0xFFFFFFFF;
    result.Padding0 = 0;
    result.Padding1 = 0;
    result.Padding2 = 0;

    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
    {
        MeshTraceResults[globalIndex] = result;
        return;
    }

    uint2 localRayCoord = uint2(rayIndex % OctahedronWidth, rayIndex / OctahedronWidth);
    uint2 screenOffset = uint2(localRayCoord.x, localRayCoord.y % ProbeSpacing);
    uint2 screenCoord = probeCoord * ProbeSpacing + screenOffset;
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
    float3 rayDir = sampleData.Direction;

    if (length(rayDir) < 0.001f)
    {
        MeshTraceResults[globalIndex] = result;
        return;
    }

    rayDir = normalize(rayDir);
    float3 rayOrigin = rayWorldPos + pixelNormal * 0.5f;

    int hintMeshIndex = -1;
    float hintDistance = 0.0f;
    bool hasVisibilityHint = QueryVoxelVisibility(rayOrigin, rayDir, hintMeshIndex, hintDistance);

    float closestDist = 100.0f;
    float3 closestHitPos = float3(0, 0, 0);
    float3 closestNormal = float3(0, 0, 1);
    uint closestCard = 0xFFFFFFFF;
    bool anyHit = false;

    if (hasVisibilityHint && hintMeshIndex >= 0 && uint(hintMeshIndex) < MeshInstanceCount)
    {
        MeshSDFInfoGPU instance = InstanceInfos[hintMeshIndex];
        if (instance.SDFTextureIndex < MAX_SDF_TEXTURES)
        {
            float hitDist;
            float3 hitNormal;
            uint hitCardIndex;
            if (TraceSingleMeshSDF(rayOrigin, rayDir, closestDist, instance, hitDist, hitNormal, hitCardIndex))
            {
                closestDist = hitDist;
                closestHitPos = rayOrigin + rayDir * hitDist;
                closestNormal = hitNormal;
                closestCard = hitCardIndex;
                anyHit = true;
            }
        }
    }

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
