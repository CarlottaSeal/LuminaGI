// VS/PS pass — renders each Card quad onto mesh surfaces via instancing
//
// WorldOrigin/AxisX/AxisY/Normal in CardMetadata are already in world space
// Inverse transform (quadUV -> worldPos):
//   localOffset.x = (quadUV.x - 0.5) * Size.x
//   localOffset.y = (quadUV.y - 0.5) * Size.y
//   worldPos = WorldOrigin + localOffset.x * AxisX + localOffset.y * AxisY

// Debug display mode (change value and recompile to switch)
// 0 = Normal render
// 1 = Sample UV (R=U, G=V)
// 2 = WorldAxisX
// 3 = WorldAxisY
// 4 = Card index color
// 5 = Direction color
// 6 = WorldOrigin (frac visualization)
// 7 = WorldSize (R=X, G=Y)
// 8 = WorldNormal
// 9 = Reconstructed world position (frac visualization)
#define DEBUG_MODE 0

cbuffer VisualizationCB : register(b0)
{
    float4x4 WorldToCameraTransform;
    float4x4 CameraToRenderTransform;
    float4x4 RenderToClipTransform;
    uint SurfaceCacheLayer;      // 0-4: SurfaceCache layers, 5: RadiosityTrace
    uint AtlasSize;              // 4096
    uint ActiveCardCount;
    float Exposure;
};

// Radiosity constants
// Mode 6 is reserved for Radiosity to avoid conflict with CombinedLight (layer 5)
#define LAYER_INDIRECT_LIGHT 4
#define LAYER_RADIOSITY 6
#define RADIOSITY_PROBE_SPACING 4  // AtlasSize / ProbeGridSize = 4096 / 1024 = 4

// Must match SurfaceCardMetadata in CacheCommon.h exactly
struct CardMetadata
{
    uint AtlasX;
    uint AtlasY;
    uint ResolutionX;
    uint ResolutionY;

    float3 WorldOrigin;    // World-space origin
    float Padding0;

    float3 WorldAxisX;     // World-space X axis
    float ObjectID;

    float3 WorldAxisY;     // World-space Y axis
    float Padding2;

    float3 WorldNormal;    // World-space normal
    float Padding3;

    float2 WorldSize;
    uint Direction;
    uint GlobalCardID;

    uint4 LightMask;
};

StructuredBuffer<CardMetadata> g_CardMetadata : register(t382);
Texture2DArray<float4> g_SurfaceCacheAtlas : register(t381);
Texture2D<float4> g_RadiosityTraceResult : register(t393);  // Radiosity Probe Grid (1024x1024) - RADIOSITY_TRACE_RESULT_SRV

SamplerState g_PointSampler : register(s0);
SamplerState g_LinearSampler : register(s1);

struct VSInput
{
    float3 Position : POSITION;
    float2 UV : TEXCOORD0;
};

struct VSOutput
{
    float4 Position : SV_POSITION;
    float2 SampleUV : TEXCOORD0;
    nointerpolation uint CardIndex : TEXCOORD1;
    float3 DebugAxisX : TEXCOORD2;
    float3 DebugAxisY : TEXCOORD3;
};

// Vertex Shader
VSOutput VSMain(VSInput input, uint instanceID : SV_InstanceID)
{
    VSOutput output;

    if (instanceID >= ActiveCardCount)
    {
        output.Position = float4(0, 0, -1, 1);
        output.SampleUV = float2(0, 0);
        output.CardIndex = 0;
        output.DebugAxisX = float3(0, 0, 0);
        output.DebugAxisY = float3(0, 0, 0);
        return output;
    }

    CardMetadata card = g_CardMetadata[instanceID];

    // WorldOrigin/AxisX/AxisY/Normal are already in world space
    // No additional rotation transform needed
    float3 worldOrigin = card.WorldOrigin;
    float3 axisX = normalize(card.WorldAxisX);
    float3 axisY = normalize(card.WorldAxisY);
    float2 size = card.WorldSize;

    // World position reconstruction — inverse of CardCapture.hlsl transform
    //
    // Inverse transform (quadUV -> worldPos):
    //   localOffset.x = (quadUV.x - 0.5) * Size.x
    //   localOffset.y = (quadUV.y - 0.5) * Size.y
    //   worldPos = WorldOrigin + localOffset.x * AxisX + localOffset.y * AxisY

    float2 quadUV = input.UV;
    float2 localOffset;
    localOffset.x = (quadUV.x - 0.5) * size.x;
    localOffset.y = (quadUV.y - 0.5) * size.y;

    float3 worldPos = worldOrigin + axisX * localOffset.x + axisY * localOffset.y;

    // Transform to clip space
    float4 cameraPos = mul(WorldToCameraTransform, float4(worldPos, 1.0));
    float4 renderPos = mul(CameraToRenderTransform, cameraPos);
    float4 clipPos = mul(RenderToClipTransform, renderPos);

    output.Position = clipPos;
    output.SampleUV = quadUV;
    output.CardIndex = instanceID;
    output.DebugAxisX = axisX;
    output.DebugAxisY = axisY;

    #if DEBUG_MODE == 9
        output.DebugAxisX = worldPos;
    #endif

    return output;
}

