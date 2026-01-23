//=============================================================================
// SpatialFilter.hlsl
// Pass 6.9: Spatial Filter
// 空间滤波降噪
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

//=============================================================================
// 资源绑定 - 使用 Bindless 寄存器号
//=============================================================================

Texture2D<float4> ProbeRadianceInput : register(REG_PROBE_RAD_HIST_SRV);       // t418
StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV); // t401

RWTexture2D<float4> ProbeRadianceFiltered : register(REG_PROBE_RAD_FILT_UAV);  // u419

//=============================================================================
// 主计算着色器
//=============================================================================

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 rayTexCoord = dispatchThreadID.xy;
    
    if (rayTexCoord.x >= RaysTexWidth || rayTexCoord.y >= RaysTexHeight)
        return;
    
    // 3x3 高斯核
    static const float kernel[3][3] = {
        { 0.0625f, 0.125f, 0.0625f },
        { 0.125f,  0.25f,  0.125f  },
        { 0.0625f, 0.125f, 0.0625f }
    };
    
    float4 center = ProbeRadianceInput[rayTexCoord];
    
    if (center.w <= 0.0f)
    {
        ProbeRadianceFiltered[rayTexCoord] = float4(0, 0, 0, 0);
        return;
    }
    
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
                float4 sample = ProbeRadianceInput[sampleCoord];
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
