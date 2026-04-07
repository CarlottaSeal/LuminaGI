//=============================================================================
// LightingPDFGeneration.hlsl
// Pass 6.3: Lighting PDF Generation
// Estimate lighting PDF from previous frame's screen radiance
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeSH.hlsli"
#include "ScreenProbeRegisters.hlsli"


StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV); // t401
Texture2D<float4> PrevScreenRadiance : register(REG_PREV_RADIANCE_SRV);        // t407

RWStructuredBuffer<SH2CoeffsGPU> LightingPDFOutput : register(REG_LIGHTING_PDF_UAV); // u404

SamplerState LinearSampler : register(s1);

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 probeCoord = dispatchThreadID.xy;
    
    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
        return;
    
    uint probeIndex = probeCoord.y * ProbeGridWidth + probeCoord.x;
    ScreenProbeGPU probe = ProbeBuffer[probeIndex];
    
    SH2RGB sh = InitSH();
    
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
    
    // Sample multiple directions; reproject luminance from previous frame screen
    float totalWeight = 0.0f;
    const uint numSamples = 32;
    
    [loop]
    for (uint i = 0; i < numSamples; i++)
    {
        // Fibonacci sample direction
        float3 sampleDir = FibonacciHemisphere(i, numSamples, probeNormal);
        
        // Offset along direction
        float3 sampleWorldPos = probeWorldPos + sampleDir * 1.0f;
        
        // Reproject to previous frame screen
        float4 prevCameraPos = mul(PrevWorldToCamera, float4(sampleWorldPos, 1.0f));
        float4 prevRenderPos = mul(PrevCameraToRender, prevCameraPos);
        float4 prevClipPos = mul(PrevRenderToClip, prevRenderPos);
        
        float2 prevNDC = prevClipPos.xy / prevClipPos.w;
        prevNDC.y = -prevNDC.y;
        float2 prevUV = prevNDC * 0.5f + 0.5f;
        
        // Check screen bounds
        if (prevUV.x >= 0.0f && prevUV.x <= 1.0f && 
            prevUV.y >= 0.0f && prevUV.y <= 1.0f)
        {
            // Sample previous frame radiance
            float3 prevRadiance = PrevScreenRadiance.SampleLevel(LinearSampler, prevUV, 0).rgb;
            float luminance = Luminance(prevRadiance);
            
            if (luminance > 0.001f)
            {
                float cosWeight = saturate(dot(sampleDir, probeNormal));
                float weight = luminance * cosWeight;
                
                ProjectToSHRGB(sampleDir, float3(weight, weight, weight), sh);
                totalWeight += weight;
            }
        }
    }
    
    // Normalize
    if (totalWeight > 0.0f)
    {
        NormalizeSHRGB(sh, 1.0f / totalWeight);
    }
    else
    {
        // No history: use uniform distribution
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
