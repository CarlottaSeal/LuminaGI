
#define VIZ_FINAL_LIGHTING              0
#define VIZ_DIRECT_ONLY                 1
#define VIZ_INDIRECT_ONLY               2
// 3-7: Surface Cache (VS/PS)
#define VIZ_VOXEL_LIGHTING              8
#define VIZ_RADIOSITY_TRACE             9
#define VIZ_SCREEN_PROBE_BRDF_PDF       10
#define VIZ_SCREEN_PROBE_LIGHTING_PDF   11
#define VIZ_SCREEN_PROBE_MESH_SDF_TRACE 12
#define VIZ_SCREEN_PROBE_RADIANCE_OCT   13
#define VIZ_SCREEN_PROBE_FILTERED       14
#define VIZ_MESH_SDF_NORMAL             15

cbuffer VisualizationCB : register(b0)
{
    float4x4 ClipToRenderTransform;
    float4x4 RenderToCameraTransform;
    float4x4 CameraToWorldTransform;

    float4x4 LightWorldToCamera;
    float4x4 LightCameraToRender;
    float4x4 LightRenderToClip;
    
    float4 SunColor;
    float3 SunNormal;
    float ShadowMapSize;
    
    float3 AmbientColor;
    float AmbientIntensity;
    
    uint g_Mode;
    float g_Exposure;
    uint g_ScreenWidth;
    uint g_ScreenHeight;
    
    uint g_ProbeGridWidth;
    uint g_ProbeGridHeight;
    uint g_ProbeSpacing;
    uint g_OctahedronSize;

    uint g_OctahedronWidth;
    uint g_OctahedronHeight;
    uint g_Padding5;
    uint g_Padding6;

    float g_DirectIntensity;
    float g_IndirectIntensity;
    float g_AOStrength;
    float g_Padding0;
    
    float3 g_VoxelGridMin;
    float g_VoxelSize;
    float3 g_VoxelGridMax;
    uint g_VoxelResolution;
    
    float3 g_GlobalSDFCenter;
    float g_GlobalSDFExtent;
    float3 g_GlobalSDFInvExtent;
    uint g_GlobalSDFResolution;
    
    uint g_RadiosityProbeGridWidth;
    uint g_RadiosityProbeGridHeight;
    uint g_AtlasWidth;
    uint g_AtlasHeight;
};

struct Light
{
    float4 Color;           // rgb = color, a = intensity
    float3 WorldPosition;
    float PADDING;
    float3 SpotForward;
    float Ambience;
    float InnerRadius;
    float OuterRadius;
    float InnerDotThreshold;
    float OuterDotThreshold;
};

cbuffer GeneralLightConstants : register(b4)
{
    float4 g_SunColorAlt;
    float3 g_SunNormalAlt;
    int g_NumLights;
    Light g_LightsArray[15];
};

cbuffer ShadowConstantsB5 : register(b5)
{
    float4x4 SC_LightWorldToCamera;
    float4x4 SC_LightCameraToRender;
    float4x4 SC_LightRenderToClip;
    float SC_ShadowMapSize;
    float SC_ShadowBias;
    float SC_SoftnessFactor;
    float SC_LightSize;
    float3 SC_LightPosition;
    float SC_FarPlane;
    int4 ShadowLightIndices;
    float4 ShadowFarPlanes;
    float PointShadowBias;
    float PointShadowSoftness;
    int NumShadowCastingLights;
    float PLShadowPadding;
};

Texture2D<float4> g_GBufferAlbedo   : register(t214);
Texture2D<float4> g_GBufferNormal   : register(t215);
Texture2D<float4> g_GBufferMaterial : register(t216);
Texture2D<float4> g_GBufferMotion   : register(t217);
Texture2D<float>  g_DepthBuffer     : register(t218);

Texture2D<float> g_ShadowMap : register(t384);
TextureCubeArray<float> g_PointLightShadowMaps : register(t435);

Texture2D<float4> g_ScreenIndirectLighting : register(t430);

// Voxel & SDF
Texture3D<float>  g_GlobalSDF       : register(t378);
Texture3D<float4> g_VoxelLighting   : register(t379);

Texture2D<float4> g_RadiosityTraceResult : register(t393);

// Screen Probe resources
struct SH2CoeffsGPU
{
    float R[4];
    float G[4];
    float B[4];
};
StructuredBuffer<SH2CoeffsGPU> g_ScreenProbeBRDF_PDF    : register(t417);
StructuredBuffer<SH2CoeffsGPU> g_ScreenProbeLightingPDF : register(t418);

