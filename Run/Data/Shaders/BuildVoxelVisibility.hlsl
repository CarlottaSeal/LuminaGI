#include "VoxelSceneCommon.hlsli"

RWBuffer<uint> VoxelVisibility : register(u0);

// SRVs (Root Parameter 2 - SRV Table, 从t1开始)
StructuredBuffer<MeshSDFInfoGPU> InstanceInfos : register(t1, space0);

// GlobalSDF SRV (Root Parameter 3)
Texture3D<float2> GlobalSDF : register(t0, space0);

// Bindless SDF Textures (Root Parameter 4)
Texture3D<float> g_SDFTextures[MAX_SDF_TEXTURES] : register(t0, space1);

SamplerState LinearSampler : register(s0);

#define FLT_MAX 3.402823466e+38F

// Pack mesh index (16bit) and distance (16bit)
uint PackVisibility(uint meshIndex, float distance, float voxelSize)
{
    meshIndex = min(meshIndex, 0xFFFFu);
    uint quantizedDist = min(uint(distance / voxelSize * 64.0), 0xFFFFu);
    return (meshIndex << 16) | quantizedDist;
}

// SDF sphere trace along direction
bool TraceMeshSDF(float3 startPos, float3 direction, uint meshIndex, 
                  out float hitDistance, float maxDistance, float voxelSize)
{
    MeshSDFInfoGPU sdfInfo = InstanceInfos[meshIndex];
    
    float t = 0.0;
    const int MAX_STEPS = 64;
    const float MIN_DIST = voxelSize * 0.5;
    
    for (int step = 0; step < MAX_STEPS; ++step)
    {
        float3 worldPos = startPos + direction * t;
        float3 localPos = mul(sdfInfo.WorldToLocal, float4(worldPos, 1.0)).xyz;
        
        // 正确：用SDF范围
        float3 bmin = sdfInfo.LocalBoundsMin;
        float3 bmax = sdfInfo.LocalBoundsMax;
        
        // Check bounds
        if (any(localPos < bmin - voxelSize) || any(localPos > bmax + voxelSize))
        {
            t += voxelSize;
            if (t > maxDistance)
                return false;
            continue;
        }
        
        // 转换到UVW
        float3 uvw = (localPos - bmin) / (bmax - bmin);
        
        if (all(uvw >= 0.0) && all(uvw <= 1.0))
        {
            float sdfDist = g_SDFTextures[sdfInfo.SDFTextureIndex].SampleLevel(LinearSampler, uvw, 0);
            float worldDist = sdfDist * sdfInfo.LocalToWorldScale;
            
            if (worldDist < MIN_DIST)
            {
                hitDistance = t;
                return true;
            }
            
            t += max(worldDist, voxelSize * 0.1);
        }
        else
        {
            t += voxelSize;
        }
        
        if (t > maxDistance)
            return false;
    }
    
    return false;
}

[numthreads(8, 8, 8)]
void CSMain(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint3 voxelCoord = dispatchThreadID;
    
    if (any(voxelCoord >= VoxelResolution))
        return;
    
    uint flatIndex = voxelCoord.x + voxelCoord.y * VoxelResolution + voxelCoord.z * VoxelResolution * VoxelResolution;
    
    float2 sdfValue = GlobalSDF[voxelCoord];
    float sdfDist = sdfValue.x;
    
    if (abs(sdfDist) > VoxelSize.x * 3.0)
    {
        VoxelVisibility[flatIndex * 3 + 0] = 0xFFFFFFFF;
        VoxelVisibility[flatIndex * 3 + 1] = 0xFFFFFFFF;
        VoxelVisibility[flatIndex * 3 + 2] = 0xFFFFFFFF;
        return;
    }
    
    float3 worldPos = SceneBoundsMin + (float3(voxelCoord) + 0.5) * VoxelSize;
    
    // 找到包含这个点的 mesh
    int containingMesh = -1;
    for (uint i = 0; i < InstanceCount; ++i)
    {
        MeshSDFInfoGPU sdfInfo = InstanceInfos[i];
        float3 localPos = mul(sdfInfo.WorldToLocal, float4(worldPos, 1.0)).xyz;
        float3 bmin = sdfInfo.LocalBoundsMin;
        float3 bmax = sdfInfo.LocalBoundsMax;
        float3 uvw = (localPos - bmin) / (bmax - bmin);
        
        if (all(uvw >= 0.0) && all(uvw <= 1.0))
        {
            containingMesh = i;
            break;
        }
    }
    
    if (containingMesh < 0)
    {
        VoxelVisibility[flatIndex * 3 + 0] = 0xFFFFFFFE;
        VoxelVisibility[flatIndex * 3 + 1] = 0xFFFFFFFE;
        VoxelVisibility[flatIndex * 3 + 2] = 0xFFFFFFFE;
        return;
    }
    
    // 6 方向 ray trace
    const float3 directions[6] = {
        float3(1, 0, 0), float3(-1, 0, 0),
        float3(0, 1, 0), float3(0, -1, 0),
        float3(0, 0, 1), float3(0, 0, -1)
    };
    
    uint visibility = 0;
    float maxTraceDist = VoxelSize.x * 10.0;
    
    for (uint d = 0; d < 6; ++d)
    {
        float hitDist;
        // 对所有 mesh 做 ray trace
        for (uint m = 0; m < InstanceCount; ++m)
        {
            if (TraceMeshSDF(worldPos, directions[d], m, hitDist, maxTraceDist, VoxelSize.x))
            {
                // Pack: 每个方向用 5 bits 存储距离信息
                uint quantized = min(uint(hitDist / maxTraceDist * 31.0), 31u);
                visibility |= (quantized << (d * 5));
                break;
            }
        }
    }
    
    VoxelVisibility[flatIndex * 3 + 0] = uint(containingMesh);
    VoxelVisibility[flatIndex * 3 + 1] = visibility;
    VoxelVisibility[flatIndex * 3 + 2] = asuint(sdfDist);
}
