//=============================================================================
// ShadowCommon.hlsli
// Shadow system common definitions and configuration
//=============================================================================

#ifndef SHADOW_COMMON_HLSLI
#define SHADOW_COMMON_HLSLI

//-----------------------------------------------------------------------------
// Configuration parameters
//-----------------------------------------------------------------------------

// Shadow map resolution
#ifndef SHADOW_MAP_SIZE
#define SHADOW_MAP_SIZE 4096
#endif

// PCF kernel size (3=3x3, 5=5x5, 7=7x7)
#ifndef PCF_KERNEL_SIZE
#define PCF_KERNEL_SIZE 5
#endif

// Base depth bias (prevents shadow acne)
#ifndef SHADOW_BIAS
#define SHADOW_BIAS 0.005f
#endif

// Slope-scale bias (larger for glancing surfaces)
#ifndef SLOPE_BIAS
#define SLOPE_BIAS 0.01f
#endif

// Maximum bias clamp
#ifndef MAX_SHADOW_BIAS
#define MAX_SHADOW_BIAS 0.05f
#endif

// Normal offset (prevents light leaking)
#ifndef NORMAL_OFFSET
#define NORMAL_OFFSET 0.05f  // Increased from 0.02 to reduce light leaking
#endif

// Soft shadow penumbra size (light source simulation)
#ifndef PENUMBRA_SIZE
#define PENUMBRA_SIZE 1.0f
#endif

// Cascade count
#ifndef CASCADE_COUNT
#define CASCADE_COUNT 4
#endif

//-----------------------------------------------------------------------------
// Constant buffer definitions
//-----------------------------------------------------------------------------

// Single-light shadow constants
struct ShadowConstants
{
    float4x4 LightViewProj;      // Light view-projection matrix
    float4x4 LightView;          // Light view matrix
    float4x4 LightProj;          // Light projection matrix
    float ShadowMapSize;         // Shadow map resolution
    float ShadowBias;            // Depth bias
    float SoftnessFactor;        // Softness factor
    float LightSize;             // Light size (for PCSS)
};

// CSM constants
struct CSMConstants
{
    float4x4 CascadeViewProj[CASCADE_COUNT];  // Per-cascade view-projection
    float4 CascadeSplits;                      // Split depths (x,y,z,w)
    float4 CascadeScales[CASCADE_COUNT];       // Per-cascade scale
    float4 CascadeOffsets[CASCADE_COUNT];      // Per-cascade offset
    float ShadowMapSize;
    float ShadowBias;
    float2 Padding;
};

//-----------------------------------------------------------------------------
// Samplers (must be declared in the including shader)
//-----------------------------------------------------------------------------

// The following samplers must be declared in the including shader:
// SamplerComparisonState g_ShadowSampler : register(s1);
// SamplerState g_PointSampler : register(s0);

//-----------------------------------------------------------------------------
// Helper functions
//-----------------------------------------------------------------------------

// Compute adaptive depth bias
float CalculateAdaptiveBias(float NdotL, float baseDepth)
{
    // More bias for glancing surfaces (smaller NdotL)
    float slopeBias = SLOPE_BIAS * sqrt(1.0f - NdotL * NdotL) / max(NdotL, 0.001f);
    float bias = SHADOW_BIAS + slopeBias;
    
    // Scale with depth (distant surfaces need larger bias)
    bias *= (1.0f + baseDepth * 0.5f);
    
    return min(bias, MAX_SHADOW_BIAS);
}

// Apply normal offset (prevents light leaking)
float3 ApplyNormalOffset(float3 worldPos, float3 worldNormal, float NdotL)
{
    float offsetScale = NORMAL_OFFSET;
    
    // More aggressive offset at grazing angles
    // As NdotL approaches 0 (near-perpendicular surface), bias increases significantly
    float grazingFactor = 1.0f - saturate(NdotL);
    offsetScale *= (1.0f + grazingFactor * 3.0f);  // Up to 4x increase
    
    // Push away from surface along normal
    return worldPos + worldNormal * offsetScale;
}

// Apply normal + light direction dual offset (prevents all light leaking)
float3 ApplyNormalOffsetWithLightDir(float3 worldPos, float3 worldNormal, float3 lightDir, float NdotL)
{
    float offsetScale = NORMAL_OFFSET;
    
    // 1. Normal direction offset
    float grazingFactor = 1.0f - saturate(NdotL);
    float normalOffset = offsetScale * (1.0f + grazingFactor * 3.0f);
    
    // 2. Additional light direction offset (effective for walls)
    float lightDirOffset = offsetScale * 0.5f * grazingFactor;
    
    // Combine both offsets
    return worldPos + worldNormal * normalOffset + lightDir * lightDirOffset;
}