// MeshTrace result
struct MeshTraceResult
{
    float3 HitPosition;
    float HitDistance;
    float3 HitNormal;
    float Validity;
    uint HitCardIndex;
    uint Padding0;
    uint Padding1;
    uint Padding2;
};
StructuredBuffer<MeshTraceResult> g_ScreenProbeMeshTrace : register(t422);

Texture2D<float4> g_ScreenProbeRadiance     : register(t424);
Texture2D<float4> g_ScreenProbeFiltered     : register(t426);

// Samplers
SamplerState g_PointSampler : register(s0);
SamplerState g_LinearSampler : register(s1);
SamplerComparisonState g_ShadowSampler : register(s2);

// Output (432)
RWTexture2D<float4> g_Output : register(u0);

//=============================================================================
// Helper Functions
//=============================================================================
float3 ReconstructWorldPosition(float2 uv, float depth)
{
    float4 clipPos = float4(uv * 2.0 - 1.0, depth, 1.0);
    clipPos.y = -clipPos.y;
    
    float4 renderPos = mul(ClipToRenderTransform, clipPos);
    float4 cameraPos = mul(RenderToCameraTransform, renderPos);
    float4 worldPos = mul(CameraToWorldTransform, cameraPos);
    
    return worldPos.xyz / worldPos.w;
}

float3 DecodeNormal(float3 encoded)
{
    return normalize(encoded * 2.0 - 1.0);
}

float3 VisualizeNormal(float3 n)
{
    return n * 0.5 + 0.5;
}

float3 ToneMapACES(float3 color)
{
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return saturate((color * (a * color + b)) / (color * (c * color + d) + e));
}

float3 Heatmap(float t)
{
    t = saturate(t);
    if (t < 0.25) return lerp(float3(0,0,1), float3(0,1,1), t*4.0);
    if (t < 0.5)  return lerp(float3(0,1,1), float3(0,1,0), (t-0.25)*4.0);
    if (t < 0.75) return lerp(float3(0,1,0), float3(1,1,0), (t-0.5)*4.0);
    return lerp(float3(1,1,0), float3(1,0,0), (t-0.75)*4.0);
}

float SampleShadowPCF(float3 worldPos, float3 normal)
{
    float4x4 lightViewProj = mul(LightRenderToClip, mul(LightCameraToRender, LightWorldToCamera));
    float4 lightClipPos = mul(lightViewProj, float4(worldPos, 1.0));
    lightClipPos.xyz /= lightClipPos.w;

    float2 shadowUV = lightClipPos.xy * 0.5 + 0.5;
    shadowUV.y = 1.0 - shadowUV.y;

    if (shadowUV.x < 0 || shadowUV.x > 1 || shadowUV.y < 0 || shadowUV.y > 1)
        return 1.0;

    float receiverDepth = lightClipPos.z;
    float bias = 0.005;
    receiverDepth -= bias;

    return g_ShadowMap.SampleCmpLevelZero(g_ShadowSampler, shadowUV, receiverDepth);
}

float VizRangeMap(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (value - inMin) * (outMax - outMin) / (inMax - inMin);
}

float VizSmoothStep3(float t)
{
    return t * t * (3.0 - 2.0 * t);
}

int GetShadowSlotForLight(int lightIndex)
{
    [unroll]
    for (int s = 0; s < 4; s++)
    {
        if (s >= NumShadowCastingLights) break;
        if (ShadowLightIndices[s] == lightIndex) return s;
    }
    return -1;
}

