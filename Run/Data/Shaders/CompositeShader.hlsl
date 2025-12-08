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
    
    float3 SunDirection;
    float SunIntensity;
    
    float3 SunColor;
    float AmbientIntensity;
    
    float3 AmbientColor;
    float ShadowBias;
    
    float4x4 LightWorldToCamera;
    float4x4 LightCameraToRender;
    float4x4 LightRenderToClip;
    
    float ShadowMapSize;
    float AOStrength;
    float Padding0;
    float Padding1;
};

//=============================================================================
// GBuffer (t200-t204) - Root Signature [15] 绑定的是连续的 5 个寄存器
//=============================================================================
Texture2D<float4> g_GBufferAlbedo   : register(t200);  
Texture2D<float4> g_GBufferNormal   : register(t201);  
Texture2D<float4> g_GBufferMaterial : register(t202);  
Texture2D<float4> g_GBufferMotion   : register(t203);  
Texture2D<float>  g_DepthBuffer     : register(t204);  

//=============================================================================
// Shadow Map (t240) - SHADOW_MAP_SRV_INDEX
//=============================================================================
Texture2D<float> g_ShadowMap : register(t240);

//=============================================================================
// Screen Probe 间接光照 (t241) - Root Parameter [27]
//=============================================================================
Texture2D<float4> g_ScreenIndirectLighting : register(t241);

//=============================================================================
// Samplers
//=============================================================================
SamplerState PointSampler  : register(s0);
SamplerState LinearSampler : register(s1);

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

//=============================================================================
// 辅助函数
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

float SampleShadowMapPCF(float3 worldPos)
{
    float4 cameraPos = mul(LightWorldToCamera, float4(worldPos, 1.0));
    float4 renderPos = mul(LightCameraToRender, cameraPos);
    float4 clipPos = mul(LightRenderToClip, renderPos);
    clipPos.xyz /= clipPos.w;
    
    float2 shadowUV = clipPos.xy * 0.5 + 0.5;
    shadowUV.y = 1.0 - shadowUV.y;
    
    if (any(shadowUV < 0.0) || any(shadowUV > 1.0))
        return 1.0;
    
    float currentDepth = clipPos.z - ShadowBias;
    
    float shadow = 0.0;
    float texelSize = 1.0 / ShadowMapSize;
    
    [unroll]
    for (int x = -1; x <= 1; x++)
    {
        [unroll]
        for (int y = -1; y <= 1; y++)
        {
            float2 offset = float2(x, y) * texelSize;
            float shadowDepth = g_ShadowMap.SampleLevel(PointSampler, shadowUV + offset, 0);
            shadow += (currentDepth < shadowDepth) ? 1.0 : 0.0;
        }
    }
    
    return shadow / 9.0;
}

float3 CalculateDirectLighting(float3 worldPos, float3 normal, float3 albedo, float shadow)
{
    float NdotL = saturate(dot(normal, -SunDirection));
    float3 sunLight = SunColor * SunIntensity * NdotL * shadow;
    float3 ambient = AmbientColor * AmbientIntensity;
    return albedo * (sunLight + ambient);
}

float3 GetSkyColor(float3 viewDir)
{
    float skyFactor = saturate(viewDir.y * 0.5 + 0.5);
    return lerp(float3(0.5, 0.7, 1.0), float3(0.1, 0.2, 0.4), skyFactor);
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
        return float4(GetSkyColor(viewDir), 1.0);
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
    float shadow = SampleShadowMapPCF(worldPos);
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
