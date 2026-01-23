//=============================================================================
// LightingPDFGeneration.hlsl
// Pass 6.3: Lighting PDF Generation
// 利用上一帧的屏幕辐射度估计光照 PDF
// [DEBUG VERSION]
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeSH.hlsli"
#include "ScreenProbeRegisters.hlsli"


StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV); // t401
Texture2D<float4> PrevScreenRadiance : register(REG_PREV_RADIANCE_SRV);        // t407

RWStructuredBuffer<SH2CoeffsGPU> LightingPDFOutput : register(REG_LIGHTING_PDF_UAV); // u404

SamplerState LinearSampler : register(s1);

// 调试开关：设为1启用调试输出
#define DEBUG_LIGHTING_PDF 1

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 probeCoord = dispatchThreadID.xy;
    
    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
        return;
    
    uint probeIndex = probeCoord.y * ProbeGridWidth + probeCoord.x;
    ScreenProbeGPU probe = ProbeBuffer[probeIndex];
    
    SH2RGB sh = InitSH();
    
    // ====== DEBUG: 检查 Validity ======
#if DEBUG_LIGHTING_PDF
    if (probeCoord.x == 60 && probeCoord.y == 30)
    {
        // 输出 probe 信息作为调试
        SH2CoeffsGPU debugResult;
        debugResult.R = float4(probe.Validity, probe.Depth, probe.ScreenX, probe.ScreenY);
        debugResult.G = probe.WorldPosition.xyzx;
        debugResult.B = probe.WorldNormal.xyzx;
        LightingPDFOutput[probeIndex] = debugResult;
        return;
    }
#endif
    
    if (probe.Validity <= 0.0f)
    {
        SH2CoeffsGPU result;
        result.R = float4(SH_L0, 0, 0, 0);
        result.G = float4(SH_L0, 0, 0, 0);
        result.B = float4(SH_L0, 0, 0, 0);
        LightingPDFOutput[probeIndex] = result;
        return;
    }
    
    float3 probeWorldPos = probe.WorldPosition;
    float3 probeNormal = probe.WorldNormal;
    
    // ====== 方法 1：直接从上一帧probe位置采样 (类似SimLumen) ======
    // 而不是沿方向偏移然后重投影
    
    float totalWeight = 0.0f;
    
    // 计算 probe 在上一帧的屏幕位置
    float4 prevCameraPos = mul(PrevWorldToCamera, float4(probeWorldPos, 1.0f));
    float4 prevRenderPos = mul(PrevCameraToRender, prevCameraPos);
    float4 prevClipPos = mul(PrevRenderToClip, prevRenderPos);
    
    float2 prevNDC = prevClipPos.xy / prevClipPos.w;
    prevNDC.y = -prevNDC.y;
    float2 prevUV = prevNDC * 0.5f + 0.5f;
    
    // ====== DEBUG: 检查第一个probe的采样结果 ======
#if DEBUG_LIGHTING_PDF
    if (probeCoord.x == 61 && probeCoord.y == 30)
    {
        // 直接用Load采样
        int2 pixelCoord = int2(prevUV * float2(ScreenWidth, ScreenHeight));
        float3 loadedRadiance = PrevScreenRadiance.Load(int3(pixelCoord, 0)).rgb;
        
        // 也试试SampleLevel
        float3 sampledRadiance = PrevScreenRadiance.SampleLevel(LinearSampler, prevUV, 0).rgb;
        
        SH2CoeffsGPU debugResult;
        debugResult.R = float4(prevUV.x, prevUV.y, Luminance(loadedRadiance), Luminance(sampledRadiance));
        debugResult.G = float4(loadedRadiance.rgb, 0);
        debugResult.B = float4(sampledRadiance.rgb, 0);
        LightingPDFOutput[probeIndex] = debugResult;
        return;
    }
#endif
    
    // ====== 正式采样逻辑 ======
    // 方法改为：在 probe 的 8x8 区域内采样邻近像素的上一帧辐射度
    // 这更接近 SimLumen 的做法
    
    const int halfSpacing = (int)ProbeSpacing / 2;
    
    [loop]
    for (int dy = -halfSpacing; dy <= halfSpacing; dy++)
    {
        [loop]
        for (int dx = -halfSpacing; dx <= halfSpacing; dx++)
        {
            int2 sampleScreenPos = int2(probe.ScreenX, probe.ScreenY) + int2(dx, dy);
            
            if (sampleScreenPos.x < 0 || sampleScreenPos.x >= (int)ScreenWidth ||
                sampleScreenPos.y < 0 || sampleScreenPos.y >= (int)ScreenHeight)
                continue;
            
            // 计算采样点的上一帧UV
            float2 sampleUV = (float2(sampleScreenPos) + 0.5f) / float2(ScreenWidth, ScreenHeight);
            
            // 使用 Load 而不是 SampleLevel (更稳定)
            float3 prevRadiance = PrevScreenRadiance.Load(int3(sampleScreenPos, 0)).rgb;
            float luminance = Luminance(prevRadiance);
            
            // 降低阈值或移除，确保能采样到
            if (luminance > 0.0001f)
            {
                // 计算方向（从probe指向采样点）
                // 这里简化处理：使用固定方向或基于像素偏移的方向
                float2 offset = float2(dx, dy) / float(halfSpacing);
                float3 sampleDir = normalize(float3(offset.x, offset.y, 1.0f));
                sampleDir = normalize(probeNormal + sampleDir * 0.5f); // 混合法线方向
                
                float cosWeight = saturate(dot(sampleDir, probeNormal));
                float weight = luminance * cosWeight;
                
                ProjectToSHRGB(sampleDir, float3(weight, weight, weight), sh);
                totalWeight += weight;
            }
        }
    }
    
    // 归一化
    if (totalWeight > 0.0f)
    {
        NormalizeSHRGB(sh, 1.0f / totalWeight);
    }
    else
    {
        // 没有历史数据：使用均匀分布
        sh = InitSH();
        sh.R.x = SH_L0;
        sh.G.x = SH_L0;
        sh.B.x = SH_L0;
    }
    
    SH2CoeffsGPU result;
    result.R = sh.R;
    result.G = sh.G;
    result.B = sh.B;
    LightingPDFOutput[probeIndex] = result;
}
