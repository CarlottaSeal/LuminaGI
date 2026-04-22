#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

Texture2D<float4> CurrentIndirect : register(REG_INDIRECT_RAW_SRV);
Texture2D<float4> HistoryIndirect : register(REG_PREV_RADIANCE_SRV);
Texture2D<float4> GBufferWorldPos : register(REG_GBUFFER_WORLDPOS);
Texture2D<float4> GBufferNormal   : register(REG_GBUFFER_NORMAL);
Texture2D<float>  DepthBuffer     : register(REG_DEPTH_BUFFER);
Texture2D<float>  PrevDepthBuffer : register(REG_PREV_DEPTH_SRV);

RWTexture2D<float4> FilteredOutput : register(REG_INDIRECT_LIGHT_UAV);

SamplerState LinearSampler : register(s1);

static const float BLEND_STATIC  = 0.02f;
static const float BLEND_MOVING  = 0.15f;
static const float VELOCITY_THRESHOLD = 4.0f;
static const float DEPTH_TOLERANCE = 0.15f;

float EstimateCameraRotation()
{
    float3 currentForward = float3(WorldToCamera[0][2], WorldToCamera[1][2], WorldToCamera[2][2]);
    float3 prevForward = float3(PrevWorldToCamera[0][2], PrevWorldToCamera[1][2], PrevWorldToCamera[2][2]);
    float dotProduct = saturate(dot(normalize(currentForward), normalize(prevForward)));
    return saturate((1.0f - dotProduct) * 20.0f);
}

float3 PreFilterSpeckles(uint2 pixel, float3 centerColor, float centerDepth, float3 centerNormal)
{
    float3 sum = float3(0, 0, 0);
    float weightSum = 0.0f;
    float3 minColor = float3(1e10, 1e10, 1e10);
    float3 maxColor = float3(0, 0, 0);
    float centerLum = Luminance(centerColor);

    [unroll]
    for (int dy = -2; dy <= 2; dy++)
    {
        [unroll]
        for (int dx = -2; dx <= 2; dx++)
        {
            if (abs(dx) == 2 && abs(dy) == 2)
                continue;

            int2 p = clamp(int2(pixel) + int2(dx, dy), int2(0,0), int2(ScreenWidth-1, ScreenHeight-1));
            float3 sampleColor = CurrentIndirect[p].rgb;
            float sampleDepth = DepthBuffer[p];
            float3 sampleNormal = GBufferNormal[p].xyz * 2.0f - 1.0f;

            float depthDiff = abs(sampleDepth - centerDepth);
            float normalDot = max(0.0f, dot(normalize(sampleNormal), normalize(centerNormal)));

            if (depthDiff < 0.1f && normalDot > 0.8f)
            {
                float dist = length(float2(dx, dy));
                float spatialWeight = exp(-dist * dist * 0.25f);

                if (dx != 0 || dy != 0)
                {
                    minColor = min(minColor, sampleColor);
                    maxColor = max(maxColor, sampleColor);
                }

                sum += sampleColor * spatialWeight;
                weightSum += spatialWeight;
            }
        }
    }

    if (weightSum < 0.001f)
        return centerColor;

    float3 neighborMean = sum / weightSum;
    float lumRatioMean = centerLum / max(Luminance(neighborMean), 0.001f);
    float lumRatioMax = centerLum / max(Luminance(maxColor), 0.001f);

    if (lumRatioMean > 1.5f || lumRatioMax > 1.2f)
        return neighborMean;

    return centerColor;
}

float2 Reproject(float3 worldPos, out float prevDepthExpected)
{
    float4 prevClip = mul(PrevRenderToClip, mul(PrevCameraToRender, mul(PrevWorldToCamera, float4(worldPos, 1.0f))));
    prevDepthExpected = prevClip.z / prevClip.w;
    float2 ndc = prevClip.xy / prevClip.w;
    ndc.y = -ndc.y;
    return ndc * 0.5f + 0.5f;
}

float3 SoftClipToAABB(float3 color, float3 aabbMin, float3 aabbMax, float softness)
{
    float3 center = (aabbMin + aabbMax) * 0.5f;
    float3 halfSize = (aabbMax - aabbMin) * 0.5f + 0.001f;

    float3 offset = color - center;
    float3 unit = abs(offset / halfSize);
    float maxUnit = max(unit.x, max(unit.y, unit.z));

    if (maxUnit > 1.0f)
    {
        float t = saturate((maxUnit - 1.0f) * softness);
        float3 clipped = center + offset / maxUnit;
        return lerp(color, clipped, t);
    }
    return color;
}