float SamplePointShadow(int shadowSlot, float3 worldPos, float3 lightPos)
{
    float3 lightToPixel = worldPos - lightPos;
    float currentDist = length(lightToPixel);
    float3 dir = lightToPixel / currentDist;
    float currentDepth = currentDist / ShadowFarPlanes[shadowSlot];

    float3 tangent = normalize(cross(dir, float3(0.0, 1.0, 0.001)));
    float3 bitangent = cross(dir, tangent);

    float diskRadius = PointShadowSoftness;
    float shadow = 0.0;
    const int NUM_SAMPLES = 16;

    static const float2 poissonDisk[16] =
    {
        float2(-0.94201624, -0.39906216), float2(0.94558609, -0.76890725),
        float2(-0.09418410, -0.92938870), float2(0.34495938,  0.29387760),
        float2(-0.91588581,  0.45771432), float2(-0.81544232, -0.87912464),
        float2(-0.38277543,  0.27676845), float2(0.97484398,  0.75648379),
        float2(0.44323325, -0.97511554), float2(0.53742981, -0.47373420),
        float2(-0.26496911, -0.41893023), float2(0.79197514,  0.19090188),
        float2(-0.24188840,  0.99706507), float2(-0.81409955,  0.91437590),
        float2(0.19984126,  0.78641367), float2(0.14383161, -0.14100790)
    };

    [unroll]
    for (int i = 0; i < NUM_SAMPLES; i++)
    {
        float3 offset = (tangent * poissonDisk[i].x + bitangent * poissonDisk[i].y) * diskRadius;
        float3 sampleDir = normalize(dir + offset);
        float stored = g_PointLightShadowMaps.SampleLevel(g_PointSampler, float4(sampleDir, (float)shadowSlot), 0).r;
        shadow += (currentDepth - PointShadowBias > stored) ? 0.0 : 1.0;
    }
    return shadow / (float)NUM_SAMPLES;
}

float3 CalculateDirectLighting(float3 worldPos, float3 normal, float3 albedo, float shadow,
                                float3 viewDir, float roughness, float metallic)
{
    float smoothness = 1.0 - roughness;
    float specPower = pow(2.0, smoothness * 12.0);
    float normFactor = (specPower + 8.0) / 25.132;
    float3 F0 = lerp(float3(0.04, 0.04, 0.04), albedo, metallic);

    float3 totalDiffuse = float3(0, 0, 0);
    float3 totalSpecular = float3(0, 0, 0);

    // === Sun ===
    float3 L = -SunNormal;
    float NdotL_sun = saturate(dot(normal, L));
    float3 sunRadiance = SunColor.rgb * SunColor.a * shadow;
    totalDiffuse += sunRadiance * NdotL_sun;

    float3 H_sun = normalize(L + viewDir);
    float NdotH_sun = saturate(dot(normal, H_sun));
    float VdotH_sun = saturate(dot(viewDir, H_sun));
    float specIntensity_sun = pow(NdotH_sun, specPower) * normFactor * NdotL_sun;
    float3 fresnel_sun = F0 + (1.0 - F0) * pow(1.0 - VdotH_sun, 5.0);
    totalSpecular += fresnel_sun * specIntensity_sun * sunRadiance;

    // === Ambient ===
    totalDiffuse += AmbientColor * AmbientIntensity;

    // === Point/Spot lights ===
    for (int i = 0; i < g_NumLights; i++)
    {
        Light light = g_LightsArray[i];
        float3 lightPos = light.WorldPosition;
        float3 lightColor = light.Color.rgb;
        float lightBrightness = light.Color.a;
        float innerRadius = light.InnerRadius;
        float outerRadius = light.OuterRadius;
        float ambience = light.Ambience;

        float3 pixelToLightDisp = lightPos - worldPos;
        float3 pixelToLightDir = normalize(pixelToLightDisp);
        float3 lightToPixelDir = -pixelToLightDir;
        float distToLight = length(pixelToLightDisp);

        float falloff = saturate(VizRangeMap(distToLight, innerRadius, outerRadius, 1.0, 0.0));
        falloff = VizSmoothStep3(falloff);

        float penumbra = 1.0;
        if (length(light.SpotForward) > 0.01)
        {
            penumbra = saturate(VizRangeMap(
                dot(light.SpotForward, lightToPixelDir),
                light.OuterDotThreshold, light.InnerDotThreshold, 0.0, 1.0));
            penumbra = VizSmoothStep3(penumbra);
        }

        float pointNdotL = saturate(dot(pixelToLightDir, normal));
        float attenuation = penumbra * falloff * lightBrightness;

        float pointShadow = 1.0;
        int shadowSlot = GetShadowSlotForLight(i);
        if (shadowSlot >= 0)
            pointShadow = SamplePointShadow(shadowSlot, worldPos, lightPos);

        float diffuseFactor = saturate(VizRangeMap(dot(pixelToLightDir, normal), -ambience, 1.0, 0.0, 1.0));
        float3 lightRadiance = attenuation * lightColor * pointShadow;
        totalDiffuse += lightRadiance * diffuseFactor;

        if (pointNdotL > 0.001)
        {
            float3 H = normalize(pixelToLightDir + viewDir);
            float NdotH = saturate(dot(normal, H));
            float VdotH = saturate(dot(viewDir, H));
            float specIntensity = pow(NdotH, specPower) * normFactor * pointNdotL;
            float3 fresnel = F0 + (1.0 - F0) * pow(1.0 - VdotH, 5.0);
            totalSpecular += fresnel * specIntensity * lightRadiance;
        }
    }

    float3 diffuseColor = albedo * (1.0 - metallic);
    return diffuseColor * totalDiffuse + totalSpecular;
}

