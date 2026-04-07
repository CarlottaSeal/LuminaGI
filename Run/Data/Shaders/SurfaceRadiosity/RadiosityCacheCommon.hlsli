//=============================================================================
// RadiosityCacheCommon.hlsli
// Surface Radiosity Cache common definitions
//=============================================================================

#ifndef RADIOSITY_CACHE_COMMON_HLSLI
#define RADIOSITY_CACHE_COMMON_HLSLI

//=============================================================================
// Constants
//=============================================================================

#define PI          3.14159265359f
#define TWO_PI      6.28318530718f
#define HALF_PI     1.57079632679f
#define INV_PI      0.31830988618f
#define INV_TWO_PI  0.15915494309f

// Probe constants
#define PROBE_TEXELS_SIZE       4       // Each probe covers a 4x4 pixel tile
#define MAX_FRAME_ACCUMULATED   4       // Hammersley 4-frame cycle

cbuffer SurfaceRadiosityConstants : register(b0)
{
    uint    AtlasWidth;
    uint    AtlasHeight;
    uint    ProbeGridWidth;
    uint    ProbeGridHeight;

    uint    RaysPerProbe;
    float   ProbeSpacing;
    float   TraceMaxDistance;
    uint    TraceMaxSteps;

    float   TraceHitThreshold;
    float   RayBias;
    float   TemporalBlendFactor;
    float   SkyIntensity;

    float3  GlobalSDFCenter;
    float   GlobalSDFExtent;

    float3  GlobalSDFInvExtent;
    uint    GlobalSDFResolution;

    float3  SceneBoundsMin;
    float   VoxelLightingPadding0;
    float3  SceneBoundsMax;
    float   VoxelLightingPadding1;

    float   DepthWeightScale;
    float   NormalWeightScale;
    uint    FilterRadius;
    float   IndirectIntensity;

    uint    FrameIndex;
    uint    ActiveCardCount;
    uint    Padding0;
    uint    Padding1;
};

struct SurfaceCardMetadata
{
    uint    AtlasX;
    uint    AtlasY;
    uint    ResolutionX;
    uint    ResolutionY;
    
    float3  Origin;
    float   Padding0;
    
    float3  AxisX;
    float   Padding1;
    
    float3  AxisY;
    float   Padding2;
    
    float3  Normal;
    float   Padding3;
    
    float2  WorldSize;
    uint    Direction;
    uint    GlobalCardID;
    
    uint4   LightMask;
};

float3 SafeNormalize(float3 v)
{
    float len = length(v);
    return len > 0.0001f ? v / len : float3(0, 1, 0);
}

float Luminance(float3 color)
{
    return dot(color, float3(0.2126f, 0.7152f, 0.0722f));
}

uint PCGHash(uint input)
{
    uint state = input * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float Random(uint seed)
{
    return float(PCGHash(seed)) / 4294967296.0f;
}

float2 Random2D(uint seed)
{
    return float2(Random(seed), Random(seed + 1u));
}

float3 FibonacciHemisphere(uint index, uint count, float3 normal)
{
    float phi = TWO_PI * frac(float(index) * 0.6180339887f);
    float cosTheta = 1.0f - (2.0f * index + 1.0f) / (2.0f * count);
    cosTheta = max(0.0f, cosTheta);
    float sinTheta = sqrt(1.0f - cosTheta * cosTheta);

    float3 localDir = float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);

    // Transform to normal space
    float3 up = abs(normal.y) < 0.999f ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 tangent = normalize(cross(up, normal));
    float3 bitangent = cross(normal, tangent);

    return normalize(tangent * localDir.x + bitangent * localDir.y + normal * localDir.z);
}

float3 CosineSampleHemisphere(float2 random, float3 normal)
{
    float phi = TWO_PI * random.x;
    float cosTheta = sqrt(random.y);
    float sinTheta = sqrt(1.0f - random.y);
    
    float3 localDir = float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
    
    float3 up = abs(normal.y) < 0.999f ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 tangent = normalize(cross(up, normal));
    float3 bitangent = cross(normal, tangent);
    
    return normalize(tangent * localDir.x + bitangent * localDir.y + normal * localDir.z);
}

float3 SampleSkyLight(float3 direction, float intensity)
{
    float skyGradient = saturate(direction.y * 0.5f + 0.5f);
    float3 horizonColor = float3(0.3f, 0.4f, 0.5f);
    float3 zenithColor = float3(0.5f, 0.7f, 1.0f);
    return lerp(horizonColor, zenithColor, skyGradient) * intensity;
}

float ComputeDepthWeight(float pixelDepth, float probeDepth, float scale)
{
    float depthDiff = abs(pixelDepth - probeDepth);
    return exp(-depthDiff * scale);
}

float ComputeNormalWeight(float3 pixelNormal, float3 probeNormal, float power)
{
    float normalDot = saturate(dot(pixelNormal, probeNormal));
    return pow(normalDot, power);
}

#endif // RADIOSITY_CACHE_COMMON_HLSLI
