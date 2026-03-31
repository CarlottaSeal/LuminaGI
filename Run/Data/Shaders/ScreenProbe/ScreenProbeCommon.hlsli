// Screen Probe common definitions
#ifndef SCREENPROBE_COMMON_HLSLI
#define SCREENPROBE_COMMON_HLSLI

#define PI 3.14159265359f
#define TWO_PI 6.28318530718f
#define INV_PI 0.31830988618f
#define HALF_PI 1.57079632679f

cbuffer ScreenProbeConstants : register(b0)
{
    uint    ScreenWidth;            // 1920
    uint    ScreenHeight;           // 1080
    uint    ProbeGridWidth;         // 240 (1920/8)
    uint    ProbeGridHeight;        // 135 (1080/8)
    
    uint    ProbeSpacing;           // 8
    uint    RaysPerProbe;           // 64
    uint    RaysTexWidth;           // ProbeGridWidth × 8
    uint    RaysTexHeight;          // ProbeGridHeight × OctahedronHeight
    
    float   TraceMaxDistance;       // 500.0
    uint    TraceMaxSteps;          // 128
    float   TraceHitThreshold;      // 0.5
    float   RayBias;                // 0.5
    
    float   MeshSDFTraceDistance;   // 100.0
    float   VoxelTraceDistance;     // 500.0
    float   TemporalBlendFactor;    // 0.05
    float   SkyIntensity;           // 0.3
    
    uint    CurrentFrame;
    uint    OctahedronSize;         // 8 (width)
    uint    OctahedronBorder;       // 1
    uint    BorderedOctSize;        // 10

    uint    OctahedronWidth;        // 8
    uint    OctahedronHeight;       // 8 (8x8=64 rays)
    uint    MeshInstanceCount;
    uint    Padding6;

    float   DepthThreshold;         // 0.1f
    float   PlaneDepthWeight;       // 10.0f
    float   BRDFWeight;             // 0.5f
    float   LightingWeight;         // 0.5f
    
    uint    FilterRadius;           // 1
    float   DepthWeightScale;       // 10.0f
    float   NormalWeightScale;      // 4.0f
    float   AOStrength;             // 0.5f
    
    uint    OctTexWidth;            // ProbeGridWidth × 10
    uint    OctTexHeight;           // ProbeGridHeight × 10
    uint    Padding3;
    uint    Padding4;
    
    // Global SDF 参数
    float3  GlobalSDFCenter;
    float   GlobalSDFExtent;
    
    float3  GlobalSDFInvExtent;
    uint    GlobalSDFResolution;
    
    // Voxel Lighting 参数
    float3  VoxelGridMin;
    float   VoxelSize;
    
    float3  VoxelGridMax;
    uint    VoxelResolution;
    
    // Surface Cache 参数
    uint    AtlasWidth;             // 4096
    uint    AtlasHeight;            // 4096
    uint    TileSize;               // 128
    uint    ActiveCardCount;
    
    // 相机参数
    float3  CameraPosition;
    float   Padding0;
    
    float4x4 WorldToCamera;        
    float4x4 CameraToRender;       
    float4x4 RenderToClip;  
float4x4 CameraToWorld;        
    float4x4 RenderToCamera;       
    float4x4 ClipToRender;               
    
    float4x4 PrevWorldToCamera;
    float4x4 PrevCameraToRender;
    float4x4 PrevRenderToClip;
    
    float   IndirectIntensity;      // 1.0
    uint UseHistoryBufferB; 
    float   CameraNear;
    float   CameraFar;
};

struct ScreenProbeGPU
{
    uint    ScreenX;
    uint    ScreenY;
    uint    Padding0;     
    uint    Padding1;     
    float3  WorldPosition;
    float   Depth;        
    float3  WorldNormal;
    float   Validity;     
};

struct TraceResult
{
    float3  HitPosition;
    float   HitDistance;
    float3  HitNormal;
    float   Validity;
    uint    HitCardIndex;     
    uint    Padding0;         
    uint    Padding1;
    uint    Padding2;
};

struct ImportanceSampleGPU
{
    float3  Direction;
    float   PDF;
};