float3 GetSkyColor(float3 viewDir)
{
    float skyFactor = saturate(viewDir.z * 0.5 + 0.5);
    float3 horizonColor = float3(0.02, 0.03, 0.08);
    float3 zenithColor = float3(0.05, 0.08, 0.15);
    return lerp(horizonColor, zenithColor, skyFactor);
}

// Standard octahedron encoding (must match GenerateSampleDirections/ScreenProbeCommon)
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

// SimLumen style probe sampling (same as FinalGather)
float3 GetScreenProbeIrradianceViz(Texture2D<float4> probeTexture, uint2 probeCoord, float2 probeUV)
{
    if (probeCoord.x >= g_ProbeGridWidth || probeCoord.y >= g_ProbeGridHeight)
        return float3(0, 0, 0);

    // 8x16 per probe layout
    uint raysTexWidth = g_ProbeGridWidth * g_OctahedronWidth;
    uint raysTexHeight = g_ProbeGridHeight * g_OctahedronHeight;

    float2 probeSize = float2(g_OctahedronWidth, g_OctahedronHeight);
    float2 subPos = probeUV * (probeSize - 1.0f) + 1.0f;
    float2 texelUV = (float2(probeCoord) * probeSize + subPos) / float2(raysTexWidth, raysTexHeight);

    float3 result = probeTexture.SampleLevel(g_LinearSampler, texelUV, 0).rgb;

    float lum = max(max(result.r, result.g), result.b);
    const float MAX_LUM = 2.0f;
    if (lum > MAX_LUM)
        result *= MAX_LUM / lum;

    return result;
}

// FinalGather style: 5-probe averaging with material processing
float3 ComputeFinalGatherStyle(Texture2D<float4> probeTexture, uint2 pixelCoord, float3 worldNormal, float3 albedo, float metallic)
{
    float2 probeUV = DirectionToOctahedronUV(worldNormal);
    uint2 probeCoord = pixelCoord / g_ProbeSpacing;

    int2 offsets[5] = {
        int2(0, 0),
        int2(0, 1),
        int2(0, -1),
        int2(1, 0),
        int2(-1, 0),
    };

    float3 totalRadiance = float3(0, 0, 0);
    float validCount = 0.0f;

    [unroll]
    for (uint i = 0; i < 5; i++)
    {
        int2 pc = int2(probeCoord) + offsets[i];

        if (pc.x >= 0 && pc.x < (int)g_ProbeGridWidth &&
            pc.y >= 0 && pc.y < (int)g_ProbeGridHeight)
        {
            float3 probeRad = GetScreenProbeIrradianceViz(probeTexture, uint2(pc), probeUV);
            totalRadiance += probeRad;
            validCount += 1.0f;
        }
    }

    float3 diffuseIrradiance = float3(0, 0, 0);
    if (validCount > 0.5f)
    {
        diffuseIrradiance = totalRadiance / validCount / 3.14159265359f;
    }

    // SimLumen: c_diff = albedo * (1 - metallic)
    float3 c_diff = albedo * (1.0f - metallic);
    float3 indirectLight = c_diff * diffuseIrradiance * g_IndirectIntensity;

    float indirectLum = max(max(indirectLight.r, indirectLight.g), indirectLight.b);
    const float MAX_INDIRECT = 1.0f;
    if (indirectLum > MAX_INDIRECT)
        indirectLight *= MAX_INDIRECT / indirectLum;

    if (any(isnan(indirectLight)) || any(isinf(indirectLight)))
        indirectLight = float3(0, 0, 0);

    return indirectLight;
}

uint2 GetProbeAtlasCoord(uint2 pixelCoord)
{
    uint2 probeCoord = pixelCoord / g_ProbeSpacing;
    probeCoord = min(probeCoord, uint2(g_ProbeGridWidth - 1, g_ProbeGridHeight - 1));
    // 8x16 per probe layout
    uint2 probeSize = uint2(g_OctahedronWidth, g_OctahedronHeight);
    uint2 localOffset = (pixelCoord % g_ProbeSpacing) * probeSize / g_ProbeSpacing;
    return probeCoord * probeSize + localOffset;
}

