//=============================================================================
// RadiosityFilter.hlsl
// Surface Radiosity Pass 5.2: Spatial Filter
//
// 对 Radiosity Trace 结果进行空间滤波降噪
//=============================================================================

#include "RadiosityCacheCommon.hlsli"

//=============================================================================
// 资源绑定
//=============================================================================

// Root Parameter [3]: Radiosity SRVs (t20-t25)
Texture2D<float4>   RadiosityTraceResult : register(t20);

// Root Parameter [4]: Radiosity UAVs (u0-u5)
RWTexture2D<float4> RadiosityFiltered : register(u2);

//=============================================================================
// 3x3 高斯滤波
//=============================================================================

[numthreads(8, 8, 1)]
void main(uint3 DispatchThreadID : SV_DispatchThreadID)
{
    uint2 probeCoord = DispatchThreadID.xy;
    
    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
        return;
    
    // 3x3 高斯核
    static const float kernel[3][3] = {
        { 0.0625f, 0.125f, 0.0625f },
        { 0.125f,  0.25f,  0.125f  },
        { 0.0625f, 0.125f, 0.0625f }
    };
    
    float4 sum = float4(0, 0, 0, 0);
    float weightSum = 0.0f;
    
    float4 centerSample = RadiosityTraceResult.Load(int3(probeCoord, 0));
    
    // 如果中心无效，直接输出
    if (centerSample.a <= 0.0f)
    {
        RadiosityFiltered[probeCoord] = float4(0, 0, 0, 0);
        return;
    }
    
    [unroll]
    for (int dy = -1; dy <= 1; dy++)
    {
        [unroll]
        for (int dx = -1; dx <= 1; dx++)
        {
            int2 sampleCoord = int2(probeCoord) + int2(dx, dy);
            
            // 边界检查
            if (sampleCoord.x >= 0 && sampleCoord.x < (int)ProbeGridWidth &&
                sampleCoord.y >= 0 && sampleCoord.y < (int)ProbeGridHeight)
            {
                float4 sample = RadiosityTraceResult.Load(int3(sampleCoord, 0));
                float spatialWeight = kernel[dy + 1][dx + 1];
                
                // 只累积有效的 Probe
                if (sample.a > 0.0f)
                {
                    // 可选：添加颜色相似性权重 (边缘保持)
                    float colorDist = length(sample.rgb - centerSample.rgb);
                    float rangeWeight = exp(-colorDist * colorDist * DepthWeightScale);
                    
                    float w = spatialWeight * rangeWeight;
                    sum += sample * w;
                    weightSum += w;
                }
            }
        }
    }
    
    if (weightSum > 0.001f)
    {
        RadiosityFiltered[probeCoord] = float4(sum.rgb / weightSum, 1.0f);
    }
    else
    {
        RadiosityFiltered[probeCoord] = centerSample;
    }
}
