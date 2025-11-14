static const uint s_maxCardsPerBatch = 256;

cbuffer CameraConstants : register(b1) 
{
    float4x4 WorldToCameraTransform;
    float4x4 CameraToRenderTransform;
    float4x4 RenderToClipTransform;
    float3 CameraWorldPosition;
    float padding;
}

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

cbuffer SurfaceCacheConstants : register(b12)
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

Texture2D<float4> g_GBufferAlbedo : register(t200);
Texture2D<float4> g_GBufferNormal : register(t201);
Texture2D<float4> g_GBufferMaterial : register(t202);
Texture2D<float2> g_GBufferMotion : register(t203);
Texture2D<float> g_DepthBuffer : register(t204);

Texture2DArray<float4> g_SurfaceAtlas : register(t205);
StructuredBuffer<SurfaceCardMetadata> g_CardMetadata : register(t206);

SamplerState g_sampler : register(s0);

#define LAYER_ALBEDO 0
#define LAYER_NORMAL 1
#define LAYER_MATERIAL 2
#define LAYER_DIRECT_LIGHT 4

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

float3 ReconstructWorldPosition(float2 uv, float depth)
{
    float2 ndc = uv * 2.0 - 1.0;
    ndc.y = -ndc.y;
    
    float4 clipPos = float4(ndc, depth, 1.0);
    float4 worldPos = mul(ViewProjInverse, clipPos);
    return worldPos.xyz / worldPos.w;
}


struct VSOutput 
{
    float4 Position : SV_POSITION;
    float2 TexCoord : TEXCOORD;
};

VSOutput CompositeVS(uint vertexID : SV_VertexID) 
{
    VSOutput output;
    float2 uv = float2((vertexID << 1) & 2, vertexID & 2);
    output.TexCoord = uv;
    output.Position = float4(uv * 2.0f - 1.0f, 0.0f, 1.0f);
    return output;
}

float4 CompositePS(VSOutput input) : SV_TARGET 
{
    uint2 pixelCoord = uint2(input.Position.xy);
    
    float depth = g_DepthBuffer[pixelCoord];
    if (depth >= 1.0)
        return float4(0.1, 0.15, 0.3, 1.0);
    
    float3 worldPos = ReconstructWorldPosition(input.TexCoord, depth);
    float3 normal = normalize(g_GBufferNormal[pixelCoord].xyz * 2.0 - 1.0);
    float4 albedo = g_GBufferAlbedo[pixelCoord];
    
    const int MAX_SAMPLES = 3;
    int bestIndices[MAX_SAMPLES];
    float bestWeights[MAX_SAMPLES];
    
    for (int j = 0; j < MAX_SAMPLES; j++)
    {
        bestIndices[j] = -1;
        bestWeights[j] = 0.0;
    }
    
    for (uint i = 0; i < ActiveCardCount; i++)
    {
        uint vec4Index = i / 4;
        uint component = i % 4;
        uint idx = DirtyCardIndices[vec4Index][component];
        SurfaceCardMetadata card = g_CardMetadata[idx];
        
        float3 cardNormal = GetLocalNormalFromDirection(card.Direction);
        float weight = max(0.0, dot(normal, cardNormal));
        
        if (weight < 0.01) continue;
        
        for (int k = 0; k < MAX_SAMPLES; k++)
        {
            if (weight > bestWeights[k])
            {
                for (int m = MAX_SAMPLES - 1; m > k; m--)
                {
                    bestWeights[m] = bestWeights[m - 1];
                    bestIndices[m] = bestIndices[m - 1];
                }
                bestWeights[k] = weight;
                bestIndices[k] = i;
                break;
            }
        }
    }
    
    float3 totalLight = float3(0, 0, 0);
    float totalWeight = 0.0;
    
    for (int s = 0; s < MAX_SAMPLES; s++)
    {
        if (bestIndices[s] < 0) continue;
        
        uint i = bestIndices[s];
        uint vec4Index = i / 4;
        uint component = i % 4;
        uint idx = DirtyCardIndices[vec4Index][component];
        SurfaceCardMetadata card = g_CardMetadata[idx];
        
        float3 axisX = GetLocalAxisX(card.Direction);
        float3 axisY = GetLocalAxisY(card.Direction);
        
        float3 localVec = worldPos - card.Origin;
        
        float2 localUV;
        localUV.x = dot(localVec, axisX) / card.WorldSize.x;
        localUV.y = dot(localVec, axisY) / card.WorldSize.y;
        
        if (localUV.x < -0.5 || localUV.x > 0.5 || localUV.y < -0.5 || localUV.y > 0.5)
            continue;
        
        // ✅ 直接计算，删除冗余的 if
        float2 exactAtlasPos = float2(card.AtlasCoord) * float(TileSize) + (localUV + 0.5) * float2(card.Resolution);
        float2 atlasUV = (exactAtlasPos + 0.5) / float2(AtlasWidth, AtlasHeight);
        
        float4 cachedNormalPacked = g_SurfaceAtlas.SampleLevel(g_sampler, float3(atlasUV, LAYER_NORMAL), 0);
        
        if (cachedNormalPacked.a < 0.01) continue;
        
        float3 cachedNormal = normalize(cachedNormalPacked.xyz * 2.0 - 1.0);
        float normalMatch = dot(normal, cachedNormal);
        
        if (normalMatch < 0.5) continue;
        
        float4 cachedLight = g_SurfaceAtlas.SampleLevel(g_sampler, float3(atlasUV, LAYER_DIRECT_LIGHT), 0);
        
        if (cachedLight.a > 0.01)
        {
            float weight = bestWeights[s] * normalMatch;
            totalLight += cachedLight.rgb * weight;
            totalWeight += weight;
        }
    }
    
    if (totalWeight > 0.01)
    {
        float3 blendedLight = totalLight / totalWeight;
        float3 finalColor = albedo.rgb * blendedLight;
        return float4(finalColor, 1.0);
    }
    
    float3 finalColor = albedo.rgb * 0.5;
    return float4(finalColor, 1.0);
}