float4x4 InverseMatrix(float4x4 m)
{
    float n11 = m[0][0], n12 = m[1][0], n13 = m[2][0], n14 = m[3][0];
    float n21 = m[0][1], n22 = m[1][1], n23 = m[2][1], n24 = m[3][1];
    float n31 = m[0][2], n32 = m[1][2], n33 = m[2][2], n34 = m[3][2];
    float n41 = m[0][3], n42 = m[1][3], n43 = m[2][3], n44 = m[3][3];

    float t11 = n23 * n34 * n42 - n24 * n33 * n42 + n24 * n32 * n43 - n22 * n34 * n43 - n23 * n32 * n44 + n22 * n33 * n44;
    float t12 = n14 * n33 * n42 - n13 * n34 * n42 - n14 * n32 * n43 + n12 * n34 * n43 + n13 * n32 * n44 - n12 * n33 * n44;
    float t13 = n13 * n24 * n42 - n14 * n23 * n42 + n14 * n22 * n43 - n12 * n24 * n43 - n13 * n22 * n44 + n12 * n23 * n44;
    float t14 = n14 * n23 * n32 - n13 * n24 * n32 - n14 * n22 * n33 + n12 * n24 * n33 + n13 * n22 * n34 - n12 * n23 * n34;

    float det = n11 * t11 + n21 * t12 + n31 * t13 + n41 * t14;
    float idet = 1.0f / det;

    float4x4 ret;

    ret[0][0] = t11 * idet;
    ret[0][1] = (n24 * n33 * n41 - n23 * n34 * n41 - n24 * n31 * n43 + n21 * n34 * n43 + n23 * n31 * n44 - n21 * n33 * n44) * idet;
    ret[0][2] = (n22 * n34 * n41 - n24 * n32 * n41 + n24 * n31 * n42 - n21 * n34 * n42 - n22 * n31 * n44 + n21 * n32 * n44) * idet;
    ret[0][3] = (n23 * n32 * n41 - n22 * n33 * n41 - n23 * n31 * n42 + n21 * n33 * n42 + n22 * n31 * n43 - n21 * n32 * n43) * idet;

    ret[1][0] = t12 * idet;
    ret[1][1] = (n13 * n34 * n41 - n14 * n33 * n41 + n14 * n31 * n43 - n11 * n34 * n43 - n13 * n31 * n44 + n11 * n33 * n44) * idet;
    ret[1][2] = (n14 * n32 * n41 - n12 * n34 * n41 - n14 * n31 * n42 + n11 * n34 * n42 + n12 * n31 * n44 - n11 * n32 * n44) * idet;
    ret[1][3] = (n12 * n33 * n41 - n13 * n32 * n41 + n13 * n31 * n42 - n11 * n33 * n42 - n12 * n31 * n43 + n11 * n32 * n43) * idet;

    ret[2][0] = t13 * idet;
    ret[2][1] = (n14 * n23 * n41 - n13 * n24 * n41 - n14 * n21 * n43 + n11 * n24 * n43 + n13 * n21 * n44 - n11 * n23 * n44) * idet;
    ret[2][2] = (n12 * n24 * n41 - n14 * n22 * n41 + n14 * n21 * n42 - n11 * n24 * n42 - n12 * n21 * n44 + n11 * n22 * n44) * idet;
    ret[2][3] = (n13 * n22 * n41 - n12 * n23 * n41 - n13 * n21 * n42 + n11 * n23 * n42 + n12 * n21 * n43 - n11 * n22 * n43) * idet;

    ret[3][0] = t14 * idet;
    ret[3][1] = (n13 * n24 * n31 - n14 * n23 * n31 + n14 * n21 * n33 - n11 * n24 * n33 - n13 * n21 * n34 + n11 * n23 * n34) * idet;
    ret[3][2] = (n14 * n22 * n31 - n12 * n24 * n31 - n14 * n21 * n32 + n11 * n24 * n32 + n12 * n21 * n34 - n11 * n22 * n34) * idet;
    ret[3][3] = (n12 * n23 * n31 - n13 * n22 * n31 + n13 * n21 * n32 - n11 * n23 * n32 - n12 * n21 * n33 + n11 * n22 * n33) * idet;

    return ret;
}

float3 ScreenUVToWorld(float2 screenUV, float depth)
{
    float near = CameraNear;
    float far = CameraFar;
    float viewZ = (far * near) / (far - depth * (far - near));

    float2 ndc = screenUV * 2.0 - 1.0;
    ndc.y = -ndc.y;

    float3 viewPos;
    viewPos.x = ndc.x * viewZ * ClipToRender[0][0];
    viewPos.y = ndc.y * viewZ * ClipToRender[1][1];
    viewPos.z = viewZ;

    float4 cameraPos = mul(RenderToCamera, float4(viewPos, 1.0));
    float4 worldPos = mul(CameraToWorld, cameraPos);

    return worldPos.xyz / worldPos.w;
}

// World position to screen UV
float2 WorldToScreenUV(float3 worldPos)
{
    float4 cameraPos = mul(WorldToCamera, float4(worldPos, 1.0f));
    float4 renderPos = mul(CameraToRender, cameraPos);
    float4 clipPos = mul(RenderToClip, renderPos);
    
    float2 ndc = clipPos.xy / clipPos.w;
    ndc.y = -ndc.y;
    return ndc * 0.5f + 0.5f;
}

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

float3 SampleSimpleSky(float3 direction, float intensity)
{
    float skyGradient = saturate(direction.y * 0.5f + 0.5f);
    float3 horizonColor = float3(0.3f, 0.4f, 0.5f);
    float3 zenithColor = float3(0.5f, 0.7f, 1.0f);
    return lerp(horizonColor, zenithColor, skyGradient) * intensity;
}

// Octahedron encoding/decoding
float2 DirectionToOctahedronUV(float3 dir)
{
    dir = normalize(dir);
    float3 n = dir / (abs(dir.x) + abs(dir.y) + abs(dir.z));
    
    if (n.z < 0.0f)
    {
        float2 sign_xy = float2(n.x >= 0.0f ? 1.0f : -1.0f, n.y >= 0.0f ? 1.0f : -1.0f);
        n.xy = (1.0f - abs(n.yx)) * sign_xy;
    }
    
    return n.xy * 0.5f + 0.5f;
}

float3 OctahedronUVToDirection(float2 uv)
{
    uv = uv * 2.0f - 1.0f;
    
    float3 n = float3(uv.x, uv.y, 1.0f - abs(uv.x) - abs(uv.y));
    
    if (n.z < 0.0f)
    {
        float2 sign_xy = float2(n.x >= 0.0f ? 1.0f : -1.0f, n.y >= 0.0f ? 1.0f : -1.0f);
        n.xy = (1.0f - abs(n.yx)) * sign_xy;
    }
    
    return normalize(n);
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

float LinearizeDepth(float depth, float near, float far)
{
    return near * far / (far - depth * (far - near));
}

#endif // SCREENPROBE_COMMON_HLSLI
