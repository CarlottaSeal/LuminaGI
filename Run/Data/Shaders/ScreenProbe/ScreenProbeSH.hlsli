#ifndef SCREENPROBE_SH_HLSLI
#define SCREENPROBE_SH_HLSLI

//=============================================================================
// SH constants
//=============================================================================
static const float SH_C0 = 0.282095f;    // 1 / (2 * sqrt(PI))
static const float SH_C1 = 0.488603f;    // sqrt(3) / (2 * sqrt(PI))
static const float SH_C2_0 = 1.092548f;  // sqrt(15) / (2 * sqrt(PI))
static const float SH_C2_1 = 0.315392f;  // sqrt(5) / (4 * sqrt(PI))
static const float SH_C2_2 = 0.546274f;  // sqrt(15) / (4 * sqrt(PI))

// PI is already defined in ScreenProbeCommon.hlsli

//=============================================================================
// 3-band SH 结构体 (9 coefficients per channel, like SimLumen/Lumen)
//=============================================================================
struct SH3
{
    float4 V0;  // L0 + L1 (4 coefficients)
    float4 V1;  // L2 (4 coefficients)
    float  V2;  // L2 (1 coefficient)
};

struct SH3RGB
{
    SH3 R;
    SH3 G;
    SH3 B;
};

//=============================================================================
// 2-band SH 结构体 (4 coefficients per channel)
//=============================================================================
struct SH2RGB
{
    float4 R;  // [L0, L1_x, L1_y, L1_z]
    float4 G;
    float4 B;
};

// GPU buffer compatible version (same layout as SH2RGB)
struct SH2CoeffsGPU
{
    float4 R;
    float4 G;
    float4 B;
};

// L0 coefficient for uniform distribution
static const float SH_L0 = 0.282095f;  // Same as SH_C0

SH3 InitSH3()
{
    SH3 sh;
    sh.V0 = float4(0, 0, 0, 0);
    sh.V1 = float4(0, 0, 0, 0);
    sh.V2 = 0;
    return sh;
}

SH3RGB InitSH3RGB()
{
    SH3RGB sh;
    sh.R = InitSH3();
    sh.G = InitSH3();
    sh.B = InitSH3();
    return sh;
}

SH2RGB InitSH2RGB()
{
    SH2RGB sh;
    sh.R = float4(0, 0, 0, 0);
    sh.G = float4(0, 0, 0, 0);
    sh.B = float4(0, 0, 0, 0);
    return sh;
}

// Alias for backward compatibility
SH2RGB InitSH()
{
    return InitSH2RGB();
}

void NormalizeSHRGB(inout SH2RGB sh, float normFactor)
{
    sh.R *= normFactor;
    sh.G *= normFactor;
    sh.B *= normFactor;
}

//=============================================================================
// 3-band SH 基函数 (9 coefficients)
//=============================================================================
SH3 SHBasisFunction3(float3 dir)
{
    SH3 result;

    // L0
    result.V0.x = SH_C0;

    // L1
    result.V0.y = -SH_C1 * dir.y;
    result.V0.z = SH_C1 * dir.z;
    result.V0.w = -SH_C1 * dir.x;

    // L2
    float3 dirSq = dir * dir;
    result.V1.x = SH_C2_0 * dir.x * dir.y;
    result.V1.y = -SH_C2_0 * dir.y * dir.z;
    result.V1.z = SH_C2_1 * (3.0f * dirSq.z - 1.0f);
    result.V1.w = -SH_C2_0 * dir.x * dir.z;
    result.V2 = SH_C2_2 * (dirSq.x - dirSq.y);

    return result;
}

//=============================================================================
// 2-band SH 基函数 (4 coefficients)
//=============================================================================
float4 SHBasisFunction2(float3 dir)
{
    return float4(
        SH_C0,
        -SH_C1 * dir.y,
        SH_C1 * dir.z,
        -SH_C1 * dir.x
    );
}