void ComputeNeighborhoodStats(uint2 pixel, out float3 mean, out float3 stddev, out float3 boxMin, out float3 boxMax)
{
    float3 m1 = float3(0, 0, 0);
    float3 m2 = float3(0, 0, 0);
    boxMin = float3(1e10, 1e10, 1e10);
    boxMax = float3(-1e10, -1e10, -1e10);
    float count = 0.0f;

    [unroll]
    for (int dy = -2; dy <= 2; dy++)
    {
        [unroll]
        for (int dx = -2; dx <= 2; dx++)
        {
            if (abs(dx) == 2 && abs(dy) == 2)
                continue;

            int2 p = clamp(int2(pixel) + int2(dx, dy), int2(0,0), int2(ScreenWidth-1, ScreenHeight-1));
            float3 c = CurrentIndirect[p].rgb;

            m1 += c;
            m2 += c * c;
            boxMin = min(boxMin, c);
            boxMax = max(boxMax, c);
            count += 1.0f;
        }
    }

    mean = m1 / count;
    float3 variance = max(m2 / count - mean * mean, float3(0,0,0));
    stddev = sqrt(variance);
}

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadID.xy;

    if (pixel.x >= ScreenWidth || pixel.y >= ScreenHeight)
        return;

    float4 currentRaw4 = CurrentIndirect[pixel];
    float3 currentRaw = currentRaw4.rgb;
    float currentAO = currentRaw4.a;
    float depth = DepthBuffer[pixel];

    if (depth >= 0.9999f || depth <= 0.0f)
    {
        FilteredOutput[pixel] = float4(currentRaw, currentAO);
        return;
    }

    float3 normal = GBufferNormal[pixel].xyz * 2.0f - 1.0f;
    float3 current = PreFilterSpeckles(pixel, currentRaw, depth, normal);
    float3 worldPos = GBufferWorldPos[pixel].rgb;

    float prevDepthExpected;
    float2 historyUV = Reproject(worldPos, prevDepthExpected);

    float2 currentUV = (float2(pixel) + 0.5f) / float2(ScreenWidth, ScreenHeight);
    float velocityPixels = length((historyUV - currentUV) * float2(ScreenWidth, ScreenHeight));

    float3 mean, stddev, boxMin, boxMax;
    ComputeNeighborhoodStats(pixel, mean, stddev, boxMin, boxMax);

    float3 varMin = mean - 3.0f * stddev;
    float3 varMax = mean + 3.0f * stddev;

    float3 result = current;
    bool historyValid = all(historyUV >= 0.0f) && all(historyUV <= 1.0f) && CurrentFrame >= 2;

    if (historyValid)
    {
        float3 history = HistoryIndirect.SampleLevel(LinearSampler, historyUV, 0).rgb;
        float prevDepth = PrevDepthBuffer.SampleLevel(LinearSampler, historyUV, 0);

        float depthError = abs(prevDepth - prevDepthExpected);
        bool depthValid = depthError < DEPTH_TOLERANCE;

        float rotationFactor = EstimateCameraRotation();
        float motionFactor = saturate(velocityPixels / VELOCITY_THRESHOLD);
        float blendFactor = lerp(BLEND_STATIC, BLEND_MOVING, max(motionFactor, rotationFactor));

        if (depthValid)
        {
            float3 clippedHistory = SoftClipToAABB(history, varMin, varMax, 2.0f);
            result = lerp(clippedHistory, current, blendFactor);
        }
        else
        {
            float3 clippedHistory = SoftClipToAABB(history, varMin, varMax, 4.0f);
            result = lerp(clippedHistory, current, 0.7f);
        }
    }

    result = max(result, float3(0, 0, 0));
    if (any(isnan(result)) || any(isinf(result)))
        result = current;

    float resultLum = Luminance(result);
    const float MAX_RADIANCE_LUM = 1.0f;
    if (resultLum > MAX_RADIANCE_LUM)
        result *= MAX_RADIANCE_LUM / resultLum;

    FilteredOutput[pixel] = float4(result, currentAO);
}
