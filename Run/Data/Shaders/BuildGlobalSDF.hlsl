#include "VoxelSceneCommon.hlsli"

RWTexture3D<float2> GlobalSDF : register(u0);  // R = distance, G = instance index
StructuredBuffer<MeshSDFInfoGPU> InstanceInfos : register(t1, space0);
Texture3D<float> g_SDFTextures[MAX_SDF_TEXTURES] : register(t0, space1);

SamplerState LinearSampler : register(s0);

#define FLT_MAX 3.402823466e+38F

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

    float3 worldPos = SceneBoundsMin + (float3(voxelCoord) + 0.5) * VoxelSize;
    
    if (any(voxelCoord >= VoxelResolution))
        return;

    //float3 worldPos = SceneBoundsMin + (float3(voxelCoord) + 0.5) * VoxelSize;

    float minDist = FLT_MAX;
    float minInstanceID = -1.0;
    
    for (uint i = 0; i < InstanceCount; ++i)
    {
        MeshSDFInfoGPU sdfInfo = InstanceInfos[i];
        
        float3 localPos = mul( sdfInfo.WorldToLocal, float4(worldPos, 1.0)).xyz;
        //float3 localPos = mul( float4(worldPos, 1.0),  sdfInfo.WorldToLocal).xyz;
        
        float3 bmin = sdfInfo.LocalBoundsMin;
        float3 bmax = sdfInfo.LocalBoundsMax;
        
        float boxDist = SDFBox(localPos, bmin, bmax);

        if (boxDist > abs(minDist) + VoxelSize.x)
            continue;
        
        float3 uvw = (localPos - bmin) / (bmax - bmin);
        
        if (all(uvw >= 0.0) && all(uvw <= 1.0))
        {
            float sdfDist = g_SDFTextures[sdfInfo.SDFTextureIndex].SampleLevel(LinearSampler, uvw, 0);
            float worldDist = sdfDist * sdfInfo.LocalToWorldScale;

            if (abs(worldDist) < abs(minDist))
            {
                minDist = worldDist;
                minInstanceID = float(i);
            }
        }
        else if (boxDist < abs(minDist))
        {
            minDist = boxDist;
            minInstanceID = float(i);
        }
    }
    
    GlobalSDF[voxelCoord] = float2(minDist, minInstanceID);
}