//=============================================================================
// 3-band SH 投影
//=============================================================================
void ProjectToSH3(float3 dir, float3 radiance, inout SH3RGB sh)
{
    SH3 basis = SHBasisFunction3(dir);

    sh.R.V0 += basis.V0 * radiance.r;
    sh.R.V1 += basis.V1 * radiance.r;
    sh.R.V2 += basis.V2 * radiance.r;

    sh.G.V0 += basis.V0 * radiance.g;
    sh.G.V1 += basis.V1 * radiance.g;
    sh.G.V2 += basis.V2 * radiance.g;

    sh.B.V0 += basis.V0 * radiance.b;
    sh.B.V1 += basis.V1 * radiance.b;
    sh.B.V2 += basis.V2 * radiance.b;
}

//=============================================================================
// 3-band SH 点积 (评估)
//=============================================================================
float DotSH3(SH3 a, SH3 b)
{
    float result = dot(a.V0, b.V0);
    result += dot(a.V1, b.V1);
    result += a.V2 * b.V2;
    return result;
}

float3 DotSH3RGB(SH3RGB sh, SH3 basis)
{
    return float3(
        DotSH3(sh.R, basis),
        DotSH3(sh.G, basis),
        DotSH3(sh.B, basis)
    );
}

//=============================================================================
// Diffuse Transfer SH (for irradiance reconstruction)
//=============================================================================
SH3 CalcDiffuseTransferSH3(float3 normal, float exponent)
{
    SH3 result = SHBasisFunction3(normal);

    // Zonal harmonics scaling factors for cosine lobe
    float L0 = 2 * PI / (1 + 1 * exponent);
    float L1 = 2 * PI / (2 + 1 * exponent);
    float L2 = exponent * 2 * PI / (3 + 4 * exponent + exponent * exponent);

    result.V0.x *= L0;
    result.V0.yzw *= L1;
    result.V1 *= L2;
    result.V2 *= L2;

    return result;
}

//=============================================================================
// 3-band SH 归一化
//=============================================================================
void NormalizeSH3RGB(inout SH3RGB sh, float normFactor)
{
    sh.R.V0 *= normFactor;
    sh.R.V1 *= normFactor;
    sh.R.V2 *= normFactor;

    sh.G.V0 *= normFactor;
    sh.G.V1 *= normFactor;
    sh.G.V2 *= normFactor;

    sh.B.V0 *= normFactor;
    sh.B.V1 *= normFactor;
    sh.B.V2 *= normFactor;
}

//=============================================================================
// 3-band SH 从方向评估 irradiance
//=============================================================================
float3 EvaluateIrradianceSH3(SH3RGB sh, float3 direction)
{
    SH3 diffuseTransfer = CalcDiffuseTransferSH3(direction, 1.0f);
    float3 irradiance = 4.0f * PI * DotSH3RGB(sh, diffuseTransfer);
    return max(irradiance, float3(0, 0, 0));
}

//=============================================================================
// 2-band SH 操作 (保留兼容性)
//=============================================================================
float4 EvaluateSHBasis(float3 direction)
{
    return SHBasisFunction2(direction);
}

float EvaluateSH(float4 shCoeffs, float3 direction)
{
    float4 basis = EvaluateSHBasis(direction);
    return max(0.0f, dot(shCoeffs, basis));
}

float3 EvaluateSHRGB(SH2RGB sh, float3 direction)
{
    float4 basis = EvaluateSHBasis(direction);
    return float3(
        max(0.0f, dot(sh.R, basis)),
        max(0.0f, dot(sh.G, basis)),
        max(0.0f, dot(sh.B, basis))
    );
}

void ProjectToSHRGB(float3 direction, float3 radiance, inout SH2RGB sh)
{
    float4 basis = EvaluateSHBasis(direction);
    sh.R += basis * radiance.r;
    sh.G += basis * radiance.g;
    sh.B += basis * radiance.b;
}

#endif // SCREENPROBE_SH_HLSLI
