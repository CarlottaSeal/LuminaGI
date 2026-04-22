#include "RadiosityCacheCommon.hlsli"

Texture2D<float4>   TraceRadianceAtlas : register(t20);
RWTexture2D<float4> TraceRadianceFiltered : register(u2);

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pixelCoord = dispatchThreadID.xy;

    if (pixelCoord.x >= AtlasWidth || pixelCoord.y >= AtlasHeight)
        return;

    float4 centerSample = TraceRadianceAtlas.Load(int3(pixelCoord, 0));

    if (dot(centerSample.rgb, centerSample.rgb) < 0.000001f)
    {
        TraceRadianceFiltered[pixelCoord] = float4(0, 0, 0, 0);
        return;
    }

    // Center weight: 2
    float centerWeight = 2.0f;
    float3 radiance = centerSample.rgb * centerWeight;
    float totalWeight = centerWeight;

    // 4-neighbor cross sample; each weight 1
    int2 offsets[4] = { int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1) };

    [unroll]
    for (uint i = 0; i < 4; i++)
    {
        int2 sampleCoord = int2(pixelCoord) + offsets[i];

        // Bounds check
        if (sampleCoord.x >= 0 && sampleCoord.x < (int)AtlasWidth &&
            sampleCoord.y >= 0 && sampleCoord.y < (int)AtlasHeight)
        {
            float3 neighborRadiance = TraceRadianceAtlas.Load(int3(sampleCoord, 0)).rgb;
            radiance += neighborRadiance;
            totalWeight += 1.0f;
        }
    }

    TraceRadianceFiltered[pixelCoord] = float4(radiance / totalWeight, 0.0f);
}