// Pixel Shader
float4 PSMain(VSOutput input) : SV_Target0
{
    CardMetadata card = g_CardMetadata[input.CardIndex];

    // Debug modes
    #if DEBUG_MODE == 1
        // Sample UV
        return float4(input.SampleUV.x, input.SampleUV.y, 0, 1);
    #elif DEBUG_MODE == 2
        // WorldAxisX
        return float4(card.WorldAxisX * 0.5 + 0.5, 1);
    #elif DEBUG_MODE == 3
        // WorldAxisY
        return float4(card.WorldAxisY * 0.5 + 0.5, 1);
    #elif DEBUG_MODE == 4
        // Card index color
        float r = frac(input.CardIndex * 0.1234);
        float g = frac(input.CardIndex * 0.5678);
        float b = frac(input.CardIndex * 0.9012);
        return float4(r, g, b, 1);
    #elif DEBUG_MODE == 5
        // Direction color (0-5)
        float3 dirColors[6] = {
            float3(1, 0, 0),   // 0: +X red
            float3(0.5, 0, 0), // 1: -X dark red
            float3(0, 1, 0),   // 2: +Y green
            float3(0, 0.5, 0), // 3: -Y dark green
            float3(0, 0, 1),   // 4: +Z blue
            float3(0, 0, 0.5)  // 5: -Z dark blue
        };
        uint dir = min(card.Direction, 5u);
        return float4(dirColors[dir], 1);
    #elif DEBUG_MODE == 6
        // WorldOrigin
        return float4(frac(card.WorldOrigin * 0.1), 1);
    #elif DEBUG_MODE == 7
        // WorldSize
        return float4(card.WorldSize.x * 0.1, card.WorldSize.y * 0.1, 0, 1);
    #elif DEBUG_MODE == 8
        // WorldNormal
        return float4(card.WorldNormal * 0.5 + 0.5, 1);
    #elif DEBUG_MODE == 9
        // Reconstructed world position (frac)
        return float4(frac(input.DebugAxisX * 0.1), 1);
    #endif

    float2 sampleUV = saturate(input.SampleUV);

    // Edge feathering: fade out towards card edges
    // edgeDist: 0 = edge, 0.5 = center
    float2 edgeDist = min(sampleUV, 1.0 - sampleUV);
    float minEdgeDist = min(edgeDist.x, edgeDist.y);

    // Feather width in UV units (~2-3 pixels)
    float featherWidth = 2.0 / min(card.ResolutionX, card.ResolutionY);
    float edgeAlpha = saturate(minEdgeDist / featherWidth);

    // Smooth transition
    edgeAlpha = smoothstep(0.0, 1.0, edgeAlpha);

    // Compute UV coordinates in the atlas (for linear sampling)
    // Inset by 0.5 pixel to avoid sampling adjacent cards
    float2 cardUVMin = (float2(card.AtlasX, card.AtlasY) + 0.5) / float(AtlasSize);
    float2 cardUVMax = (float2(card.AtlasX + card.ResolutionX, card.AtlasY + card.ResolutionY) - 0.5) / float(AtlasSize);
    float2 atlasUV = lerp(cardUVMin, cardUVMax, sampleUV);

    // Integer coordinates for Load (alpha detection)
    uint2 localPixel = uint2(sampleUV * float2(card.ResolutionX, card.ResolutionY));
    localPixel = min(localPixel, uint2(card.ResolutionX - 1, card.ResolutionY - 1));
    uint2 atlasPixel = uint2(card.AtlasX, card.AtlasY) + localPixel;

    float4 albedo = g_SurfaceCacheAtlas.Load(int4(atlasPixel, 0, 0));
    if (albedo.a < 0.1 || edgeAlpha < 0.01)
        discard;

    float3 result;

    if (SurfaceCacheLayer == LAYER_RADIOSITY)
    {
        // Radiosity mode: sample from RadiosityTraceResult
        uint2 probeCoord = atlasPixel / RADIOSITY_PROBE_SPACING;
        float4 radData = g_RadiosityTraceResult.Load(int3(probeCoord, 0));

        result = radData.rgb;
    }
    else
    {
        // Normal SurfaceCache mode — linear sampling to reduce aliasing
        float4 sampled = g_SurfaceCacheAtlas.SampleLevel(g_LinearSampler, float3(atlasUV, SurfaceCacheLayer), 0);
        result = sampled.rgb;

        // Normal layer requires decoding
        if (SurfaceCacheLayer == 1)
        {
            float3 n = sampled.rgb * 2.0 - 1.0;
            result = normalize(n) * 0.5 + 0.5;
        }

        // (auto-boost for Indirect disabled — showing raw values)
    }

    return float4(result * Exposure, edgeAlpha);
}