// SDF sampling
float3 WorldToSdfUV(float3 worldPos)
{
    float3 sdfMin = g_GlobalSDFCenter - float3(g_GlobalSDFExtent, g_GlobalSDFExtent, g_GlobalSDFExtent);
    float3 sdfMax = g_GlobalSDFCenter + float3(g_GlobalSDFExtent, g_GlobalSDFExtent, g_GlobalSDFExtent);
    return (worldPos - sdfMin) / (sdfMax - sdfMin);
}

float SampleSDF(float3 worldPos)
{
    float3 sdfUV = WorldToSdfUV(worldPos);
    if (any(sdfUV < 0.0) || any(sdfUV > 1.0))
        return 1000.0;
    return g_GlobalSDF.SampleLevel(g_LinearSampler, sdfUV, 0);
}

float3 CalculateSDFNormal(float3 worldPos)
{
    uint resolution = max(g_GlobalSDFResolution, 64u);
    float eps = g_GlobalSDFExtent / float(resolution) * 2.0;
    eps = max(eps, 0.01);

    float dx = SampleSDF(worldPos + float3(eps, 0, 0)) - SampleSDF(worldPos - float3(eps, 0, 0));
    float dy = SampleSDF(worldPos + float3(0, eps, 0)) - SampleSDF(worldPos - float3(0, eps, 0));
    float dz = SampleSDF(worldPos + float3(0, 0, eps)) - SampleSDF(worldPos - float3(0, 0, eps));
    
    float3 gradient = float3(dx, dy, dz);
    float len = length(gradient);
    
    if (len < 0.0001)
        return float3(0, 1, 0);
    
    return gradient / len;
}

float3 GetCameraPosition()
{
    return float3(CameraToWorldTransform[0][3], CameraToWorldTransform[1][3], CameraToWorldTransform[2][3]);
}

float3 GetViewRayDirection(float2 uv)
{
    float4 clipNear = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    float4 clipFar = float4(uv * 2.0 - 1.0, 1.0, 1.0);
    clipNear.y = -clipNear.y;
    clipFar.y = -clipFar.y;
    float4 renderNear = mul(ClipToRenderTransform, clipNear);
    float4 cameraNear = mul(RenderToCameraTransform, renderNear);
    float4 worldNear = mul(CameraToWorldTransform, cameraNear);
    worldNear /= worldNear.w;
    
    float4 renderFar = mul(ClipToRenderTransform, clipFar);
    float4 cameraFar = mul(RenderToCameraTransform, renderFar);
    float4 worldFar = mul(CameraToWorldTransform, cameraFar);
    worldFar /= worldFar.w;
    
    return normalize(worldFar.xyz - worldNear.xyz);
}

// SimLumen style: Ray March Global SDF
bool TraceGlobalSDF(float3 rayOrigin, float3 rayDir, float maxDist, out float hitDist, out float3 hitNormal)
{
    hitDist = maxDist;
    hitNormal = float3(0, 0, 1);
    
    uint resolution = max(g_GlobalSDFResolution, 64u);
    float voxelSize = g_GlobalSDFExtent * 2.0 / float(resolution);
    float hitThreshold = voxelSize * 0.5;
    float minStep = voxelSize * 0.25;
    
    float t = 0.0;
    
    for (uint step = 0; step < 128; step++)
    {
        if (t > maxDist)
            break;
            
        float3 pos = rayOrigin + rayDir * t;
        float dist = SampleSDF(pos);
        
        if (dist > 100.0)
        {
            t += voxelSize * 4.0;
            continue;
        }
        
        if (dist < hitThreshold)
        {
            hitDist = t;
            hitNormal = CalculateSDFNormal(pos);
            return true;
        }
        
        t += max(dist, minStep);
    }
    
    return false;
}

// SimLumen style normal coloring
float3 SimLumenNormalColor(float3 n)
{
    if (n.x > 0.5)
        return float3(1.0, 0.0, 0.0);      // +X
    else if (n.x < -0.5)
        return float3(0.2, 0.0, 0.0);      // -X
    else if (n.y > 0.5)
        return float3(0.0, 1.0, 0.0);      // +Y
    else if (n.y < -0.5)
        return float3(0.0, 0.2, 0.0);      // -Y
    else if (n.z > 0.5)
        return float3(0.0, 0.0, 1.0);      // +Z
    else if (n.z < -0.5)
        return float3(0.0, 0.0, 0.2);      // -Z
    else
        return normalize(n) * 0.5 + 0.5;
}

