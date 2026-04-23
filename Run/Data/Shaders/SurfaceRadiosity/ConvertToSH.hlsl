#include "RadiosityCacheCommon.hlsli"

Texture2D<float4> TraceRadianceFiltered : register(t22);
Texture2DArray<float4> SurfaceCacheAtlas : register(t0);
StructuredBuffer<SurfaceCardMetadata> CardMetadataBuffer : register(t1);
Texture2D<uint>   CardIndexLookup : register(t12);

RWTexture2D<float4> RadiositySH_R : register(u3);
RWTexture2D<float4> RadiositySH_G : register(u4);
RWTexture2D<float4> RadiositySH_B : register(u5);

#define LAYER_NORMAL 1
static const uint CARD_LOOKUP_TILE_SIZE = 64;

// SH structure
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

// SH basis functions
FTwoBandSHVector SHBasisFunction(float3 InputVector)
{
    FTwoBandSHVector Result;
    Result.V.x = 0.282095f;                      // L0
    Result.V.y = -0.488603f * InputVector.y;     // L1y
    Result.V.z = 0.488603f * InputVector.z;      // L1z
    Result.V.w = -0.488603f * InputVector.x;     // L1x
    return Result;
}

FTwoBandSHVectorRGB MulSH(FTwoBandSHVector SH, float3 Color)
{
    FTwoBandSHVectorRGB Result;
    Result.R.V = SH.V * Color.r;
    Result.G.V = SH.V * Color.g;
    Result.B.V = SH.V * Color.b;
    return Result;
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

// Cosine-weighted hemisphere sampling (for ray direction and PDF)
float4 CosineSampleHemisphere(float2 E)
{
    float Phi = 2.0f * PI * E.x;
    float CosTheta = sqrt(E.y);
    float SinTheta = sqrt(1.0f - CosTheta * CosTheta);

    float3 H;
    H.x = SinTheta * cos(Phi);
    H.y = SinTheta * sin(Phi);
    H.z = CosTheta;

    float PDF = CosTheta * (1.0f / PI);
    return float4(H, PDF);
}

float3x3 GetTangentBasisFrisvad(float3 TangentZ)
{
    float3 TangentX;
    float3 TangentY;

    if (TangentZ.z < -0.9999999f)
    {
        TangentX = float3(0, -1, 0);
        TangentY = float3(-1, 0, 0);
    }
    else
    {
        float A = 1.0f / (1.0f + TangentZ.z);
        float B = -TangentZ.x * TangentZ.y * A;
        TangentX = float3(1.0f - TangentZ.x * TangentZ.x * A, B, -TangentZ.x);
        TangentY = float3(B, 1.0f - TangentZ.y * TangentZ.y * A, -TangentZ.y);
    }

    return float3x3(TangentX, TangentY, TangentZ);
}

void GetRadiosityRay(uint2 tileIndex, uint2 subTilePos, float3 worldNormal, out float3 worldRay, out float pdf)
{
    float2 probeTexelJitter = float2(0.5f, 0.5f);
    float2 probeUV = (float2(subTilePos) + probeTexelJitter) / float(PROBE_TEXELS_SIZE);

    float4 raySample = CosineSampleHemisphere(probeUV);
    float3 localRayDirection = raySample.xyz;
    pdf = raySample.w;

    float3x3 tangentBasis = GetTangentBasisFrisvad(worldNormal);
    worldRay = mul(localRayDirection, tangentBasis);
    worldRay = normalize(worldRay);
}

// Get probe center normal
float3 GetProbeNormal(uint2 probeStartPos)
{
    // Use probe center normal
    uint2 centerPos = probeStartPos + uint2(PROBE_TEXELS_SIZE / 2, PROBE_TEXELS_SIZE / 2);

    if (centerPos.x >= AtlasWidth || centerPos.y >= AtlasHeight)
        return float3(0, 0, 1);

    float4 normalData = SurfaceCacheAtlas.Load(int4(centerPos, LAYER_NORMAL, 0));
    float3 normal = normalData.xyz * 2.0f - 1.0f;
    return SafeNormalize(normal);
}

// Main: iterate 4x4 pixels per tile (probe)
[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 tileIndex = dispatchThreadID.xy;

    uint probeGridWidth = AtlasWidth / PROBE_TEXELS_SIZE;
    uint probeGridHeight = AtlasHeight / PROBE_TEXELS_SIZE;

    if (tileIndex.x >= probeGridWidth || tileIndex.y >= probeGridHeight)
        return;

    uint2 probeStartPos = tileIndex * PROBE_TEXELS_SIZE;

    // O(1) early-out: skip probes that aren't on any card (majority of atlas).
    uint2 lookupTile = probeStartPos / CARD_LOOKUP_TILE_SIZE;
    if (CardIndexLookup.Load(int3(lookupTile, 0)) == 0xFFFFFFFF)
    {
        RadiositySH_R[tileIndex] = float4(0, 0, 0, 0);
        RadiositySH_G[tileIndex] = float4(0, 0, 0, 0);
        RadiositySH_B[tileIndex] = float4(0, 0, 0, 0);
        return;
    }

    float3 probeNormal = GetProbeNormal(probeStartPos);

    if (dot(probeNormal, probeNormal) < 0.5f)
    {
        RadiositySH_R[tileIndex] = float4(0, 0, 0, 0);
        RadiositySH_G[tileIndex] = float4(0, 0, 0, 0);
        RadiositySH_B[tileIndex] = float4(0, 0, 0, 0);
        return;
    }

    // Cache tangent basis once — same for all 16 rays of this probe.
    float3x3 tangentBasis = GetTangentBasisFrisvad(probeNormal);

    FTwoBandSHVectorRGB irradianceSH;
    irradianceSH.R.V = float4(0, 0, 0, 0);
    irradianceSH.G.V = float4(0, 0, 0, 0);
    irradianceSH.B.V = float4(0, 0, 0, 0);

    uint numValidSamples = 0;

    [unroll]
    for (uint traceIdxY = 0; traceIdxY < PROBE_TEXELS_SIZE; traceIdxY++)
    {
        [unroll]
        for (uint traceIdxX = 0; traceIdxX < PROBE_TEXELS_SIZE; traceIdxX++)
        {
            uint2 pixelPos = probeStartPos + uint2(traceIdxX, traceIdxY);

            if (pixelPos.x >= AtlasWidth || pixelPos.y >= AtlasHeight)
                continue;

            float3 traceRadiance = TraceRadianceFiltered.Load(int3(pixelPos, 0)).rgb;

            float2 probeUV = (float2(traceIdxX, traceIdxY) + 0.5f) / float(PROBE_TEXELS_SIZE);
            float4 raySample = CosineSampleHemisphere(probeUV);
            float3 worldRay = normalize(mul(raySample.xyz, tangentBasis));
            float pdf = raySample.w;

            if (pdf > 0.001f)
            {
                FTwoBandSHVector basis = SHBasisFunction(worldRay);
                FTwoBandSHVectorRGB contribution = MulSH(basis, traceRadiance / pdf);
                irradianceSH = AddSH(irradianceSH, contribution);
                numValidSamples++;
            }
        }
    }

    if (numValidSamples > 0)
    {
        irradianceSH = MulSH_Scalar(irradianceSH, 1.0f / float(numValidSamples));
    }

    RadiositySH_R[tileIndex] = irradianceSH.R.V;
    RadiositySH_G[tileIndex] = irradianceSH.G.V;
    RadiositySH_B[tileIndex] = irradianceSH.B.V;
}
