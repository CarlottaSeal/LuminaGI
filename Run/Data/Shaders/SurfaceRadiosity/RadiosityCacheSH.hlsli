//=============================================================================
// RadiosityCacheSH.hlsli
// 球谐函数 (Spherical Harmonics) - L0 + L1 = 4 个基函数
//=============================================================================

#ifndef RADIOSITY_CACHE_SH_HLSLI
#define RADIOSITY_CACHE_SH_HLSLI

//=============================================================================
// SH 基函数系数
//=============================================================================

// L0 (常数项)
static const float SH_L0 = 0.282095f;  // 1 / (2 * sqrt(PI))

// L1 (线性项)
static const float SH_L1 = 0.488603f;  // sqrt(3) / (2 * sqrt(PI))

// Cosine lobe 的 SH 系数 (用于漫反射)
static const float CosineLobeA0 = 3.14159265f;  // PI
static const float CosineLobeA1 = 2.09439510f;  // 2*PI/3

//=============================================================================
// SH2 结构体
//=============================================================================

struct SH2RGB
{
    float4 R;  // [L0, L1_x, L1_y, L1_z] for Red
    float4 G;  // [L0, L1_x, L1_y, L1_z] for Green
    float4 B;  // [L0, L1_x, L1_y, L1_z] for Blue
};

//=============================================================================
// SH 初始化
//=============================================================================

SH2RGB InitSH()
{
    SH2RGB sh;
    sh.R = float4(0, 0, 0, 0);
    sh.G = float4(0, 0, 0, 0);
    sh.B = float4(0, 0, 0, 0);
    return sh;
}

//=============================================================================
// SH 评估
//=============================================================================

// 评估 SH 基函数
float4 EvaluateSHBasis(float3 direction)
{
    return float4(
        SH_L0,                    // L0
        SH_L1 * direction.y,      // L1_y
        SH_L1 * direction.z,      // L1_z
        SH_L1 * direction.x       // L1_x
    );
}

// 从 SH 系数重建方向性辐射度
float EvaluateSH(float4 shCoeffs, float3 direction)
{
    float4 basis = EvaluateSHBasis(direction);
    return max(0.0f, dot(shCoeffs, basis));
}

// RGB 版本
float3 EvaluateSHRGB(SH2RGB sh, float3 direction)
{
    float4 basis = EvaluateSHBasis(direction);
    return float3(
        max(0.0f, dot(sh.R, basis)),
        max(0.0f, dot(sh.G, basis)),
        max(0.0f, dot(sh.B, basis))
    );
}

//=============================================================================
// SH 投影
//=============================================================================

// 将单个方向的辐射度投影到 SH
void ProjectToSH(float3 direction, float radiance, inout float4 shCoeffs)
{
    float4 basis = EvaluateSHBasis(direction);
    shCoeffs += basis * radiance;
}

// RGB 版本
void ProjectToSHRGB(float3 direction, float3 radiance, inout SH2RGB sh)
{
    float4 basis = EvaluateSHBasis(direction);
    sh.R += basis * radiance.r;
    sh.G += basis * radiance.g;
    sh.B += basis * radiance.b;
}

//=============================================================================
// SH 归一化
//=============================================================================

void NormalizeSH(inout float4 shCoeffs, float normFactor)
{
    shCoeffs *= normFactor;
}

void NormalizeSHRGB(inout SH2RGB sh, float normFactor)
{
    sh.R *= normFactor;
    sh.G *= normFactor;
    sh.B *= normFactor;
}

//=============================================================================
// SH 运算
//=============================================================================

SH2RGB AddSH(SH2RGB a, SH2RGB b)
{
    SH2RGB result;
    result.R = a.R + b.R;
    result.G = a.G + b.G;
    result.B = a.B + b.B;
    return result;
}

SH2RGB ScaleSH(SH2RGB sh, float scale)
{
    SH2RGB result;
    result.R = sh.R * scale;
    result.G = sh.G * scale;
    result.B = sh.B * scale;
    return result;
}

SH2RGB LerpSH(SH2RGB a, SH2RGB b, float t)
{
    SH2RGB result;
    result.R = lerp(a.R, b.R, t);
    result.G = lerp(a.G, b.G, t);
    result.B = lerp(a.B, b.B, t);
    return result;
}

//=============================================================================
// SH 漫反射照明
//=============================================================================

float3 SHDiffuse(SH2RGB sh, float3 normal)
{
    float4 basis = EvaluateSHBasis(normal);
    
    float3 irradiance = float3(
        dot(sh.R, basis),
        dot(sh.G, basis),
        dot(sh.B, basis)
    );
    
    return max(float3(0, 0, 0), irradiance) * INV_PI;
}

#endif // RADIOSITY_CACHE_SH_HLSLI
