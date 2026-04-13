//=============================================================================
// SpatialFilter.hlsl
// 5-neighbor spatial averaging
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

Texture2D<float4> ProbeRadiance : register(REG_PROBE_RAD_SRV);
Texture2D<float>  DepthBuffer : register(REG_DEPTH_BUFFER);

StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV);

RWTexture2D<float4> ProbeRadianceFiltered : register(REG_PROBE_RAD_FILT_UAV);

[numthreads(8, 8, 1)]
void main(uint3 groupID : SV_GroupID, uint3 groupThreadID : SV_GroupThreadID)
{
    uint2 probeCoord = groupID.xy;
    uint2 localCoord = groupThreadID.xy;

    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
        return;

    uint probeIndex = probeCoord.y * ProbeGridWidth + probeCoord.x;
    ScreenProbeGPU probe = ProbeBuffer[probeIndex];

    // OctahedronWidth x OctahedronHeight per probe layout
    uint2 rayTexCoord = probeCoord * uint2(OctahedronWidth, OctahedronHeight) + localCoord;

    if (probe.Validity < 0.001f || probe.Depth == 0.0f)
    {
        ProbeRadianceFiltered[rayTexCoord] = float4(0, 0, 0, 0);
        return;
    }

    float4 centerSample = ProbeRadiance[rayTexCoord];
    float3 totalRadiance = centerSample.rgb;
    float totalAO = centerSample.a;
    float totalWeight = 1.0f;

    int2 offsets[4] = { int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1) };

    [unroll]
    for (uint i = 0; i < 4; i++)
    {
        int2 neighborProbeCoord = int2(probeCoord) + offsets[i];

        if (neighborProbeCoord.x < 0 || neighborProbeCoord.x >= (int)ProbeGridWidth ||
            neighborProbeCoord.y < 0 || neighborProbeCoord.y >= (int)ProbeGridHeight)
            continue;

        uint neighborProbeIndex = neighborProbeCoord.y * ProbeGridWidth + neighborProbeCoord.x;
        ScreenProbeGPU neighborProbe = ProbeBuffer[neighborProbeIndex];

        if (neighborProbe.Validity > 0.001f && neighborProbe.Depth != 0.0f)
        {
            // Bilateral weight: reject neighbors on different surfaces
            float planeDist = abs(dot(probe.WorldPosition - neighborProbe.WorldPosition, probe.WorldNormal));
            float depthWeight = exp(-planeDist * DepthWeightScale);
            float normalWeight = pow(saturate(dot(probe.WorldNormal, neighborProbe.WorldNormal)), NormalWeightScale);
            float weight = depthWeight * normalWeight;

            if (weight > 0.001f)
            {
                int2 neighborTexCoord = neighborProbeCoord * int2(OctahedronWidth, OctahedronHeight) + int2(localCoord);
                float4 neighborSample = ProbeRadiance[neighborTexCoord];

                totalRadiance += neighborSample.rgb * weight;
                totalAO += neighborSample.a * weight;
                totalWeight += weight;
            }
        }
    }

    float3 filteredRadiance = totalRadiance / totalWeight;
    float filteredAO = totalAO / totalWeight;

    if (any(isnan(filteredRadiance)) || any(isinf(filteredRadiance)))
        filteredRadiance = float3(0, 0, 0);

    ProbeRadianceFiltered[rayTexCoord] = float4(filteredRadiance, filteredAO);
}
