#define VIZ_FINAL_LIGHTING              0   // Final Lighting (Direct + GI)
#define VIZ_DIRECT_ONLY                 1   // Direct Lighting Only
#define VIZ_INDIRECT_ONLY               2   // Indirect Lighting Only (GI)

#define VIZ_GBUFFER_ALBEDO              3   // GBuffer Albedo
#define VIZ_GBUFFER_NORMAL              4   // GBuffer Normal
#define VIZ_GBUFFER_MATERIAL            5   // GBuffer Material (R=roughness, G=metallic, B=ao)
#define VIZ_GBUFFER_WORLDPOS            6   // GBuffer World Position
#define VIZ_GBUFFER_DEPTH               7   // GBuffer Depth

#define VIZ_SURFCACHE_ALBEDO            8   // Surface Cache Albedo
#define VIZ_SURFCACHE_NORMAL            9   // Surface Cache Normal
#define VIZ_SURFCACHE_DIRECT            10  // Surface Cache Direct Lighting
#define VIZ_SURFCACHE_INDIRECT          11  // Surface Cache Indirect Lighting
#define VIZ_SURFCACHE_FINAL             12  // Surface Cache Final Lighting

#define VIZ_VOXEL_LIGHTING              13  // Scene Voxel Lighting
#define VIZ_RADIOSITY_TRACE             14  // Radiosity Trace Result

#define VIZ_PROBE_RADIANCE              15  // Screen Probe Radiance
#define VIZ_PROBE_AO                    16  // Probe-based AO

#define VIZ_SHADOW_MAP                  17  // Shadow Map
#define VIZ_MESH_SDF_NORMAL             18  // Mesh SDF Normal

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

    uint g_AtlasSize;
    uint g_RadiosityProbeGridWidth;
    uint g_RadiosityProbeGridHeight;
    float g_DirectIntensity;
    
    float g_IndirectIntensity;
    float g_AOStrength;
    float SoftnessFactor;
    float LightSize;     
};

Texture2D<float4> g_GBufferAlbedo    : register(t214);  // Albedo
Texture2D<float4> g_GBufferNormal    : register(t215);  // Normal
Texture2D<float4> g_GBufferMaterial  : register(t216);  // Material (R=roughness, G=metallic, B=ao)
Texture2D<float4> g_GBufferWorldPos  : register(t217);  // World Position
Texture2D<float>  g_DepthBuffer      : register(t218);  // Depth

Texture2DArray<float4> g_SurfaceCacheAtlas : register(t219);

Texture3D<float2> g_GlobalSDF : register(t378);
Texture3D<float4> g_VoxelLighting : register(t379);

Texture2D<float> g_ShadowMap : register(t384);  // SHADOW_MAP_SRV

Texture2D<float4> g_RadiosityTraceResult : register(t393);

Texture2D<float4> g_ProbeRadiance : register(t424);
Texture2D<float4> g_ScreenIndirectLighting : register(t430);

SamplerState g_PointSampler : register(s0);
SamplerState g_LinearSampler : register(s1);
SamplerComparisonState g_ShadowSampler : register(s2);

RWTexture2D<float4> g_Output : register(u432);

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

float3 Heatmap(float t)
{
    t = saturate(t);
    if (t < 0.25) return lerp(float3(0,0,1), float3(0,1,1), t*4.0);
    if (t < 0.5)  return lerp(float3(0,1,1), float3(0,1,0), (t-0.25)*4.0);
    if (t < 0.75) return lerp(float3(0,1,0), float3(1,1,0), (t-0.5)*4.0);
    return lerp(float3(1,1,0), float3(1,0,0), (t-0.75)*4.0);
}

float3 ToneMapACES(float3 color)
{
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return saturate((color * (a * color + b)) / (color * (c * color + d) + e));
}

