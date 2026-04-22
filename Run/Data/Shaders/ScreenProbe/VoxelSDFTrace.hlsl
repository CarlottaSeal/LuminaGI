#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV);
StructuredBuffer<ImportanceSampleGPU> SampleDirections : register(REG_SAMPLE_DIR_SRV);

Texture2D<float>  GBufferDepth  : register(REG_DEPTH_BUFFER);
Texture2D<float4> GBufferNormal : register(REG_GBUFFER_NORMAL);

Texture3D<float2> GlobalSDF     : register(REG_GLOBAL_SDF_SRV);     // R=distance, G=instance index
Texture3D<float4> VoxelLighting : register(REG_VOXEL_LIGHTING_SRV);

RWStructuredBuffer<TraceResult> VoxelTraceResults : register(REG_VOXEL_TRACE_UAV); // u413

SamplerState LinearSampler : register(s1);

float3 WorldToSDFUV(float3 worldPos)
{
    return (worldPos - GlobalSDFCenter) * GlobalSDFInvExtent + 0.5f;
}

float SampleGlobalSDF(float3 worldPos)
{
    float3 uv = WorldToSDFUV(worldPos);
    
    if (any(uv < 0.0f) || any(uv > 1.0f))
        return 1000.0f;

    float2 sdfData = GlobalSDF.SampleLevel(LinearSampler, uv, 0);
    return sdfData.x * GlobalSDFExtent;
}

bool TraceGlobalSDF(
    float3 rayOrigin, 
    float3 rayDir, 
    float maxDist,
    out float hitDist,
    out float3 hitNormal)
{
    hitDist = maxDist;
    hitNormal = float3(0, 1, 0);
    
    float t = 0.0f;
    
    [loop]
    for (uint i = 0; i < TraceMaxSteps; i++)
    {
        float3 pos = rayOrigin + rayDir * t;
        float dist = SampleGlobalSDF(pos);
        
        if (dist < TraceHitThreshold)
        {
            hitDist = t;

            float eps = VoxelSize * 0.5f;
            hitNormal = normalize(float3(
                SampleGlobalSDF(pos + float3(eps, 0, 0)) - SampleGlobalSDF(pos - float3(eps, 0, 0)),
                SampleGlobalSDF(pos + float3(0, eps, 0)) - SampleGlobalSDF(pos - float3(0, eps, 0)),
                SampleGlobalSDF(pos + float3(0, 0, eps)) - SampleGlobalSDF(pos - float3(0, 0, eps))
            ));
            
            return true;
        }
        
        t += max(dist, VoxelSize);
        
        if (t > maxDist)
            break;
    }
    
    return false;
}

float3 WorldToVoxelUV(float3 worldPos)
{
    return (worldPos - VoxelGridMin) / (VoxelGridMax - VoxelGridMin);
}

float3 SampleVoxelLightingAt(float3 worldPos)
{
    float3 uv = WorldToVoxelUV(worldPos);
    
    if (any(uv < 0.0f) || any(uv > 1.0f))
        return float3(0, 0, 0);
    
    return VoxelLighting.SampleLevel(LinearSampler, uv, 0).rgb;
}

[numthreads(8, 8, 1)]
void main(uint3 groupID : SV_GroupID, uint3 groupThreadID : SV_GroupThreadID)
{
    uint2 probeCoord = groupID.xy;
    uint probeIndex = probeCoord.y * ProbeGridWidth + probeCoord.x;

    uint rayIndex = groupThreadID.y * 8 + groupThreadID.x;
    uint globalIndex = probeIndex * RaysPerProbe + rayIndex;

    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
        return;

    ScreenProbeGPU probe = ProbeBuffer[probeIndex];

    TraceResult result = (TraceResult)0;
    result.HitDistance = MeshSDFTraceDistance;
    result.HitNormal = float3(0, 1, 0);
    result.HitCardIndex = 0xFFFFFFFF;

    uint2 localRayCoord = uint2(rayIndex % OctahedronWidth, rayIndex / OctahedronWidth);
    uint2 screenOffset = uint2(localRayCoord.x, localRayCoord.y % ProbeSpacing);
    uint2 screenCoord = probeCoord * ProbeSpacing + screenOffset;

    screenCoord = min(screenCoord, uint2(ScreenWidth - 1, ScreenHeight - 1));

    float pixelDepth = GBufferDepth[screenCoord];

    if (pixelDepth <= 0.0f || pixelDepth >= 0.9999f)
    {
        VoxelTraceResults[globalIndex] = result;
        return;
    }

    float2 screenUV = (float2(screenCoord) + 0.5f) / float2(ScreenWidth, ScreenHeight);
    float3 rayWorldPos = ScreenUVToWorld(screenUV, pixelDepth);

    float3 pixelNormal = GBufferNormal[screenCoord].xyz * 2.0f - 1.0f;
    pixelNormal = SafeNormalize(pixelNormal);

    ImportanceSampleGPU sample = SampleDirections[globalIndex];

    float3 rayOrigin = rayWorldPos + pixelNormal * RayBias;
    float3 rayDir = sample.Direction;
    
    if (length(rayDir) < 0.001f)
    {
        VoxelTraceResults[globalIndex] = result;
        return;
    }
    
    float hitDist;
    float3 hitNormal;
    bool hit = TraceGlobalSDF(rayOrigin, rayDir, TraceMaxDistance, hitDist, hitNormal);
    
    if (hit)
    {
        result.HitPosition = rayOrigin + rayDir * hitDist;
        result.HitDistance = hitDist;
        result.HitNormal = hitNormal;
        result.Validity = 1.0f;
    }
    
    VoxelTraceResults[globalIndex] = result;
}