// World position to shadow UV (with normal offset)
float3 WorldToShadowUV(float3 worldPos, float3 worldNormal, float NdotL, float4x4 lightViewProj)
{
    // Apply normal offset first
    float3 offsetWorldPos = ApplyNormalOffset(worldPos, worldNormal, NdotL);
    
    // Column-vector form mul(matrix, vector) — matches Shadow.hlsl convention
    float4 lightSpacePos = mul(lightViewProj, float4(offsetWorldPos, 1.0f));
    lightSpacePos.xyz /= lightSpacePos.w;
    
    float2 shadowUV = lightSpacePos.xy * 0.5f + 0.5f;
    shadowUV.y = 1.0f - shadowUV.y;  // Flip Y (DX coordinate system)
    
    return float3(shadowUV, lightSpacePos.z);
}

// World position to shadow UV (dual offset — normal + light direction)
float3 WorldToShadowUVWithLightDir(float3 worldPos, float3 worldNormal, float3 lightDir, float NdotL, float4x4 lightViewProj)
{
    // Apply dual offset
    float3 offsetWorldPos = ApplyNormalOffsetWithLightDir(worldPos, worldNormal, lightDir, NdotL);
    
    float4 lightSpacePos = mul(lightViewProj, float4(offsetWorldPos, 1.0f));
    lightSpacePos.xyz /= lightSpacePos.w;
    
    float2 shadowUV = lightSpacePos.xy * 0.5f + 0.5f;
    shadowUV.y = 1.0f - shadowUV.y;
    
    return float3(shadowUV, lightSpacePos.z);
}

// World position to shadow UV (no offset, legacy compatibility)
float3 WorldToShadowUV(float3 worldPos, float4x4 lightViewProj)
{
    // Column-vector form mul(matrix, vector) — matches Shadow.hlsl convention
    float4 lightSpacePos = mul(lightViewProj, float4(worldPos, 1.0f));
    lightSpacePos.xyz /= lightSpacePos.w;
    
    float2 shadowUV = lightSpacePos.xy * 0.5f + 0.5f;
    shadowUV.y = 1.0f - shadowUV.y;  // Flip Y (DX coordinate system)
    
    return float3(shadowUV, lightSpacePos.z);
}

// Check if UV is within valid range
bool IsValidShadowUV(float2 uv)
{
    return all(uv >= 0.0f) && all(uv <= 1.0f);
}

// Edge fade (avoids hard cutoff at shadow map edges)
float ShadowEdgeFade(float2 uv)
{
    float2 fade = saturate((0.5f - abs(uv - 0.5f)) * 10.0f);
    return fade.x * fade.y;
}

//-----------------------------------------------------------------------------
// Poisson Disk samples (for high-quality PCF/PCSS)
//-----------------------------------------------------------------------------

static const float2 PoissonDisk16[16] = 
{
    float2(-0.94201624f, -0.39906216f),
    float2(0.94558609f, -0.76890725f),
    float2(-0.09418410f, -0.92938870f),
    float2(0.34495938f,  0.29387760f),
    float2(-0.91588581f,  0.45771432f),
    float2(-0.81544232f, -0.87912464f),
    float2(-0.38277543f,  0.27676845f),
    float2(0.97484398f,  0.75648379f),
    float2(0.44323325f, -0.97511554f),
    float2(0.53742981f, -0.47373420f),
    float2(-0.26496911f, -0.41893023f),
    float2(0.79197514f,  0.19090188f),
    float2(-0.24188840f,  0.99706507f),
    float2(-0.81409955f,  0.91437590f),
    float2(0.19984126f,  0.78641367f),
    float2(0.14383161f, -0.14100790f)
};