// PCF Shadow Sampling
float SampleShadowPCF(float3 worldPos, float3 normal)
{
    float4x4 lightViewProj = mul(mul(LightWorldToCamera, LightCameraToRender), LightRenderToClip);
    float4 lightClipPos = mul(lightViewProj, float4(worldPos, 1.0));
    lightClipPos.xyz /= lightClipPos.w;
    
    float2 shadowUV = lightClipPos.xy * 0.5 + 0.5;
    shadowUV.y = 1.0 - shadowUV.y;
    
    if (shadowUV.x < 0 || shadowUV.x > 1 || shadowUV.y < 0 || shadowUV.y > 1)
        return 1.0;
    
    float NdotL = saturate(dot(normal, -SunNormal));
    float bias = max(0.005 * (1.0 - NdotL), 0.001);
    float currentDepth = lightClipPos.z - bias;
    
    // 3x3 PCF
    float shadow = 0.0;
    float texelSize = 1.0 / ShadowMapSize;
    for (int x = -1; x <= 1; x++)
    {
        for (int y = -1; y <= 1; y++)
        {
            shadow += g_ShadowMap.SampleCmpLevelZero(g_ShadowSampler, 
                shadowUV + float2(x, y) * texelSize, currentDepth);
        }
    }
    return shadow / 9.0;
}

float3 CalculateDirectLighting(float3 worldPos, float3 normal, float3 albedo, float shadow)
{
    float NdotL = saturate(dot(normal, -SunNormal));
    float3 sunLight = SunColor.rgb * SunColor.a * NdotL * shadow;
    float3 ambient = AmbientColor * AmbientIntensity;
    return albedo * (sunLight + ambient);
}

