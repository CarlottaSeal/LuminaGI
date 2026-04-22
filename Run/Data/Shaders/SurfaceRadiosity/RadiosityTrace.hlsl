#include "RadiosityCacheCommon.hlsli"

Texture2DArray<float4>              SurfaceCacheAtlas   : register(t0);
StructuredBuffer<SurfaceCardMetadata> CardMetadataBuffer : register(t1);

Texture3D<float>    GlobalSDF       : register(t10);
Texture3D<float4>   VoxelLighting   : register(t11);

RWTexture2D<float4> TraceRadianceAtlas : register(u0);

SamplerState PointSampler   : register(s0);
SamplerState LinearSampler  : register(s1);

#define LAYER_ALBEDO        0
#define LAYER_NORMAL        1
#define LAYER_MATERIAL      2
#define LAYER_DIRECT_LIGHT  3
#define LAYER_INDIRECT_LIGHT 4
#define LAYER_COMBINED      5

// Hammersley sequence
float2 Hammersley16(uint Index, uint NumSamples)
{
    float E1 = frac((float)Index / NumSamples);
    uint bits = Index;
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    float E2 = float(bits) * 2.3283064365386963e-10f;
    return float2(E1, E2);
}

uint2 GetProbeJitter(uint temporalIndex)
{
    return uint2(Hammersley16(temporalIndex % MAX_FRAME_ACCUMULATED, MAX_FRAME_ACCUMULATED) * float(PROBE_TEXELS_SIZE));
}

// SimLumen: Cosine-weighted hemisphere sampling
// PDF = cos(theta) / PI
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

// SimLumen: Frisvad tangent basis
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

// GetRadiosityRay — generate ray from pixel position
void GetRadiosityRay(uint2 tileIndex, uint2 subTilePos, float3 worldNormal, out float3 worldRay, out float pdf)
{
    // Probe texel center (0.5, 0.5)
    float2 probeTexelJitter = float2(0.5f, 0.5f);
    float2 probeUV = (float2(subTilePos) + probeTexelJitter) / float(PROBE_TEXELS_SIZE);

    float4 raySample = CosineSampleHemisphere(probeUV);
    float3 localRayDirection = raySample.xyz;
    pdf = raySample.w;

    float3x3 tangentBasis = GetTangentBasisFrisvad(worldNormal);
    worldRay = mul(localRayDirection, tangentBasis);
    worldRay = normalize(worldRay);
}

// SDF Tracing
float SampleGlobalSDF(float3 worldPos)
{
    // Must match BuildGlobalSDF.hlsl: AABB-based UV, not cube-based
    float3 sdfUV = (worldPos - SceneBoundsMin) / (SceneBoundsMax - SceneBoundsMin);

    if (any(sdfUV < 0.0f) || any(sdfUV > 1.0f))
        return TraceMaxDistance;

    return GlobalSDF.SampleLevel(LinearSampler, sdfUV, 0);
}

bool TraceGlobalSDF(float3 origin, float3 direction, float maxDist, out float hitDist, out float3 hitPos)
{
    float t = RayBias;

    [loop]
    for (uint i = 0; i < TraceMaxSteps; i++)
    {
        float3 pos = origin + direction * t;
        float dist = SampleGlobalSDF(pos);

        if (dist < TraceHitThreshold)
        {
            hitDist = t;
            hitPos = pos;
            return true;
        }

        t += max(dist, 0.02f);

        if (t > maxDist)
            break;
    }

    hitDist = maxDist;
    hitPos = origin + direction * maxDist;
    return false;
}

// Voxel Lighting sampling — direction-weighted approximation
float3 SampleVoxelLightingAtPosition(float3 worldPos, float3 rayDir)
{
    float3 voxelExtent = SceneBoundsMax - SceneBoundsMin;
    float3 voxelUV = (worldPos - SceneBoundsMin) / voxelExtent;

    if (any(voxelUV < 0.0f) || any(voxelUV > 1.0f))
        return float3(0, 0, 0);

    // Sample along 3 principal axes; blend by direction weight
    // 3D texture only (not a 6-direction buffer); offset sampling approximates directionality
    float3 voxelSize = voxelExtent / float3(GlobalSDFResolution, GlobalSDFResolution, GlobalSDFResolution);
    float offsetDist = length(voxelSize) * 0.5f;

    // 6 directions
    float3 directions[6] = {
        float3(1, 0, 0), float3(-1, 0, 0),
        float3(0, 1, 0), float3(0, -1, 0),
        float3(0, 0, 1), float3(0, 0, -1)
    };

    float3 totalRadiance = float3(0, 0, 0);
    float totalWeight = 0.0f;

    // Sample center
    float3 centerRadiance = VoxelLighting.SampleLevel(LinearSampler, voxelUV, 0).rgb;

    // Compute per-direction weight from ray direction
    for (int i = 0; i < 6; i++)
    {
        float weight = saturate(dot(rayDir, directions[i]));
        if (weight > 0.001f)
        {
            // Sample offset along this direction
            float3 offsetPos = worldPos + directions[i] * offsetDist;
            float3 offsetUV = (offsetPos - SceneBoundsMin) / voxelExtent;

            if (all(offsetUV >= 0.0f) && all(offsetUV <= 1.0f))
            {
                float3 dirRadiance = VoxelLighting.SampleLevel(LinearSampler, offsetUV, 0).rgb;
                totalRadiance += dirRadiance * weight;
                totalWeight += weight;
            }
            else
            {
                // Out of range: fall back to center sample
                totalRadiance += centerRadiance * weight;
                totalWeight += weight;
            }
        }
    }

    if (totalWeight > 0.001f)
    {
        return totalRadiance / totalWeight;
    }

    return centerRadiance;
}

