#include "ShadowPCF.hlsli"

// 设置为 1 启用 SDF 阴影（需要绑定 GlobalSDF 到 t378）
// 暂时禁用 - SDF 阴影有问题需要单独调试
#define ENABLE_SDF_SHADOW 0

#if ENABLE_SDF_SHADOW
#include "SDFShadow.hlsli"
#endif

cbuffer CameraConstants : register(b1)
{
    float4x4 WorldToCameraTransform;
    float4x4 CameraToRenderTransform;
    float4x4 RenderToClipTransform;
    float3 CameraWorldPosition;
    float CameraPadding;
};

cbuffer CompositeConstants : register(b12)
{
    float4x4 ClipToRenderTransform;
    float4x4 RenderToCameraTransform;
    float4x4 CameraToWorldTransform;

    float ScreenWidth;
    float ScreenHeight;
    float IndirectIntensity;
    float DirectIntensity;

    float4 SunColor;  // xyz = color, w = intensity

    float3 SunNormal;
    float AmbientIntensity;

    float3 AmbientColor;
    float ShadowBias;

    float4x4 LightWorldToCamera;
    float4x4 LightCameraToRender;
    float4x4 LightRenderToClip;

    float ShadowMapSize;
    float AOStrength;
    float SoftnessFactor;
    float LightSize;

#if ENABLE_SDF_SHADOW
    // SDF Shadow 参数（启用 SDF 阴影时需要 C++ 端也添加这些字段）
    float3 SDFCenter;
    float SDFExtent;
    float SDFShadowSoftness;  // 默认 8.0
    float UseSDFShadow;       // 0 = 关闭, 1 = 开启
    float2 SDFPadding;
#endif
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
    float4 SunColorAlt;
    float3 SunNormalAlt;
    int NumLights;
    Light LightsArray[15];
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
    // Point light cube shadow
    float3 SC_LightPosition;
    float SC_FarPlane;
    int4 ShadowLightIndices;
    float4 ShadowFarPlanes;
    float PointShadowBias;
    float PointShadowSoftness;
    int NumShadowCastingLights;
    float PLShadowPadding;
};

Texture2D<float4> g_GBufferAlbedo   : register(t200);
Texture2D<float4> g_GBufferNormal   : register(t201);
Texture2D<float4> g_GBufferMaterial : register(t202);
Texture2D<float4> g_GBufferMotion   : register(t203);
Texture2D<float>  g_DepthBuffer     : register(t204);

Texture2D<float> g_ShadowMap : register(t240);
Texture2D<float4> g_ScreenIndirectLighting : register(t241);  // 需要 C++ 端绑定 temporal filtered output 到这个 slot
TextureCubeArray<float> g_PointLightShadowMaps : register(t242);

#if ENABLE_SDF_SHADOW
Texture3D<float2> g_GlobalSDF : register(t378);
#endif

SamplerState PointSampler  : register(s0);
SamplerState LinearSampler : register(s1);
SamplerComparisonState ShadowSampler : register(s2);
struct VSOutput
{
    float4 Position : SV_POSITION;
    float2 TexCoord : TEXCOORD0;
};

VSOutput CompositeVS(uint vertexID : SV_VertexID)
{
    VSOutput output;
    float2 uv = float2((vertexID << 1) & 2, vertexID & 2);
    output.TexCoord = uv;
    output.Position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return output;
}

int GetShadowSlotForLightCS(int lightIndex)
{
    [unroll]
    for (int s = 0; s < 4; s++)
    {
        if (s >= NumShadowCastingLights) break;
        if (ShadowLightIndices[s] == lightIndex) return s;
    }
    return -1;
}

float SamplePointShadowCS(int shadowSlot, float3 worldPos, float3 lightPos)
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

    // Poisson disk
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
        float stored = g_PointLightShadowMaps.SampleLevel(PointSampler, float4(sampleDir, (float)shadowSlot), 0).r;
        shadow += (currentDepth - PointShadowBias > stored) ? 0.0 : 1.0;
    }
    return shadow / (float)NUM_SAMPLES;
}

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

// 屏幕空间接触阴影 - 用于墙角等 shadow map 失效的地方
float ScreenSpaceContactShadow(float3 worldPos, float3 lightDir, float2 screenUV, float depth)
{
    const int NUM_STEPS = 8;
    const float RAY_LENGTH = 0.5f;  // 世界空间追踪距离

    float3 rayStart = worldPos;
    float3 rayEnd = worldPos + lightDir * RAY_LENGTH;

    float occlusion = 0.0f;

    [unroll]
    for (int i = 1; i <= NUM_STEPS; i++)
    {
        float t = float(i) / float(NUM_STEPS);
        float3 sampleWorldPos = lerp(rayStart, rayEnd, t);

        // 投影到屏幕空间
        float4 clipPos = mul(RenderToClipTransform, mul(CameraToRenderTransform, mul(WorldToCameraTransform, float4(sampleWorldPos, 1.0f))));
        clipPos.xyz /= clipPos.w;

        float2 sampleUV = clipPos.xy * 0.5f + 0.5f;
        sampleUV.y = 1.0f - sampleUV.y;

        if (any(sampleUV < 0.0f) || any(sampleUV > 1.0f))
            continue;

        float sceneDepth = g_DepthBuffer.SampleLevel(PointSampler, sampleUV, 0);

        // 如果采样点的深度大于场景深度，说明被遮挡
        float rayDepth = clipPos.z;
        if (rayDepth > sceneDepth + 0.001f && sceneDepth > 0.0f && sceneDepth < 0.9999f)
        {
            // 渐进遮挡
            occlusion = max(occlusion, 1.0f - t);
        }
    }

    return 1.0f - occlusion * 0.8f;  // 不要完全黑
}

