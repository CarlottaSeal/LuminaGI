#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeSH.hlsli"
#include "ScreenProbeRegisters.hlsli"

StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV);
StructuredBuffer<SH2CoeffsGPU>   BRDFPDF     : register(REG_BRDF_PDF_SRV);
StructuredBuffer<SH2CoeffsGPU>   LightingPDF : register(REG_LIGHTING_PDF_SRV);

RWStructuredBuffer<ImportanceSampleGPU> SampleDirections : register(REG_SAMPLE_DIR_UAV);

[numthreads(8, 8, 1)]
void main(uint3 groupID : SV_GroupID, uint3 groupThreadID : SV_GroupThreadID)
{
    uint2 probeCoord = groupID.xy;
    uint probeIndex = probeCoord.y * ProbeGridWidth + probeCoord.x;

    uint rayIndex = groupThreadID.y * 8 + groupThreadID.x;
    uint globalRayIndex = probeIndex * RaysPerProbe + rayIndex;

    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
        return;

    ScreenProbeGPU probe = ProbeBuffer[probeIndex];

    if (probe.Validity <= 0.0f)
    {
        ImportanceSampleGPU sample;
        sample.Direction = float3(0, 1, 0);
        sample.PDF = 0.0f;
        SampleDirections[globalRayIndex] = sample;
        return;
    }

    uint localX = rayIndex % OctahedronWidth;
    uint localY = rayIndex / OctahedronWidth;
    float2 octUV = float2((localX + 0.5f) / float(OctahedronWidth), (localY + 0.5f) / float(OctahedronHeight));
    float3 sampleDir = OctahedronUVToDirection(octUV);

    float4 shBasis = EvaluateSHBasis(sampleDir);

    SH2CoeffsGPU brdfSH = BRDFPDF[probeIndex];
    float3 brdfEval = float3(
        max(0.0f, dot(brdfSH.R, shBasis)),
        max(0.0f, dot(brdfSH.G, shBasis)),
        max(0.0f, dot(brdfSH.B, shBasis))
    );
    float brdfPdf = max(0.01f, Luminance(brdfEval));

    SH2CoeffsGPU lightingSH = LightingPDF[probeIndex];
    float3 lightingEval = float3(
        max(0.0f, dot(lightingSH.R, shBasis)),
        max(0.0f, dot(lightingSH.G, shBasis)),
        max(0.0f, dot(lightingSH.B, shBasis))
    );
    float lightingPdf = max(0.01f, Luminance(lightingEval));

    // MIS with Power Heuristic (β = 2)
    // Power Heuristic weights for the two sampling strategies:
    // w_brdf = brdfPdf² / (brdfPdf² + lightingPdf²)
    // w_lighting = lightingPdf² / (brdfPdf² + lightingPdf²)
    // combinedPDF = w_brdf * brdfPdf + w_lighting * lightingPdf
    float brdfPow = brdfPdf * brdfPdf;
    float lightingPow = lightingPdf * lightingPdf;
    float sumPow = brdfPow + lightingPow;

    // Combined PDF: each strategy contributes weighted by its Power Heuristic
    float combinedPDF = (brdfPow * brdfPdf + lightingPow * lightingPdf) / max(sumPow, 0.0001f);

    ImportanceSampleGPU sample;
    sample.Direction = sampleDir;
    sample.PDF = combinedPDF;
    SampleDirections[globalRayIndex] = sample;
}
