//=============================================================================
#define MAX_CARDS 4096

cbuffer ShadowConstants : register(b5)
{
    float4x4 LightWorldToCamera;
    float4x4 LightCameraToRender;
    float4x4 LightRenderToClip;
    float ShadowMapSize;
    float ShadowBias;
    float SoftnessFactor;
    float LightSize;
    // Point light cube shadow
    float3 LightPosition_Shadow;
    float FarPlane;
    int4 ShadowLightIndices;
    float4 ShadowFarPlanes;
    float PointShadowBias;
    float PointShadowSoftness;
    int NumShadowCastingLights;
    float PLShadowPadding;
};

struct DLLight
{
    float4 Color;
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
    float4 SunColor;
    float3 SunDirection;
    int NumLights;
    DLLight LightsArray[15];
};

cbuffer DirectLightParams : register(b0)
{
    uint AtlasWidth;
    uint AtlasHeight;
    uint ActiveCardCount;
    uint Padding;
};

// Must match C++ SurfaceCardMetadata layout
struct SurfaceCardGPU
{
    uint AtlasX;
    uint AtlasY;
    uint ResolutionX;
    uint ResolutionY;

    float3 WorldOrigin;
    float Padding0;

    float3 WorldAxisX;
    float ObjectID;

    float3 WorldAxisY;
    float Padding2;

    float3 WorldNormal;
    float Padding3;

    float2 WorldSize;
    uint Direction;
    uint GlobalCardID;

    uint LightMask[4];
};

StructuredBuffer<SurfaceCardGPU> CardMetadata : register(t0);
Texture2DArray<float4> SurfaceAtlas : register(t1);  // Albedo=0, Normal=1, Material=2
Texture2D<float> ShadowMap : register(t2);
TextureCubeArray<float> PointLightShadowMaps : register(t3);
Texture2D<uint> CardIndexLookup : register(t4);  // tile→cardIndex map, 0xFFFFFFFF = empty

static const uint TILE_SIZE = 64;  // must match m_surfaceCache.m_tileSize

RWTexture2DArray<float4> SurfaceAtlasUAV : register(u0);  // Write to DirectLight layer (3)

SamplerState LinearSampler : register(s0);
SamplerState PointSampler : register(s1);

static const uint ALBEDO_LAYER = 0;
static const uint NORMAL_LAYER = 1;
static const uint DIRECT_LIGHT_LAYER = 3;

float RangeMapDL(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (value - inMin) * (outMax - outMin) / (inMax - inMin);
}

float SmoothStep3DL(float t)
{
    return t * t * (3.0 - 2.0 * t);
}

int GetShadowSlotForLightDL(int lightIndex)
{
    [unroll]
    for (int s = 0; s < 4; s++)
    {
        if (s >= NumShadowCastingLights) break;
        if (ShadowLightIndices[s] == lightIndex) return s;
    }
    return -1;
}

float SamplePointShadowDL(int shadowSlot, float3 worldPos, float3 lightPos)
{
    float3 lightToPixel = worldPos - lightPos;
    float currentDist = length(lightToPixel);
    float3 dir = lightToPixel / currentDist;
    float currentDepth = currentDist / ShadowFarPlanes[shadowSlot];

    float storedDepth = PointLightShadowMaps.SampleLevel(PointSampler, float4(dir, (float)shadowSlot), 0).r;
    return (currentDepth - PointShadowBias > storedDepth) ? 0.0 : 1.0;
}

bool IsLightEnabledDL(uint lightIndex, uint lightMask[4])
{
    if (lightIndex >= 128)
        return false;
    uint maskIndex = lightIndex / 32;
    uint bitIndex = lightIndex % 32;
    return (lightMask[maskIndex] & (1u << bitIndex)) != 0;
}

float SampleShadow(float3 worldPos)
{
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
            float shadowDepth = ShadowMap.SampleLevel(PointSampler, shadowUV + offset, 0);
            shadow += (currentDepth - ShadowBias > shadowDepth) ? 0.0 : 1.0;
        }
    }
    return shadow / 9.0;
}

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 atlasCoord = dispatchThreadID.xy;

    if (atlasCoord.x >= AtlasWidth || atlasCoord.y >= AtlasHeight)
        return;

    uint2 tileCoord = atlasCoord / TILE_SIZE;
    uint cardIdx = CardIndexLookup.Load(int3(tileCoord, 0));
    if (cardIdx == 0xFFFFFFFF)
        return;

    SurfaceCardGPU card = CardMetadata[cardIdx];

    uint2 cardAtlasCoord = uint2(card.AtlasX, card.AtlasY);
    uint2 cardResolution = uint2(card.ResolutionX, card.ResolutionY);
    uint2 localTexel = atlasCoord - cardAtlasCoord;

    float2 cardUV = (float2(localTexel) + 0.5f) / float2(cardResolution);

    float3 worldPos = card.WorldOrigin
        + (cardUV.x - 0.5) * card.WorldAxisX * card.WorldSize.x
        + (cardUV.y - 0.5) * card.WorldAxisY * card.WorldSize.y;

    float2 atlasUV = (float2(atlasCoord) + 0.5) / float2(AtlasWidth, AtlasHeight);
    float4 albedo = SurfaceAtlas.SampleLevel(LinearSampler, float3(atlasUV, ALBEDO_LAYER), 0);

    if (albedo.a < 0.1)
    {
        SurfaceAtlasUAV[uint3(atlasCoord, DIRECT_LIGHT_LAYER)] = float4(0, 0, 0, 0);
        return;
    }

    float4 normalSample = SurfaceAtlas.SampleLevel(LinearSampler, float3(atlasUV, NORMAL_LAYER), 0);
    float3 worldNormal = normalize(normalSample.xyz * 2.0 - 1.0);

    float shadow = SampleShadow(worldPos);

    float3 sunDir = -normalize(SunDirection);
    float NdotL = saturate(dot(sunDir, worldNormal));

    float3 directLight = NdotL * SunColor.rgb * SunColor.a * shadow;

    for (int lightIdx = 0; lightIdx < NumLights; lightIdx++)
    {
        if (!IsLightEnabledDL((uint)lightIdx, card.LightMask))
            continue;

        DLLight light = LightsArray[lightIdx];
        float3 lightPos = light.WorldPosition;
        float3 pixelToLight = lightPos - worldPos;
        float dist = length(pixelToLight);
        float3 lightDir = pixelToLight / dist;

        float falloff = saturate(RangeMapDL(dist, light.InnerRadius, light.OuterRadius, 1.0, 0.0));
        falloff = SmoothStep3DL(falloff);

        float lightNdotL = saturate(dot(lightDir, worldNormal));
        float attenuation = falloff * light.Color.a * lightNdotL;

        float pointShadow = 1.0;
        int slot = GetShadowSlotForLightDL(lightIdx);
        if (slot >= 0)
            pointShadow = SamplePointShadowDL(slot, worldPos, lightPos);

        directLight += attenuation * light.Color.rgb * pointShadow;
    }

    float3 finalLight = directLight * albedo.rgb * (1.0 / 3.14159265359);

    SurfaceAtlasUAV[uint3(atlasCoord, DIRECT_LIGHT_LAYER)] = float4(finalLight, 1.0);
}
