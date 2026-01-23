//=============================================================================
// VoxelSDFTrace.hlsl
// Pass 6.5/6.6: Voxel SDF Trace (合并 Mesh 和 Voxel 追踪)
// 追踪 Global SDF，命中后采样 VoxelLighting
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

//=============================================================================
// 资源绑定 - 使用 Bindless 寄存器号
//=============================================================================

StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV);      // t401
StructuredBuffer<ImportanceSampleGPU> SampleDirections : register(REG_SAMPLE_DIR_SRV); // t410

Texture3D<float2> GlobalSDF     : register(REG_GLOBAL_SDF_SRV);     // t378, R=距离, G=实例索引
Texture3D<float4> VoxelLighting : register(REG_VOXEL_LIGHTING_SRV); // t379

RWStructuredBuffer<TraceResult> VoxelTraceResults : register(REG_VOXEL_TRACE_UAV); // u413

SamplerState LinearSampler : register(s1);

//=============================================================================
// Global SDF 追踪
//=============================================================================

float3 WorldToSDFUV(float3 worldPos)
{
    return (worldPos - GlobalSDFCenter) * GlobalSDFInvExtent + 0.5f;
}

float SampleGlobalSDF(float3 worldPos)
{
    float3 uv = WorldToSDFUV(worldPos);
    
    if (any(uv < 0.0f) || any(uv > 1.0f))
        return 1000.0f;
    
    // GlobalSDF 格式: R = 距离, G = 实例索引
    float2 sdfData = GlobalSDF.SampleLevel(LinearSampler, uv, 0);
    return sdfData.x * GlobalSDFExtent;  // 只取距离
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
            
            // 计算法线 (中心差分)
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

//=============================================================================
// Voxel Lighting 采样
//=============================================================================

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
    
    TraceResult result = (TraceResult)0; 
    result.HitDistance = MeshSDFTraceDistance;  
    result.HitNormal = float3(0, 1, 0);         
    result.HitCardIndex = 0xFFFFFFFF;           
    
    if (probe.Validity <= 0.0f)
    {
        VoxelTraceResults[globalIndex] = result;
        return;
    }
    
    ImportanceSampleGPU sample = SampleDirections[globalIndex];
    
    float3 rayOrigin = probe.WorldPosition + probe.WorldNormal * RayBias;
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
