// Pass 9: Spatial Filter
// 空间滤波降噪 - 支持 Octahedron 边缘环绕
#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeRegisters.hlsli"

// History Buffer A (固定绑定)
Texture2D<float4> HistoryA_SRV : register(REG_PROBE_RAD_HIST_SRV);      // t425
// History Buffer B (固定绑定)
Texture2D<float4> HistoryB_SRV : register(REG_PROBE_RAD_HIST_B_SRV);    // t431

StructuredBuffer<ScreenProbeGPU> ProbeBuffer : register(REG_PROBE_BUFFER_SRV);

RWTexture2D<float4> ProbeRadianceFiltered : register(REG_PROBE_RAD_FILT_UAV);

//=============================================================================
// ★ Octahedron 边缘环绕
// 当采样超出 octahedron 边界时，正确地环绕到对面
//=============================================================================

// 在 probe 的局部 octahedron 空间内处理边缘环绕
int2 WrapOctahedronCoord(int2 localCoord, uint octSize)
{
    // localCoord 是相对于 probe 起始位置的坐标 [0, octSize)
    // 如果超出边界，需要环绕到 octahedron 的对面

    int size = int(octSize);

    // 检查是否超出边界
    if (localCoord.x < 0 || localCoord.x >= size ||
        localCoord.y < 0 || localCoord.y >= size)
    {
        // 将局部坐标转换为 octahedron UV [-1, 1]
        float2 uv = (float2(localCoord) + 0.5f) / float(size) * 2.0f - 1.0f;

        // 检查是否在 octahedron 外部（|u| + |v| > 1）
        if (abs(uv.x) + abs(uv.y) > 1.0f)
        {
            // 环绕：反射到 octahedron 内部
            float2 sign_uv = float2(uv.x >= 0.0f ? 1.0f : -1.0f, uv.y >= 0.0f ? 1.0f : -1.0f);
            uv = (1.0f - abs(uv.yx)) * sign_uv;
        }

        // Clamp 到有效范围
        uv = clamp(uv, float2(-0.99f, -0.99f), float2(0.99f, 0.99f));

        // 转换回局部坐标
        float2 newLocal = (uv * 0.5f + 0.5f) * float(size);
        localCoord = int2(clamp(newLocal, float2(0, 0), float2(size - 1, size - 1)));
    }

    return localCoord;
}

// 读取 history buffer（根据 flag 选择）
float4 ReadHistory(int2 coord)
{
    if (UseHistoryBufferB)
    {
        return HistoryA_SRV[coord];
    }
    else
    {
        return HistoryB_SRV[coord];
    }
}

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 rayTexCoord = dispatchThreadID.xy;

    if (rayTexCoord.x >= RaysTexWidth || rayTexCoord.y >= RaysTexHeight)
        return;

    // 计算当前 texel 所属的 probe
    uint2 probeCoord = rayTexCoord / OctahedronSize;
    uint2 localCoord = rayTexCoord % OctahedronSize;
    uint2 probeBase = probeCoord * OctahedronSize;

    // 读取中心样本
    float4 center = ReadHistory(int2(rayTexCoord));

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
            // 计算相邻像素的局部坐标
            int2 neighborLocal = int2(localCoord) + int2(dx, dy);

            // ★ Octahedron 边缘环绕处理
            neighborLocal = WrapOctahedronCoord(neighborLocal, OctahedronSize);

            // 计算全局坐标（保持在同一个 probe 内）
            int2 sampleCoord = int2(probeBase) + neighborLocal;

            // 边界检查
            if (sampleCoord.x >= 0 && sampleCoord.x < (int)RaysTexWidth &&
                sampleCoord.y >= 0 && sampleCoord.y < (int)RaysTexHeight)
            {
                float4 sample = ReadHistory(sampleCoord);

                float spatialWeight = kernel[dy + 1][dx + 1];

                if (sample.w > 0.0f)
                {
                    // 颜色相似性权重（bilateral filter）
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