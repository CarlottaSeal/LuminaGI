// Debug mode (0=normal, 1=shadow, 2=NdotL, 3=NumLights, 4=sun only, 5=point lights only)
#define CARDCAPTURE_DEBUG_MODE 0

#define MAX_TEXTURE_COUNT 200
cbuffer CardCaptureConstants : register(b10)
{
    float3 CardOrigin;
    float padding0;
    float3 CardAxisX;
    float padding1;
    float3 CardAxisY;
    float padding2;
    float3 CardNormal;
    float CaptureDepth;
    
    float2 CardSize;
    uint CaptureDirection;
    uint Resolution;
    
    uint LightMask[4];
};

cbuffer ShadowConstants : register(b5)
{
    float4x4 LightWorldToCamera;
    float4x4 LightCameraToRender;
    float4x4 LightRenderToClip;
    float ShadowMapSize;
    float ShadowBias;
    float SoftnessFactor;
    float LightSize;
    float3 LightPosition_Shadow;
    float FarPlane;
    int4 ShadowLightIndices;
    float4 ShadowFarPlanes;
    float PointShadowBias;
    float PointShadowSoftness;
    int NumShadowCastingLights;
    float PLShadowPadding;
};

cbuffer ModelConstants : register(b9)
{
    float4x4 ModelMatrix; 
    float4 ModelColor;
};

cbuffer MaterialConstants : register(b8)
{
    int DiffuseId;
    int NormalId;
    int SpecularId;
    float materialPadding;
};

cbuffer CameraConstants : register(b1)
{
    float4x4 WorldToCameraTransform;
    float4x4 CameraToRenderTransform;
    float4x4 RenderToClipTransform;
    float3 CameraWorldPosition;
    float cameraPadding;
};

struct Light
{
    float4 Color;          
    float3 WorldPosition;
    float EMPTY_PADDING;
    float3 SpotForward;
    float Ambience;
    float InnerRadius;
    float OuterRadius;
    float InnerDotThreshold;
    float OuterDotThreshold;
};

cbuffer GeneralLightConstants : register(b4)
{
    float4 SunColor; 
    float3 SunNormal;
    int NumLights;
    Light LightsArray[15];
};

Texture2D g_textures[MAX_TEXTURE_COUNT]: register(t0);
Texture2D<float> ShadowMap : register(t240);
TextureCubeArray<float> PointLightShadowMaps : register(t242);
SamplerState MaterialSampler : register(s0);

float RangeMap(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (value - inMin) * (outMax - outMin) / (inMax - inMin);
}

float SmoothStep3(float t)
{
    return t * t * (3.0 - 2.0 * t);
}

bool IsLightEnabled(uint lightIndex)
{
    if (lightIndex >= 128)
        return false;

    uint maskIndex = lightIndex / 32;
    uint bitIndex = lightIndex % 32;

    return (LightMask[maskIndex] & (1u << bitIndex)) != 0;
}

int GetShadowSlotForLightCC(int lightIndex)
{
    [unroll]
    for (int s = 0; s < 4; s++)
    {
        if (s >= NumShadowCastingLights) break;
        if (ShadowLightIndices[s] == lightIndex) return s;
    }
    return -1;
}

float SamplePointShadowCC(int shadowSlot, float3 worldPos, float3 lightPos)
{
    float3 lightToPixel = worldPos - lightPos;
    float currentDist = length(lightToPixel);
    float3 dir = lightToPixel / currentDist;
    float currentDepth = currentDist / ShadowFarPlanes[shadowSlot];

    float storedDepth = PointLightShadowMaps.SampleLevel(MaterialSampler, float4(dir, (float)shadowSlot), 0).r;
    return (currentDepth - PointShadowBias > storedDepth) ? 0.0 : 1.0;
}

