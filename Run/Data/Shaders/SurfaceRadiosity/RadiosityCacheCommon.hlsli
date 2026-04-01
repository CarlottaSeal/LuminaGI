//=============================================================================
// RadiosityCacheCommon.hlsli
// Surface Radiosity Cache 所有 Shader 的公共定义
// 统一使用 SurfaceRadiosityConstants
//=============================================================================

#ifndef RADIOSITY_CACHE_COMMON_HLSLI
#define RADIOSITY_CACHE_COMMON_HLSLI

//=============================================================================
// 常量定义
//=============================================================================

#define PI          3.14159265359f
#define TWO_PI      6.28318530718f
#define HALF_PI     1.57079632679f
#define INV_PI      0.31830988618f
#define INV_TWO_PI  0.15915494309f

//=============================================================================
// 统一常量缓冲区 - 与 C++ SurfaceRadiosityConstants 完全匹配
//=============================================================================

cbuffer SurfaceRadiosityConstants : register(b0)
{
    // Surface Cache Atlas 信息
    uint    AtlasWidth;                 // 4096
    uint    AtlasHeight;                // 4096
    uint    ProbeGridWidth;             // 1024 (4096 / 4)
    uint    ProbeGridHeight;            // 1024
    
    // Radiosity 追踪配置
    uint    RaysPerProbe;               // 16
    float   ProbeSpacing;               // 4.0
    float   TraceMaxDistance;           // 200.0
    uint    TraceMaxSteps;              // 64
    
    // 追踪参数
    float   TraceHitThreshold;          // 0.02
    float   RayBias;                    // 0.5
    float   TemporalBlendFactor;        // 0.05
    float   SkyIntensity;               // 0.3
    
    // Global SDF 信息
    float3  GlobalSDFCenter;
    float   GlobalSDFExtent;

    float3  GlobalSDFInvExtent;
    uint    GlobalSDFResolution;

    // Voxel Lighting 场景边界 (与 InjectVoxelLighting 一致)
    float3  SceneBoundsMin;
    float   VoxelLightingPadding0;
    float3  SceneBoundsMax;
    float   VoxelLightingPadding1;
    
    // 滤波参数
    float   DepthWeightScale;           // 10.0
    float   NormalWeightScale;          // 4.0
    uint    FilterRadius;               // 1
    float   IndirectIntensity;          // 1.0
    
    // 其他
    uint    FrameIndex;
    uint    ActiveCardCount;
    uint    Padding0;
    uint    Padding1;
};

//=============================================================================
// GPU 结构体
//=============================================================================

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

//=============================================================================
// 工具函数
//=============================================================================

// 安全归一化
float3 SafeNormalize(float3 v)
{
    float len = length(v);
    return len > 0.0001f ? v / len : float3(0, 1, 0);
}

// RGB 到亮度
float Luminance(float3 color)
{
    return dot(color, float3(0.2126f, 0.7152f, 0.0722f));
}

//=============================================================================
// 随机数生成
//=============================================================================

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

//=============================================================================
// 半球采样
//=============================================================================

// Fibonacci 半球采样
float3 FibonacciHemisphere(uint index, uint count, float3 normal)
{
    float phi = TWO_PI * frac(float(index) * 0.6180339887f);
    float cosTheta = 1.0f - (2.0f * index + 1.0f) / (2.0f * count);
    cosTheta = max(0.0f, cosTheta);
    float sinTheta = sqrt(1.0f - cosTheta * cosTheta);
    
    float3 localDir = float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
    
    // 变换到 Normal 空间
    float3 up = abs(normal.y) < 0.999f ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 tangent = normalize(cross(up, normal));
    float3 bitangent = cross(normal, tangent);
    
    return normalize(tangent * localDir.x + bitangent * localDir.y + normal * localDir.z);
}

// Cosine 加权半球采样
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

//=============================================================================
// 天空采样
//=============================================================================

float3 SampleSkyLight(float3 direction, float intensity)
{
    float skyGradient = saturate(direction.y * 0.5f + 0.5f);
    float3 horizonColor = float3(0.3f, 0.4f, 0.5f);
    float3 zenithColor = float3(0.5f, 0.7f, 1.0f);
    return lerp(horizonColor, zenithColor, skyGradient) * intensity;
}

//=============================================================================
// 权重计算
//=============================================================================

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
