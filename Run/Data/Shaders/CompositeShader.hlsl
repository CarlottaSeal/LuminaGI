#include "ShadowPCF.hlsli"

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
};

//=============================================================================
// 点光源/聚光灯
//=============================================================================
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
    float4 SunColorAlt;     // 已经在 CompositeConstants 中有了，这里可以忽略
    float3 SunNormalAlt;
    int NumLights;
    Light LightsArray[15];  // 必须与 C++ 端 s_maxLights 匹配！
};

//=============================================================================
// GBuffer (t200-t204)
//=============================================================================
Texture2D<float4> g_GBufferAlbedo   : register(t200);  
Texture2D<float4> g_GBufferNormal   : register(t201);  
Texture2D<float4> g_GBufferMaterial : register(t202);  
Texture2D<float4> g_GBufferMotion   : register(t203);  
Texture2D<float>  g_DepthBuffer     : register(t204);  

//=============================================================================
// Shadow Map (t240)
//=============================================================================
Texture2D<float> g_ShadowMap : register(t240);

//=============================================================================
// Screen Probe 间接光照 (t241)
//=============================================================================
Texture2D<float4> g_ScreenIndirectLighting : register(t241);

//=============================================================================
// Samplers
//=============================================================================
SamplerState PointSampler  : register(s0);
SamplerState LinearSampler : register(s1);
SamplerComparisonState ShadowSampler : register(s2);  

//=============================================================================
// Vertex Shader
//=============================================================================
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

float SampleShadowMapPCF(float3 worldPos, float3 normal)
{
    float4x4 lightViewProj = mul(LightRenderToClip, mul(LightCameraToRender, LightWorldToCamera));

    // 计算 NdotL
    float NdotL = saturate(dot(normal, -SunNormal));

    // 不用法线偏移，直接变换
    float4 lightSpacePos = mul(lightViewProj, float4(worldPos, 1.0f));
    lightSpacePos.xyz /= lightSpacePos.w;
    float2 shadowUV = lightSpacePos.xy * 0.5f + 0.5f;
    shadowUV.y = 1.0f - shadowUV.y;

    if (any(shadowUV < 0.0f) || any(shadowUV > 1.0f))
        return 1.0f;

    float receiverDepth = lightSpacePos.z;
    // 硬件已经有 depth bias，这里只需要很小的额外偏移
    float bias = 0.001f;
    receiverDepth -= bias;

    // 使用 5x5 PCF 采样减少闪烁
    float texelSize = 1.0f / ShadowMapSize;

    // Snap采样中心到texel中心，减少sub-texel抖动
    float2 snappedUV = (floor(shadowUV * ShadowMapSize) + 0.5f) / ShadowMapSize;

    float shadow = 0.0f;

    [unroll]
    for (int x = -2; x <= 2; ++x)
    {
        [unroll]
        for (int y = -2; y <= 2; ++y)
        {
            float2 offset = float2(x, y) * texelSize;
            shadow += g_ShadowMap.SampleCmpLevelZero(ShadowSampler, snappedUV + offset, receiverDepth);
        }
    }

    return shadow / 25.0f;
}

float RangeMap(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (value - inMin) * (outMax - outMin) / (inMax - inMin);
}

float SmoothStep3(float t)
{
    return t * t * (3.0 - 2.0 * t);
}

float3 CalculateDirectLighting(float3 worldPos, float3 normal, float3 albedo, float shadow)
{
    // 太阳光
    float NdotL = saturate(dot(normal, -SunNormal));
    float3 sunLight = SunColor.rgb * SunColor.a * NdotL * shadow;
    float3 ambient = AmbientColor * AmbientIntensity;

    float3 totalLight = sunLight + ambient;

    // 点光源/聚光灯
    for (int i = 0; i < NumLights; i++)
    {
        Light light = LightsArray[i];

        float3 lightPos = light.WorldPosition;
        float3 lightColor = light.Color.rgb;
        float lightBrightness = light.Color.a;  // 已经是 0.0-1.0 范围
        float innerRadius = light.InnerRadius;
        float outerRadius = light.OuterRadius;
        float innerPenumbraDot = light.InnerDotThreshold;
        float outerPenumbraDot = light.OuterDotThreshold;
        float ambience = light.Ambience;

        float3 pixelToLightDisp = lightPos - worldPos;
        float3 pixelToLightDir = normalize(pixelToLightDisp);
        float3 lightToPixelDir = -pixelToLightDir;
        float distToLight = length(pixelToLightDisp);

        // 距离衰减
        float falloff = saturate(RangeMap(distToLight, innerRadius, outerRadius, 1.0, 0.0));
        falloff = SmoothStep3(falloff);

        // 聚光灯角度衰减
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

        // 漫反射
        float lightStrength = penumbra * falloff * lightBrightness *
            saturate(RangeMap(dot(pixelToLightDir, normal), -ambience, 1.0, 0.0, 1.0));

        totalLight += lightStrength * lightColor;
    }

    return albedo * totalLight;
}

float3 GetSkyColor(float3 viewDir)
{
    return float3(0.0, 0.0, 0.0);  // 纯黑天空
}

float3 ToneMapACES(float3 color)
{
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return saturate((color * (a * color + b)) / (color * (c * color + d) + e));
}

//=============================================================================
// Pixel Shader
//=============================================================================

float4 CompositePS(VSOutput input) : SV_TARGET
{
    uint2 pixelCoord = uint2(input.Position.xy);
    float2 uv = input.TexCoord;
    
    float depth = g_DepthBuffer[pixelCoord];
    
    // 天空
    if (depth >= 0.9999)
    {
        float3 worldPos = ReconstructWorldPosition(uv, 0.5);
        float3 viewDir = normalize(worldPos - CameraWorldPosition);
        float3 skyColor = GetSkyColor(viewDir);
        // 天空不需要 tonemapping，直接 gamma 校正
        skyColor = pow(saturate(skyColor), 1.0 / 2.2);
        return float4(skyColor, 1.0);
    }
    
    float3 worldPos = ReconstructWorldPosition(uv, depth);
    
    // GBuffer
    float3 albedo = g_GBufferAlbedo[pixelCoord].rgb;
    float3 worldNormal = DecodeNormal(g_GBufferNormal[pixelCoord].rgb);
    float4 specularData = g_GBufferMaterial[pixelCoord];
    float roughness = specularData.r;
    float metallic = specularData.g;
    float ao = specularData.b;
    
    // 直接光照
    float shadow = SampleShadowMapPCF(worldPos, worldNormal);
    float3 directLighting = CalculateDirectLighting(worldPos, worldNormal, albedo, shadow);
    directLighting *= DirectIntensity;
    
    // 间接光照
    float3 indirectLighting = g_ScreenIndirectLighting[pixelCoord].rgb;
    indirectLighting *= IndirectIntensity;
    indirectLighting *= lerp(1.0, ao, AOStrength);
    float3 diffuseColor = albedo * (1.0 - metallic);
    indirectLighting *= diffuseColor;
    
    // 合并
    float3 finalColor = directLighting + indirectLighting;
    finalColor = ToneMapACES(finalColor);
    finalColor = pow(saturate(finalColor), 1.0 / 2.2);
    
    return float4(finalColor, 1.0);
}