static const float2 PoissonDisk32[32] = 
{
    float2(-0.975402f, -0.0711386f),
    float2(-0.920347f, -0.41142f),
    float2(-0.883908f, 0.217872f),
    float2(-0.884518f, 0.568041f),
    float2(-0.811945f, 0.90521f),
    float2(-0.792474f, -0.779962f),
    float2(-0.614856f, 0.386578f),
    float2(-0.580859f, -0.208777f),
    float2(-0.53795f, 0.716666f),
    float2(-0.515427f, 0.0899991f),
    float2(-0.454634f, -0.707938f),
    float2(-0.420942f, -0.418699f),
    float2(-0.31657f, -0.949413f),
    float2(-0.274946f, 0.41893f),
    float2(-0.239518f, -0.107773f),
    float2(-0.215309f, 0.789183f),
    float2(-0.152287f, -0.542021f),
    float2(-0.0307879f, 0.0875881f),
    float2(-0.0270295f, -0.850922f),
    float2(0.0225632f, 0.530593f),
    float2(0.0932482f, -0.259661f),
    float2(0.180892f, -0.615657f),
    float2(0.235709f, 0.893421f),
    float2(0.262908f, 0.263953f),
    float2(0.316597f, -0.945052f),
    float2(0.395019f, -0.310498f),
    float2(0.469718f, 0.576879f),
    float2(0.545636f, -0.667946f),
    float2(0.622693f, 0.175629f),
    float2(0.751933f, 0.682416f),
    float2(0.790721f, -0.379812f),
    float2(0.941635f, 0.195766f)
};

//-----------------------------------------------------------------------------
// Random rotation (for sample jitter)
//-----------------------------------------------------------------------------

// Screen-position-based pseudo-random rotation angle
float GetRandomRotation(float2 screenPos)
{
    return frac(sin(dot(screenPos, float2(12.9898f, 78.233f))) * 43758.5453f) * 6.283185f;
}

// Rotate 2D vector
float2 RotateVector(float2 v, float angle)
{
    float s = sin(angle);
    float c = cos(angle);
    return float2(v.x * c - v.y * s, v.x * s + v.y * c);
}

//-----------------------------------------------------------------------------
// Point Light Cube Shadow Map Sampling
//-----------------------------------------------------------------------------

// Find which shadow slot a given general light ID occupies (-1 if none)
int GetShadowSlotForLight(int lightIndex, int4 shadowLightIndices, int numShadowLights)
{
    [unroll]
    for (int s = 0; s < 4; s++)
    {
        if (s >= numShadowLights) break;
        if (shadowLightIndices[s] == lightIndex) return s;
    }
    return -1;
}

// Hard shadow sampling from point light cube shadow map
float SamplePointLightShadowHard(
    TextureCubeArray<float> cubeArray,
    SamplerState pointSampler,
    int shadowSlot,
    float3 worldPos,
    float3 lightPos,
    float farPlane,
    float bias)
{
    float3 lightToPixel = worldPos - lightPos;
    float currentDist = length(lightToPixel);
    float3 dir = lightToPixel / currentDist;
    float currentDepth = currentDist / farPlane;

    float storedDepth = cubeArray.SampleLevel(pointSampler, float4(dir, (float)shadowSlot), 0).r;
    return (currentDepth - bias > storedDepth) ? 0.0 : 1.0;
}

// PCF shadow sampling from point light cube shadow map (20-sample Poisson disk)
float SamplePointLightShadowPCF(
    TextureCubeArray<float> cubeArray,
    SamplerState pointSampler,
    int shadowSlot,
    float3 worldPos,
    float3 lightPos,
    float farPlane,
    float bias,
    float softness)
{
    float3 lightToPixel = worldPos - lightPos;
    float currentDist = length(lightToPixel);
    float3 dir = lightToPixel / currentDist;
    float currentDepth = currentDist / farPlane;

    // Build tangent frame perpendicular to sample direction
    float3 tangent = normalize(cross(dir, float3(0.0, 1.0, 0.001)));
    float3 bitangent = cross(dir, tangent);

    float diskRadius = softness;

    float shadow = 0.0;
    // 20-sample Poisson disk (reusing first 16 + 4 from PoissonDisk32)
    static const int NUM_SAMPLES = 16;
    [unroll]
    for (int i = 0; i < NUM_SAMPLES; i++)
    {
        float3 offset = (tangent * PoissonDisk16[i].x + bitangent * PoissonDisk16[i].y) * diskRadius;
        float3 sampleDir = normalize(dir + offset);
        float stored = cubeArray.SampleLevel(pointSampler, float4(sampleDir, (float)shadowSlot), 0).r;
        shadow += (currentDepth - bias > stored) ? 0.0 : 1.0;
    }
    return shadow / (float)NUM_SAMPLES;
}

#endif // SHADOW_COMMON_HLSLI
