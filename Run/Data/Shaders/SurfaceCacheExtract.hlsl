static const uint s_maxCardsPerBatch = 256;
static const uint TILE_SIZE   = 64;   
static const uint THREADS_PER_GROUP   = 8; 
static const uint PIXELS_PER_THREAD = TILE_SIZE / THREADS_PER_GROUP; // 8 pixels per thread
static const uint MAX_LIGHTS = 128;

cbuffer SurfaceCacheConstants : register(b0)
{
    float ScreenWidth;
    float ScreenHeight;
    float AtlasWidth;
    float AtlasHeight;
    
    uint TileSize;
    uint TilesPerRow;
    uint CurrentFrame;
    uint ActiveCardCount;
    
    float4x4 ViewProj;
    float4x4 ViewProjInverse;
    float4x4 PrevViewProj;
    
    float3 CameraPosition;
    float TemporalBlend;
    
    uint4 DirtyCardIndices[s_maxCardsPerBatch/4];
};

struct SurfaceCardMetadata
{
    uint2 AtlasCoord;
    uint2 Resolution;
    
    float3 Origin;
    uint Direction;
    
    float2 WorldSize;
    uint MeshID;
    uint Padding1;
    
    uint4 LightMask;
    
    float3 Radiance;
    uint ProbeIndex;
    