float3 NormalToColor(float3 n)
{
    float3 absN = abs(n);
    if (absN.x > absN.y && absN.x > absN.z)
        return n.x > 0 ? float3(1.0, 0.2, 0.2) : float3(0.5, 0.1, 0.1);
    else if (absN.y > absN.z)
        return n.y > 0 ? float3(0.2, 1.0, 0.2) : float3(0.1, 0.5, 0.1);
    else
        return n.z > 0 ? float3(0.2, 0.2, 1.0) : float3(0.1, 0.1, 0.5);
}

// SH2 (L0 + L1) evaluation - 4 coefficients
// Y1-1 = 0.488603 * y
// Y10 = 0.488603 * z
// Y11 = 0.488603 * x
float EvaluateSH2(float coeffs[4], float3 dir)
{
    const float Y00 = 0.282095f;
    const float Y1x = 0.488603f;

    return coeffs[0] * Y00 +
           coeffs[1] * Y1x * dir.y +
           coeffs[2] * Y1x * dir.z +
           coeffs[3] * Y1x * dir.x;
}

float3 EvaluateSH2RGB(SH2CoeffsGPU sh, float3 dir)
{
    return float3(
        EvaluateSH2(sh.R, dir),
        EvaluateSH2(sh.G, dir),
        EvaluateSH2(sh.B, dir)
    );
}

float GetSH2Energy(float coeffs[4])
{
    return abs(coeffs[0]) + (abs(coeffs[1]) + abs(coeffs[2]) + abs(coeffs[3])) * 0.5f;
}

