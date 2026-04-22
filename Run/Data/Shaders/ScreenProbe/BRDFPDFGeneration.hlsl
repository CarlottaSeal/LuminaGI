// Pass 6.2: BRDF PDF Generation
// Compute per-probe Lambertian BRDF PDF, projected to SH2
//
// For Lambertian BRDF, the importance distribution is a clamped cosine lobe:
//   PDF(ω) ∝ max(0, dot(ω, normal))
//
// The SH projection of this distribution is analytic (Zonal Harmonics):
//   L0: A0 = π
//   L1: A1 = 2π/3

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeSH.hlsli"
#include "ScreenProbeRegisters.hlsli"

StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV);

RWStructuredBuffer<SH2CoeffsGPU> BRDFPDFOutput : register(REG_BRDF_PDF_UAV);

// Compute SH projection of Lambertian BRDF (clamped cosine lobe)
// Analytic result — no sampling required
float4 ProjectLambertianBRDF(float3 normal)
{
    // Compute SH basis functions for the normal direction
    float4 basis = SHBasisFunction2(normal);

    // Zonal Harmonics coefficients (clamped cosine lobe)
    // A0 = π (L0 band)
    // A1 = 2π/3 (L1 band)
    float A0 = PI;
    float A1 = 2.0f * PI / 3.0f;

    // Apply ZH coefficients to the rotated basis functions
    return float4(
        basis.x * A0,    // L0
        basis.y * A1,    // L1_y
        basis.z * A1,    // L1_z
        basis.w * A1     // L1_x
    );
}

// Main compute shader

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 probeCoord = dispatchThreadID.xy;

    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
        return;

    uint probeIndex = probeCoord.y * ProbeGridWidth + probeCoord.x;
    ScreenProbeGPU probe = ProbeBuffer[probeIndex];

    // Check probe validity
    if (probe.Validity <= 0.0f)
    {
        // Invalid probe: use uniform distribution (L0 only)
        SH2CoeffsGPU result;
        result.R = float4(SH_L0, 0, 0, 0);
        result.G = float4(SH_L0, 0, 0, 0);
        result.B = float4(SH_L0, 0, 0, 0);
        BRDFPDFOutput[probeIndex] = result;
        return;
    }

    float3 probeNormal = SafeNormalize(probe.WorldNormal);

    // Compute SH projection of Lambertian BRDF
    // Analytic result — no per-pixel sampling required
    float4 brdfSH = ProjectLambertianBRDF(probeNormal);

    // RGB channels share the same BRDF (diffuse is color-independent)
    SH2CoeffsGPU result;
    result.R = brdfSH;
    result.G = brdfSH;
    result.B = brdfSH;
    BRDFPDFOutput[probeIndex] = result;
}