    float2 MotionVec;
    uint PrevFrameCardIdx;
    uint Padding2;
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

cbuffer LightConstants : register(b1)
{
    float4 SunColor;
    float3 SunNormal;
    int NumLights;
    Light LightsArray[MAX_LIGHTS];
}

Texture2D<float4> GBufferAlbedo : register(t0);
Texture2D<float4> GBufferNormal : register(t1);
Texture2D<float4> GBufferMaterial : register(t2);
Texture2D<float2> GBufferMotion : register(t3);
Texture2D<float2> DepthBuffer : register(t4);
Texture2DArray<float4> PrevSurfaceAtlas : register(t5);
StructuredBuffer<SurfaceCardMetadata> CardMetadata : register(t6);

RWTexture2DArray<float4> SurfaceCacheAtlas : register(u0);

SamplerState PointSampler : register(s0);

#define LAYER_ALBEDO          0  
#define LAYER_NORMAL          1  
#define LAYER_MATERIAL        2  
#define LAYER_MOTION          3  
#define LAYER_DIRECT_LIGHT    4  

float3 GetLocalNormalFromDirection(uint dir)
{
    switch (dir) {
    case 0: return float3(1, 0, 0);
    case 1: return float3(-1, 0, 0);
    case 2: return float3(0, 1, 0);
    case 3: return float3(0, -1, 0);
    case 4: return float3(0, 0, 1);
    case 5: return float3(0, 0, -1);
    default: return float3(0, 1, 0);
    }
}

float3 GetLocalAxisX(uint dir)
{
    switch (dir)
	{
	case 0: return float3(0, 1, 0);
	case 1: return float3(0, 0, 1);
	case 2: return float3(-1, 0, 0);
	case 3: return float3(0, 0, 1);
	case 4: return float3(1, 0, 0);
	case 5: return float3(1, 0, 0);
	default: return float3(0, 1, 0);
	}
}

float3 GetLocalAxisY(uint dir)
{
    float3 normal = GetLocalNormalFromDirection(dir);
    float3 axisX = GetLocalAxisX(dir);
    return normalize(cross(normal, axisX));
}

float3 CardLocalToWorld(SurfaceCardMetadata card, float2 localUV)
{
    float3 normal = GetLocalNormalFromDirection(card.Direction);
    float3 axisX = GetLocalAxisX(card.Direction);
    float3 axisY = GetLocalAxisY(card.Direction);
    
    float2 offset = (localUV - 0.5) * card.WorldSize;
    return card.Origin + axisX * offset.x + axisY * offset.y;
}

float3 ReconstructWorldPosition(float2 screenUV, float depth)
{
    float2 ndc = screenUV * 2.0 - 1.0;

    ndc.y = -ndc.y;
    
    float4 clipPos = float4(ndc, depth, 1.0);
    float4 worldPos = mul(ViewProjInverse, clipPos);
    return worldPos.xyz / worldPos.w;
}

float RangeMapClamped(float inValue, float inStart, float inEnd, float outStart, float outEnd)
{
    float fraction = saturate((inValue - inStart) / (inEnd - inStart));
    return outStart + fraction * (outEnd - outStart);
}

float SmoothStep3(float x)
{
    return (3.0 * (x * x)) - (2.0 * x) * (x * x);
}

float3 ComputeDirectLighting(
    float3 worldPos,
    float3 albedo,
    float3 normal,
    float roughness,
    float metallic,
    SurfaceCardMetadata card)
{
    float3 pixelToCameraDir = normalize(CameraPosition - worldPos);
    float3 totalDiffuseLight = float3(0, 0, 0);
    float3 totalSpecularLight = float3(0, 0, 0);
    
    float glossiness = 1.0 - roughness;
    float specularExponent = lerp(1.0, 32.0, glossiness);
    float specularity = lerp(0.04, 1.0, metallic);
    
    // Sun lighting
    {
        float sunAmbience = 0.0;
        float sunlightStrength = SunColor.a * saturate(
            RangeMapClamped(dot(-SunNormal, normal), -sunAmbience, 1.0, 0.0, 1.0)
        );
        float3 diffuseLightFromSun = sunlightStrength * SunColor.rgb;
        totalDiffuseLight += diffuseLightFromSun;
        
        float3 pixelToSunDir = -SunNormal;
        float3 sunIdealReflectionDir = normalize(pixelToSunDir + pixelToCameraDir);
        float sunSpecularDot = saturate(dot(sunIdealReflectionDir, normal));
        float sunSpecularStrength = glossiness * SunColor.a * pow(sunSpecularDot, specularExponent);
        float3 sunSpecularLight = sunSpecularStrength * SunColor.rgb;
        totalSpecularLight += sunSpecularLight;
    }
    
    // Point/Spot lights
    [unroll]
    for (uint word = 0; word < 4; word++)
    {
        uint mask = card.LightMask[word];
        uint baseIndex = word * 32;
        while (mask != 0)
        {
            uint bit = firstbitlow(mask);
            mask &= ~(1u << bit);
            
            uint lightIndex = baseIndex + bit;  //- 1;  //减掉太阳光的占位指数
            if (lightIndex >= NumLights) continue;
            
            Light light = LightsArray[lightIndex];
            
            float3 pixelToLightDisp = light.WorldPosition - worldPos;
            float3 pixelToLightDir = normalize(pixelToLightDisp);
            float3 lightToPixelDir = -pixelToLightDir;
            float distToLight = length(pixelToLightDisp);
            
            float falloff = saturate(RangeMapClamped(
                distToLight, light.InnerRadius, light.OuterRadius, 1.0, 0.0
            ));
            falloff = SmoothStep3(falloff);
            
            float penumbra = saturate(RangeMapClamped(
                dot(light.SpotForward, lightToPixelDir),
                light.OuterDotThreshold, light.InnerDotThreshold, 0.0, 1.0
            ));
            penumbra = SmoothStep3(penumbra);
            
            float lightStrength = penumbra * falloff * light.Color.a * saturate(
                RangeMapClamped(dot(pixelToLightDir, normal), -light.Ambience, 1.0, 0.0, 1.0)
            );
            float3 diffuseLight = lightStrength * light.Color.rgb;
            totalDiffuseLight += diffuseLight;
            
            float3 idealReflectionDir = normalize(pixelToCameraDir + pixelToLightDir);
            float specularDot = saturate(dot(idealReflectionDir, normal));
            float specularStrength = glossiness * light.Color.a * pow(specularDot, specularExponent);
            specularStrength *= falloff * penumbra;
            float3 specularLight = specularStrength * light.Color.rgb;
            totalSpecularLight += specularLight;
        }
    }
    
    float3 diffuse = albedo * (1.0 - metallic);
    float3 finalLighting = saturate(totalDiffuseLight) * diffuse + 
                          totalSpecularLight * specularity;
    
    return finalLighting;
}

float2 WorldToAtlasUV(float3 worldPos, SurfaceCardMetadata card)
{
    float3 normal = GetLocalNormalFromDirection(card.Direction);
    float3 axisX = GetLocalAxisX(card.Direction);
    float3 axisY = GetLocalAxisY(card.Direction);
    
    float3 localVec = worldPos - card.Origin;
    float2 localUV;
    localUV.x = dot(localVec, axisX) / card.WorldSize.x;
    localUV.y = dot(localVec, axisY) / card.WorldSize.y;

    float2 exactAtlasPos = float2(card.AtlasCoord)* TileSize + (localUV + 0.5) * float2(card.Resolution);
    return (exactAtlasPos + 0.5) / float2(AtlasWidth, AtlasHeight);
}

float2 ReprojectToPreviousFrame(float3 worldPos)
{
    // 将世界坐标投影到上一帧的屏幕空间
    float4 prevClipPos = mul(PrevViewProj, float4(worldPos, 1.0));
    prevClipPos /= prevClipPos.w;
    
    // 转换到UV坐标
    float2 prevUV;
    prevUV.x = prevClipPos.x * 0.5 + 0.5;
    prevUV.y = -prevClipPos.y * 0.5 + 0.5;
    
    return prevUV;
}


[numthreads(THREADS_PER_GROUP, THREADS_PER_GROUP, 1)]
void ExtractTileCS(uint3 groupID : SV_GroupID, uint3 threadID : SV_GroupThreadID,
                   uint3 dispatchThreadID : SV_DispatchThreadID, uint gi : SV_GroupIndex)
{
     // groupID.x = card 索引 (0 到 ActiveCardCount-1)
    // groupID.y = Y 方向的线程组索引 (0-7)
    // groupID.z = Z 方向的线程组索引 (0-7)
    // threadID.xy = 线程组内的线程位置 (0-7, 0-7)
    
    uint cardIndex = groupID.x;
    if (cardIndex >= ActiveCardCount) return;

    uint vec4Index = cardIndex / 4;
    uint component = cardIndex % 4;
    uint dirtyIndex = DirtyCardIndices[vec4Index][component];
    SurfaceCardMetadata card = CardMetadata[dirtyIndex];
    
    // groupID.yz 是线程组在 card 内的 2D 位置
    // threadID.xy 是线程在线程组内的位置
    uint2 cardPixel = groupID.yz * THREADS_PER_GROUP + threadID.xy;
    
    if (any(cardPixel >= card.Resolution)) return;

    float2 cardUV = (cardPixel + 0.5) / float2(card.Resolution);
    //float2 uv = float2(cardUV.y, 1-cardUV.x);
    float3 worldPos = CardLocalToWorld(card, cardUV);
    
    // 投影到当前帧屏幕
    float4 clipPos = mul(ViewProj, float4(worldPos, 1.0));
    clipPos /= clipPos.w;
    float2 screenUV = clipPos.xy * 0.5 + 0.5;
    screenUV.y = 1.0 - screenUV.y;
    
    if (any(screenUV < 0.0) || any(screenUV > 1.0))
        return;
    
    // 从 GBuffer 采样
    float depth = DepthBuffer.SampleLevel(PointSampler, screenUV, 0);
    if (depth >= 1.0) return;

float3 gbufferWorldPos = ReconstructWorldPosition(screenUV, depth);
    
    //float3 gbufferWorldPos = ReconstructWorldPosition(screenUV, depth);
    //float dist = distance(gbufferWorldPos, worldPos);
    //if (dist > 0.5) return;
float4 cardClipPos = mul(ViewProj, float4(worldPos, 1.0));
float cardDepth = cardClipPos.z / cardClipPos.w;

// 比较深度差异
float depthDiff = abs(depth - cardDepth);
if (depthDiff > 0.1)  // 深度差异太大，可能是遮挡
    return;
    
    float4 albedo = GBufferAlbedo.SampleLevel(PointSampler, screenUV, 0);
    float4 normalPacked = GBufferNormal.SampleLevel(PointSampler, screenUV, 0);
    float3 normal = normalize(normalPacked.xyz * 2.0 - 1.0);
    float4 material = GBufferMaterial.SampleLevel(PointSampler, screenUV, 0);
    
    float3 cardNormal = GetLocalNormalFromDirection(card.Direction);
    float normalDot = dot(normal, cardNormal);
    if (abs(normalDot) < 0.3) return;
    
    float3 directLight = ComputeDirectLighting(
        gbufferWorldPos, albedo.rgb, normal, material.r, material.g, card);
    
    //Temporal Reprojection
    float4 finalAlbedo = albedo;
    //float4 finalNormal = float4(normal * 0.5 + 0.5, 1.0);
    float4 finalNormal = float4(normal * 0.5 + 0.5, 1.0); 
    float4 finalMaterial = material;
    float4 finalDirectLight = float4(directLight, 1.0);
    
    if (TemporalBlend > 0.01)
{
    // ✅ 用 gbufferWorldPos 重投影
    float2 prevUV = ReprojectToPreviousFrame(gbufferWorldPos);
    
    if (all(prevUV >= 0.0 && prevUV <= 1.0))
    {
        // ✅ 用 gbufferWorldPos 转换 Atlas UV
        float2 prevAtlasUV = WorldToAtlasUV(gbufferWorldPos, card);
        
        float4 histAlbedo = PrevSurfaceAtlas.SampleLevel(PointSampler, 
            float3(prevAtlasUV, LAYER_ALBEDO), 0);
        float4 histNormal = PrevSurfaceAtlas.SampleLevel(PointSampler, 
            float3(prevAtlasUV, LAYER_NORMAL), 0);
        float4 histMaterial = PrevSurfaceAtlas.SampleLevel(PointSampler, 
            float3(prevAtlasUV, LAYER_MATERIAL), 0);
        float4 histDirectLight = PrevSurfaceAtlas.SampleLevel(PointSampler, 
            float3(prevAtlasUV, LAYER_DIRECT_LIGHT), 0);
        
        // ✅ 验证：检查 Albedo 和法线
        if (histAlbedo.a > 0.01)
        {
            float3 histNormalWorld = normalize(histNormal.xyz * 2.0 - 1.0);
            float normalSimilarity = dot(normal, histNormalWorld);
            
            if (normalSimilarity > 0.8)
            {
                finalAlbedo = lerp(albedo, histAlbedo, TemporalBlend);
                finalNormal = lerp(float4(normal * 0.5 + 0.5, 1.0), histNormal, TemporalBlend);
                finalMaterial = lerp(material, histMaterial, TemporalBlend);
                finalDirectLight = lerp(float4(directLight, 1.0), histDirectLight, TemporalBlend);
            }
        }
    }
}

    uint2 atlasCoord = card.AtlasCoord * TileSize  + cardPixel;
    SurfaceCacheAtlas[uint3(atlasCoord, LAYER_ALBEDO)] = finalAlbedo;
    SurfaceCacheAtlas[uint3(atlasCoord, LAYER_NORMAL)] = finalNormal;
    SurfaceCacheAtlas[uint3(atlasCoord, LAYER_MATERIAL)] = finalMaterial;
    SurfaceCacheAtlas[uint3(atlasCoord, LAYER_DIRECT_LIGHT)] = finalDirectLight;
}