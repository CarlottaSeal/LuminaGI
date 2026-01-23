//=============================================================================
// ScreenSpaceTemporalFilter.hlsl
// 屏幕空间时间重投影滤波
//
// 功能：
// 1. 使用世界坐标重投影到上一帧屏幕位置
// 2. 采样历史缓冲
// 3. 颜色邻域钳制 (防止 ghosting)
// 4. 深度验证 (检测遮挡变化)
// 5. 自适应混合
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

//=============================================================================
// 资源绑定
//=============================================================================

// 当前帧间接光照 (FinalGather 的原始输出)
Texture2D<float4> CurrentIndirect : register(REG_INDIRECT_RAW_SRV);  // t434 - m_screenIndirectRaw

// 历史缓冲 (上一帧的滤波结果)
Texture2D<float4> HistoryIndirect : register(REG_PREV_RADIANCE_SRV);   // t419

// GBuffer
Texture2D<float4> GBufferWorldPos : register(REG_GBUFFER_WORLDPOS);    // t217
Texture2D<float4> GBufferNormal   : register(REG_GBUFFER_NORMAL);      // t215
Texture2D<float>  DepthBuffer     : register(REG_DEPTH_BUFFER);        // t218

// 输出 (写回 ScreenIndirectLighting)
RWTexture2D<float4> FilteredOutput : register(REG_INDIRECT_LIGHT_UAV);  // u414

// 采样器
SamplerState LinearSampler : register(s1);

//=============================================================================
// 常量
//=============================================================================

static const float DEPTH_REJECT_THRESHOLD = 0.1f;   // 深度差异阈值
static const float COLOR_BOX_SCALE = 1.25f;         // 颜色钳制范围缩放
static const float BLEND_FACTOR_MIN = 0.02f;        // 最小混合因子 (更多历史)
static const float BLEND_FACTOR_MAX = 0.25f;        // 最大混合因子 (更多当前帧)

//=============================================================================
// 辅助函数
//=============================================================================

// 世界坐标到上一帧屏幕 UV
float3 WorldToPrevClipPos(float3 worldPos)
{
    float4 cameraPos = mul(PrevWorldToCamera, float4(worldPos, 1.0f));
    float4 renderPos = mul(PrevCameraToRender, cameraPos);
    float4 clipPos = mul(PrevRenderToClip, renderPos);
    return clipPos.xyz / clipPos.w;
}

float2 WorldToPrevScreenUV(float3 worldPos)
{
    float3 clipPos = WorldToPrevClipPos(worldPos);
    float2 ndc = clipPos.xy;
    ndc.y = -ndc.y;
    return ndc * 0.5f + 0.5f;
}

// 计算 3x3 邻域的颜色范围 (用于 clamp 防止 ghosting)
void ComputeColorBounds(uint2 coord, out float3 minColor, out float3 maxColor, out float3 avgColor)
{
    minColor = float3(1e10, 1e10, 1e10);
    maxColor = float3(-1e10, -1e10, -1e10);
    avgColor = float3(0, 0, 0);
    float count = 0;

    [unroll]
    for (int y = -1; y <= 1; y++)
    {
        [unroll]
        for (int x = -1; x <= 1; x++)
        {
            int2 sampleCoord = int2(coord) + int2(x, y);
            sampleCoord = clamp(sampleCoord, int2(0, 0), int2(ScreenWidth - 1, ScreenHeight - 1));

            float3 color = CurrentIndirect[sampleCoord].rgb;
            minColor = min(minColor, color);
            maxColor = max(maxColor, color);
            avgColor += color;
            count += 1.0f;
        }
    }

    avgColor /= count;

    // 扩展范围以允许一些变化
    float3 colorCenter = (minColor + maxColor) * 0.5f;
    float3 colorExtent = (maxColor - minColor) * 0.5f * COLOR_BOX_SCALE;
    minColor = colorCenter - colorExtent;
    maxColor = colorCenter + colorExtent;
}

// RGB 到 YCoCg 颜色空间 (更好的 clamp)
float3 RGBToYCoCg(float3 rgb)
{
    return float3(
        0.25f * rgb.r + 0.5f * rgb.g + 0.25f * rgb.b,
        0.5f * rgb.r - 0.5f * rgb.b,
        -0.25f * rgb.r + 0.5f * rgb.g - 0.25f * rgb.b
    );
}

float3 YCoCgToRGB(float3 ycocg)
{
    return float3(
        ycocg.x + ycocg.y - ycocg.z,
        ycocg.x + ycocg.z,
        ycocg.x - ycocg.y - ycocg.z
    );
}

//=============================================================================
// 主计算着色器
//=============================================================================

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pixelCoord = dispatchThreadID.xy;

    if (pixelCoord.x >= ScreenWidth || pixelCoord.y >= ScreenHeight)
        return;

    float2 screenUV = (float2(pixelCoord) + 0.5f) / float2(ScreenWidth, ScreenHeight);

    // 读取当前帧数据
    float3 currentColor = CurrentIndirect[pixelCoord].rgb;
    float currentDepth = DepthBuffer[pixelCoord];
    float3 worldPos = GBufferWorldPos[pixelCoord].rgb;
    float3 worldNormal = GBufferNormal[pixelCoord].rgb * 2.0f - 1.0f;

    // 天空像素直接输出当前帧
    if (currentDepth >= 0.9999f)
    {
        FilteredOutput[pixelCoord] = float4(currentColor, 1.0f);
        return;
    }

    // 计算上一帧的屏幕 UV (重投影)
    float2 historyUV = WorldToPrevScreenUV(worldPos);

    // 检查历史 UV 是否有效 (在屏幕内)
    bool validHistory = all(historyUV >= 0.0f) && all(historyUV <= 1.0f);

    float blendFactor = BLEND_FACTOR_MAX;  // 默认偏向当前帧
    float3 historyColor = currentColor;

    if (validHistory)
    {
        // 双线性采样历史
        historyColor = HistoryIndirect.SampleLevel(LinearSampler, historyUV, 0).rgb;

        // 计算邻域颜色范围
        float3 minColor, maxColor, avgColor;
        ComputeColorBounds(pixelCoord, minColor, maxColor, avgColor);

        // 在 YCoCg 空间做 clamp (更好的效果)
        float3 historyYCoCg = RGBToYCoCg(historyColor);
        float3 minYCoCg = RGBToYCoCg(minColor);
        float3 maxYCoCg = RGBToYCoCg(maxColor);

        // Clamp 历史颜色到当前帧邻域范围
        historyYCoCg = clamp(historyYCoCg, minYCoCg, maxYCoCg);
        historyColor = YCoCgToRGB(historyYCoCg);

        // 计算历史与当前的差异，用于自适应混合
        float colorDiff = length(historyColor - currentColor) / (length(currentColor) + 0.001f);

        // 差异大时更多使用当前帧
        blendFactor = lerp(BLEND_FACTOR_MIN, BLEND_FACTOR_MAX, saturate(colorDiff * 2.0f));

        // 考虑首帧情况
        if (CurrentFrame < 2)
        {
            blendFactor = 1.0f;  // 首帧完全使用当前帧
        }
    }

    // 混合当前帧和历史
    float3 result = lerp(historyColor, currentColor, blendFactor);

    // 确保非负
    result = max(result, float3(0, 0, 0));

    FilteredOutput[pixelCoord] = float4(result, 1.0f);
}
