//=============================================================================
// BRDFPDFGeneration.hlsl
// Pass 6.2: BRDF PDF Generation
// 计算每个 Probe 的 BRDF PDF，投影到 SH2
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeSH.hlsli"
#include "ScreenProbeRegisters.hlsli"


StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV); 
Texture2D<float>  DepthBuffer  : register(REG_DEPTH_BUFFER);   
Texture2D<float4> NormalBuffer : register(REG_GBUFFER_NORMAL); 

RWStructuredBuffer<SH2CoeffsGPU> BRDFPDFOutput : register(REG_BRDF_PDF_UAV); // u402

SamplerState PointSampler : register(s0);


float ComputePlaneWeight(float3 probePos, float3 probeNormal, float3 samplePos)
{
    float planeDist = abs(dot(samplePos - probePos, probeNormal));
    return exp(-planeDist * PlaneDepthWeight);
}

float ComputeBRDFImportance(float3 sampleNormal, float3 probeNormal)
{
    return saturate(dot(sampleNormal, probeNormal));
}

//=============================================================================
// 主计算着色器
//=============================================================================

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 probeCoord = dispatchThreadID.xy;
    
    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
        return;
    
    uint probeIndex = probeCoord.y * ProbeGridWidth + probeCoord.x;
    ScreenProbeGPU probe = ProbeBuffer[probeIndex];
    
    SH2RGB sh = InitSH();
    
    // 检查 Probe 有效性
    if (probe.Validity <= 0.0f)
    {
        SH2CoeffsGPU result;
        result.R = float4(SH_L0, 0, 0, 0);
        result.G = float4(SH_L0, 0, 0, 0);
        result.B = float4(SH_L0, 0, 0, 0);
        BRDFPDFOutput[probeIndex] = result;
        return;
    }
    
    float3 probeWorldPos = probe.WorldPosition;
    float3 probeNormal = probe.WorldNormal;
    
    int halfSpacing = (int)ProbeSpacing / 2;
    float totalWeight = 0.0f;
    
    [loop]
    for (int dy = -halfSpacing; dy <= halfSpacing; dy++)
    {
        [loop]
        for (int dx = -halfSpacing; dx <= halfSpacing; dx++)
        {
            int2 samplePos = int2(probe.ScreenX, probe.ScreenY) + int2(dx, dy);
            
            if (samplePos.x < 0 || samplePos.x >= (int)ScreenWidth ||
                samplePos.y < 0 || samplePos.y >= (int)ScreenHeight)
                continue;
            
            float sampleDepth = DepthBuffer[samplePos];
            float3 sampleNormal = NormalBuffer[samplePos].xyz * 2.0f - 1.0f;
            sampleNormal = SafeNormalize(sampleNormal);
            
            if (sampleDepth <= 0.0f || sampleDepth >= 0.9999f)
                continue;
            
            // 重建世界坐标
            float2 screenUV = (float2(samplePos) + 0.5f) / float2(ScreenWidth, ScreenHeight);
            float3 sampleWorldPos = ScreenUVToWorld(screenUV, sampleDepth);
            
            float planeWeight = ComputePlaneWeight(probeWorldPos, probeNormal, sampleWorldPos);
            float brdfImportance = ComputeBRDFImportance(sampleNormal, probeNormal);
            float weight = planeWeight * brdfImportance;
            
            if (weight > 0.001f)
            {
                ProjectToSHRGB(sampleNormal, float3(weight, weight, weight), sh);
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
        sh = InitSH();
        ProjectToSHRGB(probeNormal, float3(1, 1, 1), sh);
    }
    
    // 输出
    SH2CoeffsGPU result;
    result.R = sh.R;
    result.G = sh.G;
    result.B = sh.B;
    BRDFPDFOutput[probeIndex] = result;
}
