#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

Texture2D<float4> ProbeRadianceCurrent : register(REG_PROBE_RAD_SRV);

Texture2D<float4> HistoryA_SRV : register(REG_PROBE_RAD_HIST_SRV);
RWTexture2D<float4> HistoryA_UAV : register(REG_PROBE_RAD_HIST_UAV);

Texture2D<float4> HistoryB_SRV : register(REG_PROBE_RAD_HIST_B_SRV);
RWTexture2D<float4> HistoryB_UAV : register(REG_PROBE_RAD_HIST_B_UAV);

StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV);

static const float MAX_RADIANCE = 1.0f / 3.14159265359f;
static const float BASE_BLEND = 0.02f;  // 2% new frame - very stable (was 5%)

// Detect camera rotation magnitude — compare current and previous frame view matrices
float EstimateCameraRotation()
{
    // Extract forward direction from current and previous view matrices (third row)
    float3 currentForward = float3(WorldToCamera[0][2], WorldToCamera[1][2], WorldToCamera[2][2]);
    float3 prevForward = float3(PrevWorldToCamera[0][2], PrevWorldToCamera[1][2], PrevWorldToCamera[2][2]);

    // Compute directional change
    float dotProduct = saturate(dot(normalize(currentForward), normalize(prevForward)));

    // Return rotation factor: 0 = no rotation, 1 = large rotation
    // cos(5°) ≈ 0.996, cos(15°) ≈ 0.966, cos(30°) ≈ 0.866
    return saturate((1.0f - dotProduct) * 20.0f);  // Amplify small differences
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