float SampleShadowMapPCF(float3 worldPos, float3 normal, float2 screenUV, float depth)
{
    float4x4 lightViewProj = mul(LightRenderToClip, mul(LightCameraToRender, LightWorldToCamera));
    float NdotL = saturate(dot(normal, -SunNormal));
    float3 lightDir = -SunNormal;

    // === 背面直接返回无阴影 ===
    if (NdotL < 0.01f)
    {
        return 1.0f;
    }

    // === 标准 Shadow Map + PCF ===
    float normalOffsetScale = 0.005f * (1.0f - NdotL);
    float3 offsetWorldPos = worldPos + normal * normalOffsetScale;

    float4 lightSpacePos = mul(lightViewProj, float4(offsetWorldPos, 1.0f));
    lightSpacePos.xyz /= lightSpacePos.w;
    float2 shadowUV = lightSpacePos.xy * 0.5f + 0.5f;
    shadowUV.y = 1.0f - shadowUV.y;

    float shadowMapResult = 1.0f;
    if (all(shadowUV >= 0.0f) && all(shadowUV <= 1.0f))
    {
        float texelSize = 1.0f / ShadowMapSize;

        // Slope-scaled bias
        float slopeScale = sqrt(1.0f - NdotL * NdotL) / NdotL;
        slopeScale = min(slopeScale, 5.0f);
        float bias = 0.002f + 0.003f * slopeScale;
        float receiverDepth = lightSpacePos.z - bias;

        float shadow = 0.0f;

        // 5x5 PCF
        [unroll]
        for (int x = -2; x <= 2; ++x)
        {
            [unroll]
            for (int y = -2; y <= 2; ++y)
            {
                float2 offset = float2(x, y) * texelSize;
                shadow += g_ShadowMap.SampleCmpLevelZero(ShadowSampler, shadowUV + offset, receiverDepth);
            }
        }
        shadowMapResult = shadow / 25.0f;
    }

    // 边缘平滑已移除 - 会在 NdotL 0.02~0.2 区域造成漫反射光泄漏（线状高光）

    // float contactShadow = ScreenSpaceContactShadow(worldPos, lightDir, screenUV, depth);
    float finalShadow = shadowMapResult;

    // === SDF 阴影 ===
#if ENABLE_SDF_SHADOW
    float sdfShadowResult = 1.0f;
    if (UseSDFShadow > 0.5f && SDFExtent > 0.0f)
    {
        float3 sunDir = -SunNormal;
        float softness = SDFShadowSoftness > 0.0f ? SDFShadowSoftness : 12.0f;

        // 沿法线和光线方向偏移，避免 self-shadowing
        float3 sdfRayOrigin = worldPos + normal * 0.5f + sunDir * 0.5f;

        sdfShadowResult = TraceSDFSoftShadowImproved(
            g_GlobalSDF,
            LinearSampler,
            SDFCenter,
            SDFExtent,
            sdfRayOrigin,
            sunDir,
            SDF_SHADOW_MAX_DISTANCE,
            softness
        );
    }

    // 简化混合：SDF 只用于软化阴影边缘，不引入新的阴影
    float combined = finalShadow * sdfShadowResult;

    // 防止过暗
    combined = max(combined, finalShadow * 0.3f);

    return combined;
#else
    return finalShadow;
#endif
}

float RangeMap(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (value - inMin) * (outMax - outMin) / (inMax - inMin);
}

float SmoothStep3(float t)
{
    return t * t * (3.0 - 2.0 * t);
}

