//=============================================================================
// GIVisualizationSurfaceCache.hlsl
// VS/PS Pass - Instance 渲染每个 Card 到模型表面
//
// CardMetadata 中的 WorldOrigin/AxisX/AxisY/Normal 已经是世界空间坐标
// 逆变换 (quadUV -> worldPos):
//   localOffset.x = (quadUV.x - 0.5) * Size.x
//   localOffset.y = (quadUV.y - 0.5) * Size.y
//   worldPos = WorldOrigin + localOffset.x * AxisX + localOffset.y * AxisY
//=============================================================================

// 调试显示模式 (修改此值并重新编译shader可切换)
// 0 = 正常渲染
// 1 = 显示采样UV (红=U, 绿=V)
// 2 = 显示WorldAxisX
// 3 = 显示WorldAxisY
// 4 = 显示CardIndex颜色
// 5 = 显示Direction颜色
// 6 = 显示WorldOrigin (frac可视化)
// 7 = 显示WorldSize (红=X, 绿=Y)
// 8 = 显示WorldNormal
// 9 = 显示重建的世界位置 (frac可视化)
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

// Radiosity相关常量
// 注意：使用6作为特殊的Radiosity模式，避免与CombinedLight(layer 5)冲突
#define LAYER_RADIOSITY 6
#define RADIOSITY_PROBE_SPACING 4  // AtlasSize / ProbeGridSize = 4096 / 1024 = 4

// 必须与 CacheCommon.h 中的 SurfaceCardMetadata 完全匹配
struct CardMetadata
{
    uint AtlasX;
    uint AtlasY;
    uint ResolutionX;
    uint ResolutionY;

    float3 WorldOrigin;    // 已经是世界空间坐标
    float Padding0;

    float3 WorldAxisX;     // 已经是世界空间方向
    float ObjectID;

    float3 WorldAxisY;     // 已经是世界空间方向
    float Padding2;

    float3 WorldNormal;    // 已经是世界空间法线
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

//=============================================================================
// Vertex Shader
//=============================================================================
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

    // CardMetadata 中的 WorldOrigin/AxisX/AxisY/Normal 已经是世界空间
    // 不需要任何额外的rotation变换
    float3 worldOrigin = card.WorldOrigin;
    float3 axisX = normalize(card.WorldAxisX);
    float3 axisY = normalize(card.WorldAxisY);
    float2 size = card.WorldSize;

    // =========================================================================
    // 世界位置重建 - CardCapture.hlsl 的逆变换
    //
    // 逆变换 (quadUV -> worldPos):
    //   localOffset.x = (quadUV.x - 0.5) * Size.x
    //   localOffset.y = (quadUV.y - 0.5) * Size.y
    //   worldPos = WorldOrigin + localOffset.x * AxisX + localOffset.y * AxisY
    // =========================================================================

    float2 quadUV = input.UV;
    float2 localOffset;
    localOffset.x = (quadUV.x - 0.5) * size.x;
    localOffset.y = (quadUV.y - 0.5) * size.y;

    float3 worldPos = worldOrigin + axisX * localOffset.x + axisY * localOffset.y;

