//=============================================================================
// TemporalAccumulation.hlsl
// Pass 8: Probe-level temporal with conservative blending
// Uses exponential moving average without reprojection (simpler, more stable)
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

Texture2D<float4> ProbeRadianceCurrent : register(REG_PROBE_RAD_SRV);

Texture2D<float4> HistoryA_SRV : register(REG_PROBE_RAD_HIST_SRV);
RWTexture2D<float4> HistoryA_UAV : register(REG_PROBE_RAD_HIST_UAV);

Texture2D<float4> HistoryB_SRV : register(REG_PROBE_RAD_HIST_B_SRV);
RWTexture2D<float4> HistoryB_UAV : register(REG_PROBE_RAD_HIST_B_UAV);

StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV);

static const float MAX_RADIANCE = 1.0f / 3.14159265359f;   // SimLumen: 1/PI ≈ 0.318
static const float BASE_BLEND = 0.02f;  // 2% new frame - very stable (was 5%)

// 检测相机旋转量 - 通过比较当前和前一帧的view矩阵
float EstimateCameraRotation()
{
    // 提取当前和前一帧相机的前向方向 (view matrix 的第三行)
    float3 currentForward = float3(WorldToCamera[0][2], WorldToCamera[1][2], WorldToCamera[2][2]);
    float3 prevForward = float3(PrevWorldToCamera[0][2], PrevWorldToCamera[1][2], PrevWorldToCamera[2][2]);

    // 计算方向变化
    float dotProduct = saturate(dot(normalize(currentForward), normalize(prevForward)));

    // 返回旋转因子：0 = 没有旋转，1 = 大幅旋转
    // cos(5°) ≈ 0.996, cos(15°) ≈ 0.966, cos(30°) ≈ 0.866
    return saturate((1.0f - dotProduct) * 20.0f);  // 放大差异
}

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 rayTexCoord = dispatchThreadID.xy;

    if (rayTexCoord.x >= RaysTexWidth || rayTexCoord.y >= RaysTexHeight)
        return;

    // OctahedronWidth x OctahedronHeight per probe layout
    uint2 probeCoord = uint2(rayTexCoord.x / OctahedronWidth, rayTexCoord.y / OctahedronHeight);
    uint probeIndex = probeCoord.y * ProbeGridWidth + probeCoord.x;

    float4 current = ProbeRadianceCurrent[rayTexCoord];

    float4 history;
    if (UseHistoryBufferB)
        history = HistoryB_SRV[rayTexCoord];
    else
        history = HistoryA_SRV[rayTexCoord];

    float3 currentRadiance = float3(0, 0, 0);
    bool validCurrent = current.w > 0.001f;

    if (validCurrent)
    {
        currentRadiance = current.rgb / current.w;

        float maxVal = max(max(currentRadiance.r, currentRadiance.g), currentRadiance.b);
        if (maxVal > MAX_RADIANCE)
            currentRadiance *= MAX_RADIANCE / maxVal;
    }

    float3 result;
    bool hasValidHistory = history.w > 0.5f;

    float cameraRotation = EstimateCameraRotation();

    float blendFactor = lerp(BASE_BLEND, 0.10f, cameraRotation);

    if (hasValidHistory && validCurrent)
    {
        float historyLum = Luminance(history.rgb);
        float currentLum = Luminance(currentRadiance);
        float lumRatio = (historyLum + 0.01f) / (currentLum + 0.01f);

        if (lumRatio > 5.0f || lumRatio < 0.2f)
        {
            blendFactor = max(blendFactor, 0.3f);
        }

        result = lerp(history.rgb, currentRadiance, blendFactor);
    }
    else
    {
        result = currentRadiance;
    }

    result = max(result, float3(0, 0, 0));
    if (any(isnan(result)) || any(isinf(result)))
        result = float3(0, 0, 0);

    float resultMax = max(max(result.r, result.g), result.b);
    if (resultMax > MAX_RADIANCE)
        result *= MAX_RADIANCE / resultMax;

    float4 output = float4(result, 1.0f);
    if (UseHistoryBufferB)
        HistoryA_UAV[rayTexCoord] = output;
    else
        HistoryB_UAV[rayTexCoord] = output;
}
