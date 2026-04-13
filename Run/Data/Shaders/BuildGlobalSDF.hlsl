#include "VoxelSceneCommon.hlsli"

// UAV (Root Parameter 1 - UAV Table)
RWTexture3D<float2> GlobalSDF : register(u0);  // R = 距离, G = 实例索引

// SRVs (Root Parameter 2 - SRV Table, 从t1开始)
StructuredBuffer<MeshSDFInfoGPU> InstanceInfos : register(t1, space0);

// Bindless SDF Textures (Root Parameter 4)
Texture3D<float> g_SDFTextures[MAX_SDF_TEXTURES] : register(t0, space1);

SamplerState LinearSampler : register(s0);

#define FLT_MAX 3.402823466e+38F

// 计算点到AABB的signed distanceSurfaceCardMetadata
float SDFBox(float3 p, float3 bmin, float3 bmax)
{
    float3 center = (bmin + bmax) * 0.5;
    float3 extent = (bmax - bmin) * 0.5;
    float3 d = abs(p - center) - extent;
    return length(max(d, 0.0)) + min(max(d.x, max(d.y, d.z)), 0.0);
}

[numthreads(8, 8, 8)]
void CSMain(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint3 voxelCoord = dispatchThreadID;
    
    if (any(voxelCoord >= VoxelResolution))
        return;

    //if (voxelCoord.y == 0 && voxelCoord.z == 0 && voxelCoord.x <= 6)
    //{
    //    if (all(voxelCoord == uint3(0,0,0)))
    //    {
    //        // Mesh 0 的世界中心是 (10, 0.5, 0.1)
    //        float3 testWorldPos = float3(10.0, 0.5, 0.1);
    //        MeshSDFInfoGPU sdfInfo = InstanceInfos[0];
    //        float3 localPos = mul(sdfInfo.WorldToLocal, float4(testWorldPos, 1.0)).xyz;
    //    
    //        float3 bmin = sdfInfo.LocalBoundsMin;
    //        float3 bmax = sdfInfo.LocalBoundsMax;
    //        float3 uvw = (localPos - bmin) / (bmax - bmin);
    //    
    //        bool inBounds = all(uvw >= 0.0) && all(uvw <= 1.0);
    //    
    //        GlobalSDF[uint3(0,0,0)] = float2(localPos.x, localPos.y);
    //        GlobalSDF[uint3(1,0,0)] = float2(localPos.z, inBounds ? 1.0 : 0.0);
    //        GlobalSDF[uint3(2,0,0)] = float2(uvw.x, uvw.y);
    //        GlobalSDF[uint3(3,0,0)] = float2(uvw.z, 0);
    //        GlobalSDF[uint3(4,0,0)] = float2(bmin.x, bmax.x);
    //        GlobalSDF[uint3(5,0,0)] = float2(bmin.y, bmax.y);
    //        GlobalSDF[uint3(6,0,0)] = float2(bmin.z, bmax.z);
    //    }
    //    return;  // 所有 [0-6, 0, 0] 的线程都直接返回，不覆盖调试数据
    //}

    float3 worldPos = SceneBoundsMin + (float3(voxelCoord) + 0.5) * VoxelSize;
    
    // Bounds check
    if (any(voxelCoord >= VoxelResolution))
        return;
    
    // Calculate world position of voxel center
    //float3 worldPos = SceneBoundsMin + (float3(voxelCoord) + 0.5) * VoxelSize;
    
    // Initialize to maximum distance
    float minDist = FLT_MAX;
    float minInstanceID = -1.0;
    
    // 遍历所有instances找最近的SDF
    for (uint i = 0; i < InstanceCount; ++i)
    {
        MeshSDFInfoGPU sdfInfo = InstanceInfos[i];
        
        // Transform to local space
        float3 localPos = mul( sdfInfo.WorldToLocal, float4(worldPos, 1.0)).xyz;
        //float3 localPos = mul( float4(worldPos, 1.0),  sdfInfo.WorldToLocal).xyz;
        
        // 用你的SDF生成范围 [boundsMin, boundsMax]
        float3 bmin = sdfInfo.LocalBoundsMin;
        float3 bmax = sdfInfo.LocalBoundsMax;
        
        // Conservative distance to bounding box
        float boxDist = SDFBox(localPos, bmin, bmax);
        
        // Early out if this mesh is too far
        if (boxDist > abs(minDist) + VoxelSize.x)
            continue;
        
        // 转换到UVW [0,1]，匹配你的SDF生成
        // 你的生成：worldPos = lerp(boundsMin, boundsMax, uvw)
        // 反推：uvw = (localPos - boundsMin) / (boundsMax - boundsMin)
        float3 uvw = (localPos - bmin) / (bmax - bmin);
        
        if (all(uvw >= 0.0) && all(uvw <= 1.0))
        {
            // Sample SDF texture
            float sdfDist = g_SDFTextures[sdfInfo.SDFTextureIndex].SampleLevel(LinearSampler, uvw, 0);
            
            // Transform to world space distance
            float worldDist = sdfDist * sdfInfo.LocalToWorldScale;
            
            // Update minimum
            if (abs(worldDist) < abs(minDist))
            {
                minDist = worldDist;
                minInstanceID = float(i);
            }
        }
        else if (boxDist < abs(minDist))
        {
            // Outside bounds but closer than current minimum
            // Use conservative box distance
            minDist = boxDist;
            minInstanceID = float(i);
        }
    }
    
    // Write result
    GlobalSDF[voxelCoord] = float2(minDist, minInstanceID);
}