//=============================================================================
// Main
//=============================================================================
[numthreads(8, 8, 1)]
void CSMain(uint3 dispatchID : SV_DispatchThreadID)
{
    uint2 pixelCoord = dispatchID.xy;
    if (pixelCoord.x >= g_ScreenWidth || pixelCoord.y >= g_ScreenHeight)
        return;
    
    float2 uv = (float2(pixelCoord) + 0.5) / float2(g_ScreenWidth, g_ScreenHeight);
    float depth = g_DepthBuffer[pixelCoord];
    
    float3 result = float3(0, 0, 0);
    bool isSky = (depth >= 0.9999);
    
    float3 albedo = g_GBufferAlbedo[pixelCoord].rgb;
    float3 worldNormal = DecodeNormal(g_GBufferNormal[pixelCoord].rgb);
    float4 materialData = g_GBufferMaterial[pixelCoord];
    float roughness = materialData.r;
    float metallic = materialData.g;
    float ao = materialData.b;
    float3 worldPos = ReconstructWorldPosition(uv, depth);

    float3 cameraPos = GetCameraPosition();
    float3 viewDir = normalize(cameraPos - worldPos);
    
    switch (g_Mode)
    {
        //=================================================================
        // Output Modes (0-2)
        //=================================================================
        case VIZ_FINAL_LIGHTING:
        {
            if (isSky)
            {
                result = float3(0, 0, 0);
            }
            else
            {
                float shadow = SampleShadowPCF(worldPos, worldNormal);
                float3 directLighting = CalculateDirectLighting(worldPos, worldNormal, albedo, shadow,
                                                                 viewDir, roughness, metallic);
                directLighting *= g_DirectIntensity;

                float3 indirectLighting = g_ScreenIndirectLighting[pixelCoord].rgb;

                result = directLighting + indirectLighting;
                result = ToneMapACES(result);
                result = pow(saturate(result), 1.0 / 2.2);
            }
            break;
        }
        
        case VIZ_DIRECT_ONLY:
        {
            if (isSky)
            {
                result = float3(0, 0, 0);
            }
            else
            {
                float shadow = SampleShadowPCF(worldPos, worldNormal);
                result = CalculateDirectLighting(worldPos, worldNormal, albedo, shadow,
                                                  viewDir, roughness, metallic);
                result *= g_DirectIntensity;
                result = ToneMapACES(result);
                result = pow(saturate(result), 1.0 / 2.2);
            }
            break;
        }
        
        case VIZ_INDIRECT_ONLY:
        {
            if (isSky)
            {
                result = float3(0, 0, 0);
            }
            else
            {
                float3 indirectLighting = g_ScreenIndirectLighting[pixelCoord].rgb;
                result = indirectLighting;
                result = ToneMapACES(result);
                result = pow(saturate(result), 1.0 / 2.2);
            }
            break;
        }
        
        //=================================================================
        // Voxel Lighting (8)
        //=================================================================
        case VIZ_VOXEL_LIGHTING:
        {
            if (isSky)
            {
                result = float3(0, 0, 0);
                break;
            }

            float3 voxelMin = g_VoxelGridMin;
            float3 voxelMax = g_VoxelGridMax;
            float3 gridSize = voxelMax - voxelMin;

            if (length(gridSize) < 1.0)
            {
                voxelMin = g_GlobalSDFCenter - g_GlobalSDFExtent;
                voxelMax = g_GlobalSDFCenter + g_GlobalSDFExtent;
                gridSize = voxelMax - voxelMin;
            }

            float3 voxelUV = (worldPos - voxelMin) / gridSize;

            if (all(voxelUV >= 0.0) && all(voxelUV <= 1.0))
            {
                float4 voxelData = g_VoxelLighting.SampleLevel(g_LinearSampler, voxelUV, 0);
                result = voxelData.rgb;

                result = ToneMapACES(result);
                result = pow(saturate(result), 1.0 / 2.2);
            }
            else
            {
                result = float3(0.15, 0.0, 0.0);
            }
            break;
        }
        
        //=================================================================
        // Radiosity Trace Result (9)
        //=================================================================
        case VIZ_RADIOSITY_TRACE:
        {
            if (isSky)
            {
                result = float3(0, 0, 0);
                break;
            }

            uint probeGridW = g_RadiosityProbeGridWidth;
            uint probeGridH = g_RadiosityProbeGridHeight;

            if (probeGridW == 0) probeGridW = 1024;
            if (probeGridH == 0) probeGridH = 1024;

            float2 probeUV = float2(pixelCoord) / float2(g_ScreenWidth, g_ScreenHeight);
            uint2 probeCoord = uint2(probeUV * float2(probeGridW, probeGridH));
            probeCoord = min(probeCoord, uint2(probeGridW - 1, probeGridH - 1));

            float4 radData = g_RadiosityTraceResult.Load(int3(probeCoord, 0));

            if (radData.w > 0.01f)
            {
                result = radData.rgb;
                result = ToneMapACES(result);
                result = pow(saturate(result), 1.0 / 2.2);
            }
            else if (length(radData.rgb) > 0.001f)
            {
                result = radData.rgb * 0.5;
                result = ToneMapACES(result);
                result = pow(saturate(result), 1.0 / 2.2);
            }
            else
            {
                result = float3(0, 0, 0);
            }
            break;
        }

        //=================================================================
        // Screen Probe Modes (10-14)
        //=================================================================
        case VIZ_SCREEN_PROBE_BRDF_PDF:
        {
            if (isSky)
            {
                result = float3(0.0, 0.0, 0.0);
            }
            else
            {
                uint2 probeCoord = pixelCoord / g_ProbeSpacing;
                probeCoord = min(probeCoord, uint2(g_ProbeGridWidth - 1, g_ProbeGridHeight - 1));
                uint probeIndex = probeCoord.y * g_ProbeGridWidth + probeCoord.x;

                SH2CoeffsGPU brdfSH = g_ScreenProbeBRDF_PDF[probeIndex];

                float energy = GetSH2Energy(brdfSH.R) + GetSH2Energy(brdfSH.G) + GetSH2Energy(brdfSH.B);
                energy /= 3.0f;

                if (energy > 0.001f)
                {
                    float3 evalDir = worldNormal;
                    float3 shValue = EvaluateSH2RGB(brdfSH, evalDir);

                    float heatValue = saturate(energy * 2.0f);
                    float3 heatColor = Heatmap(heatValue);

                    result = heatColor * max(0.3f, saturate(length(shValue)));
                }
                else
                {
                    result = float3(0.05, 0.05, 0.05);
                }
            }
            break;
        }
        
        case VIZ_SCREEN_PROBE_LIGHTING_PDF:
        {
            if (isSky)
            {
                result = float3(0.0, 0.0, 0.0);
            }
            else
            {
                uint2 probeCoord = pixelCoord / g_ProbeSpacing;
                probeCoord = min(probeCoord, uint2(g_ProbeGridWidth - 1, g_ProbeGridHeight - 1));
                uint probeIndex = probeCoord.y * g_ProbeGridWidth + probeCoord.x;

                SH2CoeffsGPU lightingSH = g_ScreenProbeLightingPDF[probeIndex];

                float energy = GetSH2Energy(lightingSH.R) + GetSH2Energy(lightingSH.G) + GetSH2Energy(lightingSH.B);
                energy /= 3.0f;

                if (energy > 0.001f)
                {
                    float3 evalDir = -normalize(SunNormal);
                    float3 shValue = EvaluateSH2RGB(lightingSH, evalDir);

                    float heatValue = saturate(energy * 2.0f);
                    float3 heatColor = Heatmap(heatValue);

                    float3 lightingValue = max(float3(0, 0, 0), shValue);
                    result = lerp(heatColor, lightingValue, 0.5f);
                }
                else
                {
                    result = float3(0.05, 0.05, 0.05);
                }
            }
            break;
        }
        
        case VIZ_SCREEN_PROBE_MESH_SDF_TRACE:
        {
            if (isSky)
            {
                result = float3(0, 0, 0);
                break;
            }

            uint2 probeCoord = pixelCoord / g_ProbeSpacing;
            probeCoord = min(probeCoord, uint2(g_ProbeGridWidth - 1, g_ProbeGridHeight - 1));
            uint probeIndex = probeCoord.y * g_ProbeGridWidth + probeCoord.x;

            uint hitCount = 0;
            float avgDistance = 0;
            float3 avgNormal = float3(0, 0, 0);
            float minDistance = 10000.0;

            const uint raysPerProbe = 64;
            const float meshTraceMaxDist = 100.0;

            [loop]
            for (uint i = 0; i < raysPerProbe; i++)
            {
                uint sampleIndex = probeIndex * raysPerProbe + i;
                MeshTraceResult tr = g_ScreenProbeMeshTrace[sampleIndex];

                if (tr.Validity > 0.5)
                {
                    hitCount++;
                    avgDistance += tr.HitDistance;
                    avgNormal += tr.HitNormal;
                    minDistance = min(minDistance, tr.HitDistance);
                }
            }

            if (hitCount > 0)
            {
                avgDistance /= float(hitCount);
                avgNormal = normalize(avgNormal);

                float hitRate = float(hitCount) / float(raysPerProbe);
                float normalizedDist = saturate(avgDistance / meshTraceMaxDist);

                float3 normalColor = SimLumenNormalColor(avgNormal);
                float3 distColor = Heatmap(1.0 - normalizedDist);

                result = normalColor * 0.7 + distColor * 0.3;
                result *= (0.4 + hitRate * 0.6);

                if (hitRate < 0.15)
                {
                    result = lerp(result, float3(0.4, 0.0, 0.4), 0.5);
                }
            }
            else
            {
                result = float3(0, 0, 0);
            }
            break;
        }
        
        case VIZ_SCREEN_PROBE_RADIANCE_OCT:
        {
            // Raw probe radiance texture (same layout as PIX)
            float3 raw = g_ScreenProbeRadiance[pixelCoord].rgb;
            result = ToneMapACES(raw);
            result = pow(saturate(result), 1.0 / 2.2);
            break;
        }

        case VIZ_SCREEN_PROBE_FILTERED:
        {
            if (isSky)
            {
                result = float3(0, 0, 0);
                break;
            }
            // FinalGather style: 5-probe average + c_diff + IndirectIntensity
            result = ComputeFinalGatherStyle(g_ScreenProbeFiltered, pixelCoord, worldNormal, albedo, metallic);
            result = ToneMapACES(result);
            result = pow(saturate(result), 1.0 / 2.2);
            break;
        }
        
        //=================================================================
        // Mesh SDF Normal (15)
        //=================================================================
        case VIZ_MESH_SDF_NORMAL:
        {
            if (isSky)
            {
                result = float3(0, 0, 0);
            }
            else
            {
                float3 sdfMin = g_GlobalSDFCenter - float3(g_GlobalSDFExtent, g_GlobalSDFExtent, g_GlobalSDFExtent);
                float3 sdfMax = g_GlobalSDFCenter + float3(g_GlobalSDFExtent, g_GlobalSDFExtent, g_GlobalSDFExtent);
                
                if (all(worldPos >= sdfMin) && all(worldPos <= sdfMax))
                {
                    float3 n = CalculateSDFNormal(worldPos);
                    result = SimLumenNormalColor(n);
                }
                else
                {
                    result = float3(0, 0, 0);
                }
            }
            break;
        }
        
        default:
            result = float3(1, 0, 1);  // Magenta = unknown mode
            break;
    }
    
    result *= g_Exposure;
    g_Output[pixelCoord] = float4(result, 1.0);
}
