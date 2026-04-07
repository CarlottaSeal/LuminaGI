//=============================================================================
// IntegrateSH.hlsl
// Bilinear probe interpolation + diffuse transfer SH + DotSH
//=============================================================================

#include "RadiosityCacheCommon.hlsli"

Texture2DArray<float4> SurfaceCacheAtlas : register(t0);
StructuredBuffer<SurfaceCardMetadata> CardMetadataBuffer : register(t1);

Texture2D<float4> RadiositySH_R_In : register(t23);
Texture2D<float4> RadiositySH_G_In : register(t24);
Texture2D<float4> RadiositySH_B_In : register(t25);

RWTexture2DArray<float4> SurfaceCacheAtlasOutput : register(u0);

#define LAYER_NORMAL 1
#define LAYER_INDIRECT_LIGHT 4

//=============================================================================
// SH structure
//=============================================================================
struct FTwoBandSHVector
{
    float4 V;  // [L0, L1y, L1z, L1x]
};

struct FTwoBandSHVectorRGB
{
    FTwoBandSHVector R;
    FTwoBandSHVector G;
    FTwoBandSHVector B;
};

FTwoBandSHVectorRGB GetRadiosityProbeSH(uint2 probeCoord)
{
    uint probeGridWidth = AtlasWidth / PROBE_TEXELS_SIZE;
    uint probeGridHeight = AtlasHeight / PROBE_TEXELS_SIZE;

    FTwoBandSHVectorRGB sh;
    sh.R.V = float4(0, 0, 0, 0);
    sh.G.V = float4(0, 0, 0, 0);
    sh.B.V = float4(0, 0, 0, 0);

    if (probeCoord.x >= probeGridWidth || probeCoord.y >= probeGridHeight)
        return sh;

    sh.R.V = RadiositySH_R_In.Load(int3(probeCoord, 0));
    sh.G.V = RadiositySH_G_In.Load(int3(probeCoord, 0));
    sh.B.V = RadiositySH_B_In.Load(int3(probeCoord, 0));

    return sh;
}

FTwoBandSHVectorRGB MulSH_Scalar(FTwoBandSHVectorRGB SH, float Scalar)
{
    FTwoBandSHVectorRGB Result;
    Result.R.V = SH.R.V * Scalar;
    Result.G.V = SH.G.V * Scalar;
    Result.B.V = SH.B.V * Scalar;
    return Result;
}

FTwoBandSHVectorRGB AddSH(FTwoBandSHVectorRGB A, FTwoBandSHVectorRGB B)
{
    FTwoBandSHVectorRGB Result;
    Result.R.V = A.R.V + B.R.V;
    Result.G.V = A.G.V + B.G.V;
    Result.B.V = A.B.V + B.B.V;
    return Result;
}

//=============================================================================
// SimLumen: CalcDiffuseTransferSH
//=============================================================================
FTwoBandSHVector SHBasisFunction(float3 InputVector)
{
    FTwoBandSHVector Result;
    Result.V.x = 0.282095f;
    Result.V.y = -0.488603f * InputVector.y;
    Result.V.z = 0.488603f * InputVector.z;
    Result.V.w = -0.488603f * InputVector.x;
    return Result;
}

FTwoBandSHVector CalcDiffuseTransferSH(float3 Normal, float Exponent)
{
    FTwoBandSHVector Result = SHBasisFunction(Normal);

    float L0 = 2.0f * PI / (1.0f + 1.0f * Exponent);
    float L1 = 2.0f * PI / (2.0f + 1.0f * Exponent);

    Result.V.x *= L0;
    Result.V.yzw *= L1;

    return Result;
}

float DotSH(FTwoBandSHVector A, FTwoBandSHVector B)
{
    return dot(A.V, B.V);
}

float3 DotSH_RGB(FTwoBandSHVectorRGB A, FTwoBandSHVector B)
{
    float3 Result;
    Result.r = DotSH(A.R, B);
    Result.g = DotSH(A.G, B);
    Result.b = DotSH(A.B, B);
    return Result;
}

//=============================================================================
// Main
//=============================================================================
[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pixelCoord = dispatchThreadID.xy;

    if (pixelCoord.x >= AtlasWidth || pixelCoord.y >= AtlasHeight)
        return;

    // Read pixel normal
    float4 normalData = SurfaceCacheAtlas.Load(int4(pixelCoord, LAYER_NORMAL, 0));
    float3 pixelNormal = normalData.xyz * 2.0f - 1.0f;
    pixelNormal = SafeNormalize(pixelNormal);

    // Validity check
    if (length(pixelNormal) < 0.5f)
    {
        SurfaceCacheAtlasOutput[uint3(pixelCoord, LAYER_INDIRECT_LIGHT)] = float4(0, 0, 0, 0);
        return;
    }

    // Compute pixel position in probe grid
    uint2 tileIndex = pixelCoord / PROBE_TEXELS_SIZE;
    uint2 subTilePos = pixelCoord % PROBE_TEXELS_SIZE;

    // Bilinear weights
    float2 bilinearWeight = float2(subTilePos) / float(PROBE_TEXELS_SIZE);
    float4 weights = float4(
        (1.0f - bilinearWeight.x) * (1.0f - bilinearWeight.y),  // 00
        (1.0f - bilinearWeight.x) * bilinearWeight.y,           // 01
        bilinearWeight.x * (1.0f - bilinearWeight.y),           // 10
        bilinearWeight.x * bilinearWeight.y                     // 11
    );

    // 4 neighboring probe coordinates
    uint2 probeCoord00 = tileIndex;
    uint2 probeCoord01 = probeCoord00 + uint2(0, 1);
    uint2 probeCoord10 = probeCoord00 + uint2(1, 0);
    uint2 probeCoord11 = probeCoord00 + uint2(1, 1);

    // Load and interpolate SH
    FTwoBandSHVectorRGB irradianceSH;
    irradianceSH.R.V = float4(0, 0, 0, 0);
    irradianceSH.G.V = float4(0, 0, 0, 0);
    irradianceSH.B.V = float4(0, 0, 0, 0);

    FTwoBandSHVectorRGB sh00 = GetRadiosityProbeSH(probeCoord00);
    FTwoBandSHVectorRGB sh01 = GetRadiosityProbeSH(probeCoord01);
    FTwoBandSHVectorRGB sh10 = GetRadiosityProbeSH(probeCoord10);
    FTwoBandSHVectorRGB sh11 = GetRadiosityProbeSH(probeCoord11);

    irradianceSH = AddSH(irradianceSH, MulSH_Scalar(sh00, weights.x));
    irradianceSH = AddSH(irradianceSH, MulSH_Scalar(sh01, weights.y));
    irradianceSH = AddSH(irradianceSH, MulSH_Scalar(sh10, weights.z));
    irradianceSH = AddSH(irradianceSH, MulSH_Scalar(sh11, weights.w));

    // SimLumen: CalcDiffuseTransferSH + DotSH
    FTwoBandSHVector diffuseTransferSH = CalcDiffuseTransferSH(pixelNormal, 1.0f);
    float3 texelIrradiance = max(float3(0, 0, 0), DotSH_RGB(irradianceSH, diffuseTransferSH));

    // Normalize weights
    float totalWeight = weights.x + weights.y + weights.z + weights.w;
    if (totalWeight > 0.001f)
    {
        texelIrradiance = texelIrradiance / totalWeight;
    }

    // Note: IndirectIntensity is applied once in FinalGather, not here
    // Direct output, no clamp

    SurfaceCacheAtlasOutput[uint3(pixelCoord, LAYER_INDIRECT_LIGHT)] = float4(texelIrradiance, 0.0f);
}
