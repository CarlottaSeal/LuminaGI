//=============================================================================
// GenerateSampleDirections.hlsl
// Pass 6.4: Structured Importance Sampling
// 结合 BRDF PDF 和 Lighting PDF 生成采样方向
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeSH.hlsli"
#include "ScreenProbeRegisters.hlsli"


StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV); // t401
StructuredBuffer<SH2CoeffsGPU>   BRDFPDF     : register(REG_BRDF_PDF_SRV);     // t403
StructuredBuffer<SH2CoeffsGPU>   LightingPDF : register(REG_LIGHTING_PDF_SRV); // t405

RWStructuredBuffer<ImportanceSampleGPU> SampleDirections : register(REG_SAMPLE_DIR_UAV); // u409

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
    
    // 无效 Probe
    if (probe.Validity <= 0.0f)
    {
        ImportanceSampleGPU sample;
        sample.Direction = float3(0, 1, 0);
        sample.PDF = 0.0f;
        SampleDirections[globalIndex] = sample;
        return;
    }
    
    float3 probeNormal = probe.WorldNormal;
    
    // 加载 PDF SH
    SH2RGB brdfSH;
    brdfSH.R = BRDFPDF[probeIndex].R;
    brdfSH.G = BRDFPDF[probeIndex].G;
    brdfSH.B = BRDFPDF[probeIndex].B;
    
    SH2RGB lightingSH;
    lightingSH.R = LightingPDF[probeIndex].R;
    lightingSH.G = LightingPDF[probeIndex].G;
    lightingSH.B = LightingPDF[probeIndex].B;
    
    // 基础采样方向 (Fibonacci 半球)
    float3 baseDir = FibonacciHemisphere(rayIndex, RaysPerProbe, probeNormal);
    
    // 添加随机抖动
    uint seed = probeIndex * RaysPerProbe + rayIndex + CurrentFrame * 1337u;
    float2 jitter = Random2D(seed) * 0.1f;
    
    // 在切线空间中抖动
    float3 up = abs(probeNormal.y) < 0.999f ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 tangent = normalize(cross(up, probeNormal));
    float3 bitangent = cross(probeNormal, tangent);
    
    float3 sampleDir = normalize(baseDir + tangent * jitter.x + bitangent * jitter.y);
    
    // 确保在半球内
    if (dot(sampleDir, probeNormal) < 0.0f)
    {
        sampleDir = reflect(sampleDir, probeNormal);
    }
    
    // 评估组合 PDF
    float brdfPDF = max(0.001f, (EvaluateSH(brdfSH.R, sampleDir) + 
                                 EvaluateSH(brdfSH.G, sampleDir) + 
                                 EvaluateSH(brdfSH.B, sampleDir)) / 3.0f);
    
    float lightingPDF = max(0.001f, (EvaluateSH(lightingSH.R, sampleDir) + 
                                      EvaluateSH(lightingSH.G, sampleDir) + 
                                      EvaluateSH(lightingSH.B, sampleDir)) / 3.0f);
    
    // MIS 组合
    float combinedPDF = BRDFWeight * brdfPDF + LightingWeight * lightingPDF;
    combinedPDF = max(0.001f, combinedPDF);
    
    ImportanceSampleGPU sample;
    sample.Direction = sampleDir;
    sample.PDF = combinedPDF;
    SampleDirections[globalIndex] = sample;
}