float SampleShadow(float3 worldPos)
{
    if (LightWorldToCamera[0][0] == 0.0 && LightWorldToCamera[1][1] == 0.0 &&
        LightWorldToCamera[2][2] == 0.0)
    {
        return 0.5;
    }

    float4 cameraPos = mul(LightWorldToCamera, float4(worldPos, 1.0));
    float4 renderPos = mul(LightCameraToRender, cameraPos);
    float4 lightClipPos = mul(LightRenderToClip, renderPos);

    float3 projCoords = lightClipPos.xyz / lightClipPos.w;
    float2 shadowUV = projCoords.xy * 0.5 + 0.5;
    shadowUV.y = 1.0 - shadowUV.y;

    if (any(shadowUV < 0.0) || any(shadowUV > 1.0) || projCoords.z > 1.0 || projCoords.z < 0.0)
        return 1.0;

    float currentDepth = projCoords.z;

    // PCF 3x3
    float shadow = 0.0;
    float texelSize = 1.0 / max(ShadowMapSize, 1.0);
    [unroll]
    for (int x = -1; x <= 1; x++)
    {
        [unroll]
        for (int y = -1; y <= 1; y++)
        {
            float2 offset = float2(x, y) * texelSize;
            float shadowDepth = ShadowMap.Sample(MaterialSampler, shadowUV + offset);
            shadow += (currentDepth - ShadowBias > shadowDepth) ? 0.0 : 1.0;
        }
    }
    return shadow / 9.0;
}

struct VSInput
{
    float3 position : POSITION;
    float4 color : COLOR;
    float2 texcoord : TEXCOORD0;
    float3 tangent : TANGENT;
    float3 bitangent : BITANGENT;
    float3 normal : NORMAL;
};

struct PSInput
{
    float4 position : SV_Position;
    float3 worldPos : POSITION0;
    float3 worldNormal : NORMAL0;
    float3 worldTangent : TANGENT0;
    float3 worldBitangent : BITANGENT0;
    float2 texcoord : TEXCOORD0;
};

PSInput CardCaptureVS(VSInput input)
{
    PSInput output;

    float4 worldPos = mul(ModelMatrix, float4(input.position, 1.0));
    output.worldPos = worldPos.xyz;

    float3x3 modelMatrix3x3 = (float3x3)ModelMatrix;
    float3 worldNormal = normalize(mul(modelMatrix3x3, input.normal));
    float3 worldTangent = normalize(mul(modelMatrix3x3, input.tangent));
    float3 worldBitangent = normalize(mul(modelMatrix3x3, input.bitangent));

    output.worldNormal = worldNormal;
    output.worldTangent = worldTangent;
    output.worldBitangent = worldBitangent;
    output.texcoord = input.texcoord;

    float3 worldOffset = worldPos.xyz - CardOrigin;
    float3 localPos;
    localPos.x = dot(worldOffset, CardAxisX);
    localPos.y = dot(worldOffset, CardAxisY);
    localPos.z = dot(worldOffset, CardNormal);

    float2 ndc;
    ndc.x = localPos.x / (CardSize.x * 0.5);
    ndc.y = -localPos.y / (CardSize.y * 0.5);

    float depth = saturate(localPos.z / CaptureDepth);

    float facing = dot(worldNormal, CardNormal);
    if (facing < -0.05)
    {
        depth = 1.1;
    }

    output.position = float4(ndc.x, ndc.y, depth, 1.0);

    return output;
}

struct PSOutput
{
    float4 albedo : SV_Target0;        // Layer 0: Albedo (RGB + Alpha)
    float4 normal : SV_Target1;        // Layer 1: World Normal [0,1]
    float4 material : SV_Target2;      // Layer 2: Roughness, Metallic, AO
    float4 directLight : SV_Target3;   // Layer 3: Direct Lighting
};