float3 CalculateDirectLighting(float3 worldPos, float3 normal, float3 albedo, float shadow,
                                float3 viewDir, float roughness, float metallic)
{
    float3 F0 = lerp(float3(0.04, 0.04, 0.04), albedo, metallic);
    float smoothness = 1.0 - roughness;
    float specPower = pow(2.0, smoothness * 12.0);  // Range: 1 to 4096
    float normFactor = (specPower + 8.0) / 25.132;  // Normalization: (n+8)/(8*PI)

    float3 totalDiffuse = float3(0, 0, 0);
    float3 totalSpecular = float3(0, 0, 0);

    float3 L_sun = -SunNormal;
    float NdotL_sun = saturate(dot(normal, L_sun));
    float3 sunRadiance = SunColor.rgb * SunColor.a * NdotL_sun * shadow;

    totalDiffuse += sunRadiance;

    float3 H_sun = normalize(L_sun + viewDir);
    float NdotH_sun = saturate(dot(normal, H_sun));
    float VdotH_sun = saturate(dot(viewDir, H_sun));

    float specIntensity_sun = pow(NdotH_sun, specPower) * normFactor;
    float3 fresnel_sun = F0 + (1.0 - F0) * pow(1.0 - VdotH_sun, 5.0);
    totalSpecular += fresnel_sun * specIntensity_sun * sunRadiance;

    float3 ambient = AmbientColor * AmbientIntensity;
    totalDiffuse += ambient;

    for (int i = 0; i < NumLights; i++)
    {
        Light light = LightsArray[i];

        float3 lightPos = light.WorldPosition;
        float3 lightColor = light.Color.rgb;
        float lightBrightness = light.Color.a;
        float innerRadius = light.InnerRadius;
        float outerRadius = light.OuterRadius;
        float innerPenumbraDot = light.InnerDotThreshold;
        float outerPenumbraDot = light.OuterDotThreshold;
        float ambience = light.Ambience;

        float3 pixelToLightDisp = lightPos - worldPos;
        float3 pixelToLightDir = normalize(pixelToLightDisp);
        float3 lightToPixelDir = -pixelToLightDir;
        float distToLight = length(pixelToLightDisp);

        float falloff = saturate(RangeMap(distToLight, innerRadius, outerRadius, 1.0, 0.0));
        falloff = SmoothStep3(falloff);

        float penumbra = 1.0;
        if (length(light.SpotForward) > 0.01)
        {
            penumbra = saturate(RangeMap(
                dot(light.SpotForward, lightToPixelDir),
                outerPenumbraDot,
                innerPenumbraDot,
                0.0,
                1.0
            ));
            penumbra = SmoothStep3(penumbra);
        }

        float NdotL = saturate(dot(pixelToLightDir, normal));
        float attenuation = penumbra * falloff * lightBrightness;

        float pointShadow = 1.0;
        int shadowSlot = GetShadowSlotForLightCS(i);
        if (shadowSlot >= 0)
            pointShadow = SamplePointShadowCS(shadowSlot, worldPos, lightPos);

        float diffuseFactor = saturate(RangeMap(dot(pixelToLightDir, normal), -ambience, 1.0, 0.0, 1.0));
        float3 lightRadiance = attenuation * lightColor * pointShadow;
        totalDiffuse += lightRadiance * diffuseFactor;

        if (NdotL > 0.001)
        {
            float3 H = normalize(pixelToLightDir + viewDir);
            float NdotH = saturate(dot(normal, H));
            float VdotH = saturate(dot(viewDir, H));

            float specIntensity = pow(NdotH, specPower) * normFactor * NdotL;
            float3 fresnel = F0 + (1.0 - F0) * pow(1.0 - VdotH, 5.0);
            totalSpecular += fresnel * specIntensity * lightRadiance;
        }
    }

    float3 diffuseColor = albedo * (1.0 - metallic);
    return diffuseColor * totalDiffuse + totalSpecular;
}

float3 GetSkyColor(float3 viewDir)
{
    return float3(0.0, 0.0, 0.0);
}

float3 ToneMapACES(float3 color)
{
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return saturate((color * (a * color + b)) / (color * (c * color + d) + e));
}

float4 CompositePS(VSOutput input) : SV_TARGET
{
    uint2 pixelCoord = uint2(input.Position.xy);
    float2 uv = input.TexCoord;

    float depth = g_DepthBuffer[pixelCoord];

    if (depth >= 0.9999)
    {
        float3 worldPos = ReconstructWorldPosition(uv, 0.5);
        float3 viewDir = normalize(worldPos - CameraWorldPosition);
        float3 skyColor = GetSkyColor(viewDir);
        skyColor = pow(saturate(skyColor), 1.0 / 2.2);
        return float4(skyColor, 1.0);
    }

    float3 worldPos = ReconstructWorldPosition(uv, depth);

    float3 albedo = g_GBufferAlbedo[pixelCoord].rgb;
    float3 worldNormal = DecodeNormal(g_GBufferNormal[pixelCoord].rgb);
    float4 specularData = g_GBufferMaterial[pixelCoord];
    float roughness = specularData.r;
    float metallic = specularData.g;
    float ao = specularData.b;

    float3 viewDir = normalize(CameraWorldPosition - worldPos);

    float shadow = SampleShadowMapPCF(worldPos, worldNormal, uv, depth);
    float3 directLighting = CalculateDirectLighting(worldPos, worldNormal, albedo, shadow,
                                                     viewDir, roughness, metallic);
    directLighting *= DirectIntensity;

    float3 indirectLighting = g_ScreenIndirectLighting[pixelCoord].rgb;

    float3 finalColor = directLighting + indirectLighting;
    finalColor = ToneMapACES(finalColor);
    finalColor = pow(saturate(finalColor), 1.0 / 2.2);

    return float4(finalColor, 1.0);
}
