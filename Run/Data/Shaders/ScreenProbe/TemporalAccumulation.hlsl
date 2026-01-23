//=============================================================================
// TemporalAccumulation.hlsl
// Pass 8: Temporal Accumulation with Ping-Pong Buffers
// 使用固定的两个History buffer，通过flag选择读写
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

//=============================================================================
// 资源绑定 - 固定的两个History buffer
//=============================================================================

// 当前帧的Radiance（Pass 7的输出）
Texture2D<float4> ProbeRadianceCurrent : register(REG_PROBE_RAD_SRV);  // t424

// History Buffer A (固定绑定)
Texture2D<float4> HistoryA_SRV : register(REG_PROBE_RAD_HIST_SRV);      // t425
RWTexture2D<float4> HistoryA_UAV : register(REG_PROBE_RAD_HIST_UAV);    // u409

// History Buffer B (固定绑定)
Texture2D<float4> HistoryB_SRV : register(REG_PROBE_RAD_HIST_B_SRV);    // t431
RWTexture2D<float4> HistoryB_UAV : register(REG_PROBE_RAD_HIST_B_UAV);  // u415

//=============================================================================
// 主计算着色器
//=============================================================================

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 rayTexCoord = dispatchThreadID.xy;
    
    if (rayTexCoord.x >= RaysTexWidth || rayTexCoord.y >= RaysTexHeight)
        return;
    
    // 读取当前帧
    float4 current = ProbeRadianceCurrent[rayTexCoord];
    
    // 根据flag选择读取哪个History（从Constants传入）
    float4 history;
    if (UseHistoryBufferB)
    {
        // 当前使用B，所以读取B，写入A
        history = HistoryB_SRV[rayTexCoord];
    }
    else
    {
        // 当前使用A，所以读取A，写入B
        history = HistoryA_SRV[rayTexCoord];
    }
    
    // 归一化当前帧
    float3 currentRadiance = float3(0, 0, 0);
    if (current.w > 0.001f)
    {
        currentRadiance = current.rgb / current.w;
    }
    
    // 时间混合
    float3 result;
    if (history.w > 0.0f)
    {
        result = lerp(history.rgb, currentRadiance, TemporalBlendFactor);
    }
    else
    {
        result = currentRadiance;
    }
    
    // 根据flag选择写入哪个History
    if (UseHistoryBufferB)
    {
        // 读B，写A
        HistoryA_UAV[rayTexCoord] = float4(result, 1.0f);
    }
    else
    {
        // 读A，写B
        HistoryB_UAV[rayTexCoord] = float4(result, 1.0f);
    }
}