PSOutput CardCapturePS(PSInput input)
{
    PSOutput output;

    output.albedo = g_textures[DiffuseId].Sample(MaterialSampler, input.texcoord);
    
    if (output.albedo.a < 0.1)
        discard;
    
    float3 tangentNormal = g_textures[NormalId].Sample(MaterialSampler, input.texcoord).xyz;
    tangentNormal = tangentNormal * 2.0 - 1.0;  // [0,1] -> [-1,1]
    
    float3 N = normalize(input.worldNormal);
    float3 T = normalize(input.worldTangent);
    T = normalize(T - dot(T, N) * N);  // Gram-Schmidt orthogonalization
    float3 B = normalize(input.worldBitangent);
    
    float3x3 TBN = float3x3(T, B, N);
    float3 worldNormal = mul(tangentNormal, TBN);
    worldNormal = normalize(worldNormal);
    
    output.normal = float4(worldNormal * 0.5 + 0.5, 1.0);
    
    float4 materialProps = g_textures[SpecularId].Sample(MaterialSampler, input.texcoord);
    output.material = materialProps;

    // Surface cache uses Lambertian only; roughness/metallic/specular not needed
    float3 diffuseColor = output.albedo.rgb;
    float3 pixelNormalWorldSpace = worldNormal;

    float shadow = SampleShadow(input.worldPos);
    float3 sunDir = -normalize(SunNormal);
    float sunDiffuseDot = saturate(dot(sunDir, pixelNormalWorldSpace));

    #if CARDCAPTURE_DEBUG_MODE == 1
        output.directLight = float4(shadow, shadow, shadow, 1.0);
        return output;
    #elif CARDCAPTURE_DEBUG_MODE == 2
        output.directLight = float4(sunDiffuseDot, sunDiffuseDot, sunDiffuseDot, 1.0);
        return output;
    #elif CARDCAPTURE_DEBUG_MODE == 3
        output.directLight = float4(NumLights * 0.1, 0, 0, 1.0);
        return output;
    #endif

    float3 totalDiffuseLight = 0;

    // Pure Lambertian, no specular
    #if CARDCAPTURE_DEBUG_MODE != 5
    {
        float3 sunDiffuseLight = sunDiffuseDot * SunColor.rgb * SunColor.a * shadow;
        totalDiffuseLight += sunDiffuseLight;
    }
    #endif

    #if CARDCAPTURE_DEBUG_MODE != 4
    for (int lightIndex = 0; lightIndex < NumLights; lightIndex++)
    {
        if (!IsLightEnabled(lightIndex))
            continue;

        Light light = LightsArray[lightIndex];

        float3 lightPos = light.WorldPosition;
        float3 lightColor = light.Color.rgb;
        float lightBrightness = light.Color.a;
        float innerRadius = light.InnerRadius;
        float outerRadius = light.OuterRadius;
        float innerPenumbraDot = light.InnerDotThreshold;
        float outerPenumbraDot = light.OuterDotThreshold;
        float ambience = light.Ambience;

        float3 pixelToLightDisp = lightPos - input.worldPos;
        float3 pixelToLightDir = normalize(pixelToLightDisp);
        float3 lightToPixelDir = -pixelToLightDir;
        float distToLight = length(pixelToLightDisp);

        float falloff = saturate(RangeMap(distToLight, innerRadius, outerRadius, 1.0, 0.0));
        falloff = SmoothStep3(falloff);

        float penumbra = saturate(RangeMap(
            dot(light.SpotForward, lightToPixelDir),
            outerPenumbraDot,
            innerPenumbraDot,
            0.0,
            1.0
        ));
        penumbra = SmoothStep3(penumbra);

        float NoL = saturate(dot(pixelToLightDir, pixelNormalWorldSpace));

        float pointShadow = 1.0;
        int shadowSlot = GetShadowSlotForLightCC(lightIndex);
        if (shadowSlot >= 0)
            pointShadow = SamplePointShadowCC(shadowSlot, input.worldPos, lightPos);

        float lightStrength = penumbra * falloff * lightBrightness * NoL * pointShadow;
        float3 diffuseLight = lightStrength * lightColor;
        totalDiffuseLight += diffuseLight;
    }
    #endif

    // Lambertian BRDF = albedo / PI
    float3 finalRGB = totalDiffuseLight * diffuseColor.rgb * (1.0 / 3.14159265359);

    output.directLight = float4(finalRGB, 1.0);
    
    return output;
}