// Get pixel world position and normal
struct PixelData
{
    float3 WorldPosition;
    float3 WorldNormal;
    float Depth;
    bool Valid;
};

PixelData GetPixelData(uint2 atlasCoord)
{
    PixelData data;
    data.Valid = false;

    // Find which Card contains this pixel
    [loop]
    for (uint i = 0; i < ActiveCardCount; i++)
    {
        SurfaceCardMetadata card = CardMetadataBuffer[i];

        if (atlasCoord.x >= card.AtlasX &&
            atlasCoord.x < card.AtlasX + card.ResolutionX &&
            atlasCoord.y >= card.AtlasY &&
            atlasCoord.y < card.AtlasY + card.ResolutionY)
        {
            float2 localPixel = float2(atlasCoord) - float2(card.AtlasX, card.AtlasY);
            float2 uv = (localPixel + 0.5f) / float2(card.ResolutionX, card.ResolutionY);

            data.WorldPosition = card.Origin
                + card.AxisX * (uv.x - 0.5f) * card.WorldSize.x
                + card.AxisY * (uv.y - 0.5f) * card.WorldSize.y;

            float4 normalData = SurfaceCacheAtlas.Load(int4(atlasCoord, LAYER_NORMAL, 0));
            data.WorldNormal = normalData.xyz * 2.0f - 1.0f;
            data.WorldNormal = SafeNormalize(data.WorldNormal);

            data.Depth = 1.0f; // Simplified: assume valid
            data.Valid = true;
            break;
        }
    }

    return data;
}

// Main: one ray per pixel
[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pixelCoord = dispatchThreadID.xy;

    if (pixelCoord.x >= AtlasWidth || pixelCoord.y >= AtlasHeight)
        return;

    float4 normalCheck = SurfaceCacheAtlas.Load(int4(pixelCoord, LAYER_NORMAL, 0));
    if (dot(normalCheck.xyz, normalCheck.xyz) < 0.001f)
    {
        TraceRadianceAtlas[pixelCoord] = float4(0, 0, 0, 0);
        return;
    }

    // Compute pixel position within probe grid
    uint2 tileIndex = pixelCoord / PROBE_TEXELS_SIZE;
    uint2 subTilePos = pixelCoord % PROBE_TEXELS_SIZE;

    // Hammersley jitter — deterministic sequence, 4-frame cycle
    uint temporalIndex = tileIndex.y * (AtlasWidth / PROBE_TEXELS_SIZE) + tileIndex.x + FrameIndex;
    uint2 probeJitter = GetProbeJitter(temporalIndex);

    uint2 probeStartPos = tileIndex * PROBE_TEXELS_SIZE;
    uint2 probeCenterPos = probeStartPos + probeJitter;

    // Get probe center pixel data
    PixelData probeData = GetPixelData(probeCenterPos);

    float3 radiance = float3(0, 0, 0);

    if (probeData.Valid)
    {
        // Generate ray for this pixel
        float3 worldRay;
        float pdf;
        GetRadiosityRay(tileIndex, subTilePos, probeData.WorldNormal, worldRay, pdf);

        // SDF trace
        float3 rayOrigin = probeData.WorldPosition + probeData.WorldNormal * RayBias;
        float hitDist;
        float3 hitPos;
        bool hit = TraceGlobalSDF(rayOrigin, worldRay, TraceMaxDistance, hitDist, hitPos);

        if (hit)
        {
            // Quadratic distance fade to suppress corner over-brightening
            // Reference distance ~5 units (half the short room dimension)
            float refDist = 5.0f;
            float normDist = saturate(hitDist / refDist);
            float distFade = normDist * normDist;

            radiance = SampleVoxelLightingAtPosition(hitPos, worldRay) * distFade;
        }
        else
        {
            radiance = SampleSkyLight(worldRay, SkyIntensity);
            if (SkyIntensity < 0.001f)
            {
                radiance = float3(0.01f, 0.01f, 0.01f);
            }
        }

        // Normalize: divide by PI
        radiance = radiance * (1.0f / PI);

        // Firefly clamp: limit to 1/PI (Lambertian BRDF maximum)
        float maxLighting = max(radiance.r, max(radiance.g, radiance.b));
        if (maxLighting > (1.0f / PI))
        {
            radiance *= (1.0f / PI) / maxLighting;
        }
    }

    TraceRadianceAtlas[pixelCoord] = float4(radiance, 0.0f);
}