uint2 GetProbeAtlasCoord(uint2 pixelCoord)
{
    uint2 probeCoord = pixelCoord / g_ProbeSpacing;
    uint2 localOffset = (pixelCoord % g_ProbeSpacing) * g_OctahedronSize / g_ProbeSpacing;
    return probeCoord * g_OctahedronSize + localOffset;
}

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
    float3 worldPos = g_GBufferWorldPos[pixelCoord].rgb;
    
    switch (g_Mode)
    {
        // Final Output Modes
        case VIZ_FINAL_LIGHTING:
        {
            if (isSky)
            {
                result = float3(0.05, 0.08, 0.15);
            }
            else
            {
                float shadow = SampleShadowPCF(worldPos, worldNormal);
                float3 directLighting = CalculateDirectLighting(worldPos, worldNormal, albedo, shadow);
                directLighting *= g_DirectIntensity;

                // FinalGather already baked albedo, IndirectIntensity, and AO — use directly
                float3 indirectLighting = g_ScreenIndirectLighting[pixelCoord].rgb;

                result = directLighting + indirectLighting;
                result = ToneMapACES(result);
                result = pow(saturate(result), 1.0 / 2.2);
            }
            break;
        }
        
        case VIZ_DIRECT_ONLY:
        {
            if (!isSky)
            {
                float shadow = SampleShadowPCF(worldPos, worldNormal);
                result = CalculateDirectLighting(worldPos, worldNormal, albedo, shadow);
                result *= g_DirectIntensity;
                result = ToneMapACES(result);
                result = pow(saturate(result), 1.0 / 2.2);
            }
            break;
        }
        
        case VIZ_INDIRECT_ONLY:
        {
            if (!isSky)
            {
                // FinalGather already baked albedo, IndirectIntensity, and AO — use directly
                result = g_ScreenIndirectLighting[pixelCoord].rgb;
                result = ToneMapACES(result);
                result = pow(saturate(result), 1.0 / 2.2);
            }
            break;
        }
        
        // GBuffer Modes (5 types)
        case VIZ_GBUFFER_ALBEDO:
        {
            result = albedo;
            break;
        }
        
        case VIZ_GBUFFER_NORMAL:
        {
            result = VisualizeNormal(worldNormal);
            break;
        }
        
        case VIZ_GBUFFER_MATERIAL:
        {
            // R = roughness, G = metallic, B = ao
            result = materialData.rgb;
            break;
        }
        
        case VIZ_GBUFFER_WORLDPOS:
        {
            result = frac(worldPos * 0.01);
            break;
        }
        
        case VIZ_GBUFFER_DEPTH:
        {
            result = Heatmap(depth);
            break;
        }
        
        // Surface Cache Modes (direct atlas display)
        case VIZ_SURFCACHE_ALBEDO:
        {
            uint2 atlasCoord = pixelCoord % g_AtlasSize;
            result = g_SurfaceCacheAtlas.Load(int4(atlasCoord, 0, 0)).rgb;
            break;
        }
        
        case VIZ_SURFCACHE_NORMAL:
        {
            uint2 atlasCoord = pixelCoord % g_AtlasSize;
            float3 n = g_SurfaceCacheAtlas.Load(int4(atlasCoord, 1, 0)).rgb;
            result = VisualizeNormal(n * 2.0 - 1.0);
            break;
        }
        
        case VIZ_SURFCACHE_DIRECT:
        {
            // Layer 3 = DirectLight (from CardCapture SV_Target3)
            uint2 atlasCoord = pixelCoord % g_AtlasSize;
            result = g_SurfaceCacheAtlas.Load(int4(atlasCoord, 3, 0)).rgb;
            break;
        }

        case VIZ_SURFCACHE_INDIRECT:
        {
            // Layer 4 = Indirect Lighting (computed by radiosity pass)
            uint2 atlasCoord = pixelCoord % g_AtlasSize;
            result = g_SurfaceCacheAtlas.Load(int4(atlasCoord, 4, 0)).rgb;
            break;
        }
        
        case VIZ_SURFCACHE_FINAL:
        {
            // Layer 5 = Combined Light (Direct + Indirect)
            uint2 atlasCoord = pixelCoord % g_AtlasSize;
            result = g_SurfaceCacheAtlas.Load(int4(atlasCoord, 5, 0)).rgb;
            break;
        }
        
        // Voxel & Radiosity Modes
        case VIZ_VOXEL_LIGHTING:
        {
            float3 voxelUV = float3(uv, 0.5);
            result = g_VoxelLighting.SampleLevel(g_LinearSampler, voxelUV, 0).rgb;
            break;
        }
        
        case VIZ_RADIOSITY_TRACE:
        {
            uint2 radCoord = pixelCoord % uint2(g_RadiosityProbeGridWidth, g_RadiosityProbeGridHeight);
            result = g_RadiosityTraceResult[radCoord].rgb;
            break;
        }
        
        // Screen Probe Modes
        case VIZ_PROBE_RADIANCE:
        {
            uint2 atlasCoord = GetProbeAtlasCoord(pixelCoord);
            result = g_ProbeRadiance[atlasCoord].rgb;
            break;
        }
        
        case VIZ_PROBE_AO:
        {
            result = float3(0, 1, 0);
            if (!isSky)
            {
                float ao = g_ScreenIndirectLighting[pixelCoord].a;
                result = float3(ao, ao, ao);
            }
            break;
        }
        
        // Other Modes
        case VIZ_SHADOW_MAP:
        {
            float shadowDepth = g_ShadowMap.SampleLevel(g_PointSampler, uv, 0);
            result = float3(shadowDepth, shadowDepth, shadowDepth);
            break;
        }
        
        case VIZ_MESH_SDF_NORMAL:
        {
            float3 sdfUV = float3(uv, 0.5);
            float eps = 0.01;
            float dx = g_GlobalSDF.SampleLevel(g_LinearSampler, sdfUV + float3(eps,0,0), 0).x
                     - g_GlobalSDF.SampleLevel(g_LinearSampler, sdfUV - float3(eps,0,0), 0).x;
            float dy = g_GlobalSDF.SampleLevel(g_LinearSampler, sdfUV + float3(0,eps,0), 0).x
                     - g_GlobalSDF.SampleLevel(g_LinearSampler, sdfUV - float3(0,eps,0), 0).x;
            float dz = g_GlobalSDF.SampleLevel(g_LinearSampler, sdfUV + float3(0,0,eps), 0).x
                     - g_GlobalSDF.SampleLevel(g_LinearSampler, sdfUV - float3(0,0,eps), 0).x;
            float3 sdfNormal = normalize(float3(dx, dy, dz));
            result = VisualizeNormal(sdfNormal);
            break;
        }
        
        default:
        {
            result = albedo;
            break;
        }
    }
    
    result *= g_Exposure;
    g_Output[pixelCoord] = float4(result, 1.0);
}
