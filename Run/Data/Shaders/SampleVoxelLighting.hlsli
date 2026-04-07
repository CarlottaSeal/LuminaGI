// Shared helper for sampling the Voxel Lighting volume
#ifndef SAMPLE_VOXEL_LIGHTING_HLSLI
#define SAMPLE_VOXEL_LIGHTING_HLSLI

Texture3D<float4> VoxelLightingTexture : register(t_VOXEL_LIGHTING);

float3 SampleVoxelLighting(float3 worldPos, float3 direction)
{
    float3 uvw = (worldPos - SceneBoundsMin) / (SceneBoundsMax - SceneBoundsMin);
    
    if (any(uvw < 0) || any(uvw > 1))
        return float3(0, 0, 0);
    
    // Sample 3 faces weighted by direction
    float3 absDir = abs(direction);
    float3 weights = absDir / (absDir.x + absDir.y + absDir.z + 0.001);
    
    float3 result = float3(0, 0, 0);
    
    // X direction
    {
        uint dirIndex = (direction.x > 0) ? 0 : 1;
        float3 sampleUVW = float3(uvw.xy, (uvw.z + dirIndex) / 6.0);
        result += VoxelLightingTexture.SampleLevel(LinearSampler, sampleUVW, 0).rgb * weights.x;
    }
    
    // Y direction
    {
        uint dirIndex = (direction.y > 0) ? 2 : 3;
        float3 sampleUVW = float3(uvw.xy, (uvw.z + dirIndex) / 6.0);
        result += VoxelLightingTexture.SampleLevel(LinearSampler, sampleUVW, 0).rgb * weights.y;
    }
    
    // Z direction
    {
        uint dirIndex = (direction.z > 0) ? 4 : 5;
        float3 sampleUVW = float3(uvw.xy, (uvw.z + dirIndex) / 6.0);
        result += VoxelLightingTexture.SampleLevel(LinearSampler, sampleUVW, 0).rgb * weights.z;
    }
    
    return result;
}

#endif 