// Pass 9: Spatial Filter 
// 空间滤波降噪
#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

// History Buffer A (固定绑定)
Texture2D<float4> HistoryA_SRV : register(REG_PROBE_RAD_HIST_SRV);      // t425
// History Buffer B (固定绑定)
Texture2D<float4> HistoryB_SRV : register(REG_PROBE_RAD_HIST_B_SRV);    // t431

StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV);

RWTexture2D<float4> ProbeRadianceFiltered : register(REG_PROBE_RAD_FILT_UAV);

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 rayTexCoord = dispatchThreadID.xy;
    
    if (rayTexCoord.x >= RaysTexWidth || rayTexCoord.y >= RaysTexHeight)
        return;
    
    // 根据flag选择读取哪个History（Pass8的输出）
    float4 center;
    if (UseHistoryBufferB)
    {
        // Pass8写入了HistoryA，所以读取HistoryA
        center = HistoryA_SRV[rayTexCoord];
    }
    else
    {
        // Pass8写入了HistoryB，所以读取HistoryB
        center = HistoryB_SRV[rayTexCoord];
    }
    
    if (center.w <= 0.0f)
    {
        ProbeRadianceFiltered[rayTexCoord] = float4(0, 0, 0, 0);
        return;
    }
    
    // 3x3 高斯核
    static const float kernel[3][3] = {
        { 0.0625f, 0.125f, 0.0625f },
        { 0.125f,  0.25f,  0.125f  },
        { 0.0625f, 0.125f, 0.0625f }
    };
    
    float3 sum = float3(0, 0, 0);
    float weightSum = 0.0f;
    
    [unroll]
    for (int dy = -1; dy <= 1; dy++)
    {
        [unroll]
        for (int dx = -1; dx <= 1; dx++)
        {
            int2 sampleCoord = int2(rayTexCoord) + int2(dx, dy);
            
            if (sampleCoord.x >= 0 && sampleCoord.x < (int)RaysTexWidth &&
                sampleCoord.y >= 0 && sampleCoord.y < (int)RaysTexHeight)
            {
                // 同样根据flag读取
                float4 sample;
                if (UseHistoryBufferB)
                {
                    sample = HistoryA_SRV[sampleCoord];
                }
                else
                {
                    sample = HistoryB_SRV[sampleCoord];
                }
                
                float spatialWeight = kernel[dy + 1][dx + 1];
                
                if (sample.w > 0.0f)
                {
                    // 颜色相似性权重
                    float colorDist = length(sample.rgb - center.rgb);
                    float rangeWeight = exp(-colorDist * colorDist * DepthWeightScale);
                    
                    float w = spatialWeight * rangeWeight;
                    sum += sample.rgb * w;
                    weightSum += w;
                }
            }
        }
    }
    
    if (weightSum > 0.001f)
    {
        ProbeRadianceFiltered[rayTexCoord] = float4(sum / weightSum, 1.0f);
    }
    else
    {
        ProbeRadianceFiltered[rayTexCoord] = center;
    }
}