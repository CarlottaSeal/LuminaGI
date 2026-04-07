//=============================================================================
// RadiosityCacheSH.hlsli
// Spherical Harmonics — L0 + L1 = 4 basis functions
//=============================================================================

#ifndef RADIOSITY_CACHE_SH_HLSLI
#define RADIOSITY_CACHE_SH_HLSLI

//=============================================================================
// SH basis function coefficients
//=============================================================================

// L0 (constant term)
static const float SH_L0 = 0.282095f;  // 1 / (2 * sqrt(PI))

// L1 (linear terms)
static const float SH_L1 = 0.488603f;  // sqrt(3) / (2 * sqrt(PI))

// SH coefficients of cosine lobe (diffuse)
static const float CosineLobeA0 = 3.14159265f;  // PI
static const float CosineLobeA1 = 2.09439510f;  // 2*PI/3

//=============================================================================
// SH2 struct
//=============================================================================

struct SH2RGB
{
    float4 R;  // [L0, L1_x, L1_y, L1_z] for Red
    float4 G;  // [L0, L1_x, L1_y, L1_z] for Green
    float4 B;  // [L0, L1_x, L1_y, L1_z] for Blue
};

//=============================================================================
// SH initialization
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
// SH evaluation
//=============================================================================

// Evaluate SH basis functions
float4 EvaluateSHBasis(float3 direction)
{
    return float4(
        SH_L0,                    // L0
        SH_L1 * direction.y,      // L1_y
        SH_L1 * direction.z,      // L1_z
        SH_L1 * direction.x       // L1_x
    );
}

// Reconstruct directional radiance from SH
float EvaluateSH(float4 shCoeffs, float3 direction)
{
    float4 basis = EvaluateSHBasis(direction);
    return max(0.0f, dot(shCoeffs, basis));
}

// RGB version
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
// SH projection
//=============================================================================

// Project single-direction radiance onto SH
void ProjectToSH(float3 direction, float radiance, inout float4 shCoeffs)
{
    float4 basis = EvaluateSHBasis(direction);
    shCoeffs += basis * radiance;
}

// RGB version
void ProjectToSHRGB(float3 direction, float3 radiance, inout SH2RGB sh)
{
    float4 basis = EvaluateSHBasis(direction);
    sh.R += basis * radiance.r;
    sh.G += basis * radiance.g;
    sh.B += basis * radiance.b;
}

//=============================================================================
// SH normalization
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
// SH arithmetic
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
// SH diffuse lighting
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
