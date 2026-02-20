//=============================================================================
// BRDFPDFGeneration.hlsl
// Pass 6.2: BRDF PDF Generation
// 计算每个 Probe 的 Lambertian BRDF PDF，投影到 SH2
//
// 对于 Lambertian BRDF，重要性分布是 clamped cosine lobe：
//   PDF(ω) ∝ max(0, dot(ω, normal))
//
// 这个分布的 SH 投影是解析的 (Zonal Harmonics)：
//   L0: A0 = π
//   L1: A1 = 2π/3
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeSH.hlsli"
#include "ScreenProbeRegisters.hlsli"

StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV);

RWStructuredBuffer<SH2CoeffsGPU> BRDFPDFOutput : register(REG_BRDF_PDF_UAV);

//=============================================================================
// 计算 Lambertian BRDF 的 SH 投影 (clamped cosine lobe)
// 这是解析解，不需要采样
//=============================================================================
float4 ProjectLambertianBRDF(float3 normal)
{
    // 先计算法线方向的 SH 基函数
    float4 basis = SHBasisFunction2(normal);

    // Zonal Harmonics 系数 (clamped cosine lobe)
    // A0 = π (L0 band)
    // A1 = 2π/3 (L1 band)
    float A0 = PI;
    float A1 = 2.0f * PI / 3.0f;

    // 将 ZH 系数应用到旋转后的基函数
    return float4(
        basis.x * A0,    // L0
        basis.y * A1,    // L1_y
        basis.z * A1,    // L1_z
        basis.w * A1     // L1_x
    );
}

//=============================================================================
// 主计算着色器
//=============================================================================

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 probeCoord = dispatchThreadID.xy;

    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
        return;

    uint probeIndex = probeCoord.y * ProbeGridWidth + probeCoord.x;
    ScreenProbeGPU probe = ProbeBuffer[probeIndex];

    // 检查 Probe 有效性
    if (probe.Validity <= 0.0f)
    {
        // 无效探针：使用均匀分布 (只有 L0)
        SH2CoeffsGPU result;
        result.R = float4(SH_L0, 0, 0, 0);
        result.G = float4(SH_L0, 0, 0, 0);
        result.B = float4(SH_L0, 0, 0, 0);
        BRDFPDFOutput[probeIndex] = result;
        return;
    }

    float3 probeNormal = SafeNormalize(probe.WorldNormal);

    // 计算 Lambertian BRDF 的 SH 投影
    // 这是解析解，不需要采样周围像素
    float4 brdfSH = ProjectLambertianBRDF(probeNormal);

    // RGB 通道使用相同的 BRDF（漫反射是颜色无关的）
    SH2CoeffsGPU result;
    result.R = brdfSH;
    result.G = brdfSH;
    result.B = brdfSH;
    BRDFPDFOutput[probeIndex] = result;
}
