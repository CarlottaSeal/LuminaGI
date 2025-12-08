//=============================================================================
// RadianceComposite.hlsl
// Pass 6.7: Radiance Composite
// 从追踪结果采样光照，组合成 Probe Radiance
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

//=============================================================================
// 资源绑定 - 使用 Bindless 寄存器号
//=============================================================================

StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV);         // t401
StructuredBuffer<ImportanceSampleGPU> SampleDirections : register(REG_SAMPLE_DIR_SRV); // t410
StructuredBuffer<TraceResult> VoxelTraceResults : register(REG_VOXEL_TRACE_SRV);       // t414
Texture3D<float4> VoxelLighting : register(REG_VOXEL_LIGHTING_SRV);                    // t379

RWTexture2D<float4> ProbeRadiance : register(REG_PROBE_RAD_UAV); // u415

SamplerState LinearSampler : register(s1);

//=============================================================================
// 辅助函数
//=============================================================================

float3 SampleVoxelLighting(float3 worldPos)
{
    float3 voxelUV = (worldPos - VoxelGridMin) / (VoxelGridMax - VoxelGridMin);
    
    if (any(voxelUV < 0.0f) || any(voxelUV > 1.0f))
        return float3(0, 0, 0);
    
    return VoxelLighting.SampleLevel(LinearSampler, voxelUV, 0).rgb;
}

//=============================================================================
// 主计算着色器
//=============================================================================

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 rayTexCoord = dispatchThreadID.xy;
    
    if (rayTexCoord.x >= RaysTexWidth || rayTexCoord.y >= RaysTexHeight)
        return;
    
    // 计算 Probe 和 Ray 索引
    uint2 probeCoord = rayTexCoord / 8;
    uint2 localRayCoord = rayTexCoord % 8;
    uint rayIndex = localRayCoord.y * 8 + localRayCoord.x;
    
    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
        return;
    
    uint probeIndex = probeCoord.y * ProbeGridWidth + probeCoord.x;
    uint globalRayIndex = probeIndex * RaysPerProbe + rayIndex;
    
    ScreenProbeGPU probe = ProbeBuffer[probeIndex];
    
    if (probe.Validity <= 0.0f || rayIndex >= RaysPerProbe)
    {
        ProbeRadiance[rayTexCoord] = float4(0, 0, 0, 0);
        return;
    }
    
    ImportanceSampleGPU sampleData = SampleDirections[globalRayIndex];
    float3 rayDir = sampleData.Direction;
    float pdf = sampleData.PDF;
    
    if (length(rayDir) < 0.001f || pdf < 0.001f)
    {
        ProbeRadiance[rayTexCoord] = float4(0, 0, 0, 0);
        return;
    }
    
    TraceResult traceResult = VoxelTraceResults[globalRayIndex];
    
    float3 radiance = float3(0, 0, 0);
    
    if (traceResult.Validity > 0.0f)
    {
        // 命中：采样 Voxel Lighting
        radiance = SampleVoxelLighting(traceResult.HitPosition);
    }
    else
    {
        // 未命中：天空光
        radiance = SampleSimpleSky(rayDir, SkyIntensity);
    }
    
    // Cosine 加权
    float cosWeight = saturate(dot(rayDir, probe.WorldNormal));
    
    // 重要性采样校正
    float weight = cosWeight / max(pdf, 0.001f);
    
    ProbeRadiance[rayTexCoord] = float4(radiance * weight, weight);
}