    // 变换到裁剪空间
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

//=============================================================================
// Pixel Shader
//=============================================================================
float4 PSMain(VSOutput input) : SV_Target0
{
    CardMetadata card = g_CardMetadata[input.CardIndex];

    // 调试模式
    #if DEBUG_MODE == 1
        // 显示采样UV
        return float4(input.SampleUV.x, input.SampleUV.y, 0, 1);
    #elif DEBUG_MODE == 2
        // 显示WorldAxisX (metadata原始值，可视化)
        return float4(card.WorldAxisX * 0.5 + 0.5, 1);
    #elif DEBUG_MODE == 3
        // 显示WorldAxisY (metadata原始值，可视化)
        return float4(card.WorldAxisY * 0.5 + 0.5, 1);
    #elif DEBUG_MODE == 4
        // 显示CardIndex颜色
        float r = frac(input.CardIndex * 0.1234);
        float g = frac(input.CardIndex * 0.5678);
        float b = frac(input.CardIndex * 0.9012);
        return float4(r, g, b, 1);
    #elif DEBUG_MODE == 5
        // 显示Direction颜色 (0-5)
        float3 dirColors[6] = {
            float3(1, 0, 0),   // 0: +X 红
            float3(0.5, 0, 0), // 1: -X 暗红
            float3(0, 1, 0),   // 2: +Y 绿
            float3(0, 0.5, 0), // 3: -Y 暗绿
            float3(0, 0, 1),   // 4: +Z 蓝
            float3(0, 0, 0.5)  // 5: -Z 暗蓝
        };
        uint dir = min(card.Direction, 5u);
        return float4(dirColors[dir], 1);
    #elif DEBUG_MODE == 6
        // 显示WorldOrigin位置
        return float4(frac(card.WorldOrigin * 0.1), 1);
    #elif DEBUG_MODE == 7
        // 显示WorldSize
        return float4(card.WorldSize.x * 0.1, card.WorldSize.y * 0.1, 0, 1);
    #elif DEBUG_MODE == 8
        // 显示WorldNormal (metadata原始值，可视化)
        return float4(card.WorldNormal * 0.5 + 0.5, 1);
    #elif DEBUG_MODE == 9
        // 显示重建的世界位置 (frac可视化)
        return float4(frac(input.DebugAxisX * 0.1), 1);
    #endif

    float2 sampleUV = saturate(input.SampleUV);

    // 边缘羽化：计算距离边缘的距离，越近边缘越透明
    // edgeDist: 0 = 边缘, 0.5 = 中心
    float2 edgeDist = min(sampleUV, 1.0 - sampleUV);
    float minEdgeDist = min(edgeDist.x, edgeDist.y);

    // 羽化宽度（以 UV 为单位，约 2-3 像素）
    float featherWidth = 2.0 / min(card.ResolutionX, card.ResolutionY);
    float edgeAlpha = saturate(minEdgeDist / featherWidth);

    // 平滑过渡
    edgeAlpha = smoothstep(0.0, 1.0, edgeAlpha);

    // 计算在 Atlas 中的 UV 坐标（用于线性采样）
    // 添加 0.5 像素的内缩避免采样到相邻 card
    float2 cardUVMin = (float2(card.AtlasX, card.AtlasY) + 0.5) / float(AtlasSize);
    float2 cardUVMax = (float2(card.AtlasX + card.ResolutionX, card.AtlasY + card.ResolutionY) - 0.5) / float(AtlasSize);
    float2 atlasUV = lerp(cardUVMin, cardUVMax, sampleUV);

    // 用于 Load 的整数坐标（alpha 检测用）
    uint2 localPixel = uint2(sampleUV * float2(card.ResolutionX, card.ResolutionY));
    localPixel = min(localPixel, uint2(card.ResolutionX - 1, card.ResolutionY - 1));
    uint2 atlasPixel = uint2(card.AtlasX, card.AtlasY) + localPixel;

    float4 albedo = g_SurfaceCacheAtlas.Load(int4(atlasPixel, 0, 0));
    if (albedo.a < 0.1 || edgeAlpha < 0.01)
        discard;

    float3 result;

    if (SurfaceCacheLayer == LAYER_RADIOSITY)
    {
        // Radiosity模式：从RadiosityTraceResult采样
        uint2 probeCoord = atlasPixel / RADIOSITY_PROBE_SPACING;
        float4 radData = g_RadiosityTraceResult.Load(int3(probeCoord, 0));

        if (radData.w > 0.01)
        {
            result = radData.rgb;
        }
        else
        {
            result = float3(0.02, 0.02, 0.03);
        }
    }
    else
    {
        // 正常SurfaceCache模式 - 使用线性采样减少锯齿
        float4 sampled = g_SurfaceCacheAtlas.SampleLevel(g_LinearSampler, float3(atlasUV, SurfaceCacheLayer), 0);
        result = sampled.rgb;

        // Normal 层需要解码
        if (SurfaceCacheLayer == 1)
        {
            float3 n = sampled.rgb * 2.0 - 1.0;
            result = normalize(n) * 0.5 + 0.5;
        }
    }

    return float4(result * Exposure, edgeAlpha);
}
