//=============================================================================
// OctIrradiance.hlsl
// SimLumen-style: Project radiance to SH, then reconstruct irradiance
// This acts as a low-pass filter, smoothing out temporal noise
// One thread per probe (same as SimLumen's LumenScreenProbeConvertToOCT)
//=============================================================================

#include "ScreenProbeCommon.hlsli"
#include "ScreenProbeSH.hlsli"
#include "ScreenProbeRegisters.hlsli"

Texture2D<float4> ProbeRadianceInput : register(REG_PROBE_RAD_FILT_SRV);

RWTexture2D<float4> OctIrradianceOutput : register(REG_PROBE_RAD_UAV);

// SimLumen's OctahedralMapWrapBorder - 处理八面体边界
// 确保在探针边界处采样连续
uint2 OctahedralMapWrapBorder(uint2 texelCoord, uint resolution, uint borderSize)
{
    // 如果在有效范围内，直接返回
    if (texelCoord.x >= borderSize && texelCoord.x < resolution - borderSize &&
        texelCoord.y >= borderSize && texelCoord.y < resolution - borderSize)
    {
        return texelCoord;
    }

    // 处理边界包裹
    int2 signedCoord = int2(texelCoord) - int(borderSize);
    int effectiveRes = int(resolution) - 2 * int(borderSize);

    // 镜像包裹
    if (signedCoord.x < 0)
        signedCoord.x = -signedCoord.x - 1;
    if (signedCoord.y < 0)
        signedCoord.y = -signedCoord.y - 1;
    if (signedCoord.x >= effectiveRes)
        signedCoord.x = 2 * effectiveRes - signedCoord.x - 1;
    if (signedCoord.y >= effectiveRes)
        signedCoord.y = 2 * effectiveRes - signedCoord.y - 1;

    return uint2(signedCoord + int(borderSize));
}

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 probeCoord = dispatchThreadID.xy;

    if (probeCoord.x >= ProbeGridWidth || probeCoord.y >= ProbeGridHeight)
        return;

    // 8x16 per probe layout
    uint2 probeStartPos = probeCoord * uint2(OctahedronWidth, OctahedronHeight);

    SH3RGB irradianceSH = InitSH3RGB();

    for (uint texelY = 0; texelY < OctahedronHeight; texelY++)
    {
        for (uint texelX = 0; texelX < OctahedronWidth; texelX++)
        {
            uint2 texelPos = probeStartPos + uint2(texelX, texelY);

            float2 probeUV = float2((texelX + 0.5f) / float(OctahedronWidth),
                                    (texelY + 0.5f) / float(OctahedronHeight));

            float3 worldDir = OctahedronUVToDirection(probeUV);

            float4 radianceData = ProbeRadianceInput.Load(int3(texelPos, 0));
            float3 radiance = radianceData.rgb;

            SH3 basis = SHBasisFunction3(worldDir);

            irradianceSH.R.V0 += basis.V0 * radiance.r;
            irradianceSH.R.V1 += basis.V1 * radiance.r;
            irradianceSH.R.V2 += basis.V2 * radiance.r;

            irradianceSH.G.V0 += basis.V0 * radiance.g;
            irradianceSH.G.V1 += basis.V1 * radiance.g;
            irradianceSH.G.V2 += basis.V2 * radiance.g;

            irradianceSH.B.V0 += basis.V0 * radiance.b;
            irradianceSH.B.V1 += basis.V1 * radiance.b;
            irradianceSH.B.V2 += basis.V2 * radiance.b;
        }
    }

    float normalizeWeight = 1.0f / float(OctahedronWidth * OctahedronHeight);
    NormalizeSH3RGB(irradianceSH, normalizeWeight);

    for (uint writeY = 0; writeY < OctahedronHeight; writeY++)
    {
        for (uint writeX = 0; writeX < OctahedronWidth; writeX++)
        {
            uint2 texelPos = probeStartPos + uint2(writeX, writeY);

            float2 probeUV = float2((writeX + 0.5f) / float(OctahedronWidth),
                                    (writeY + 0.5f) / float(OctahedronHeight));
            float3 texelDir = OctahedronUVToDirection(probeUV);

            SH3 diffuseTransfer = CalcDiffuseTransferSH3(texelDir, 1.0f);
            float3 irradiance = 4.0f * PI * DotSH3RGB(irradianceSH, diffuseTransfer);

            irradiance = max(irradiance, float3(0, 0, 0));

            // SimLumen: 此处无 firefly clamp

            if (any(isnan(irradiance)) || any(isinf(irradiance)))
                irradiance = float3(0, 0, 0);

            // Pass through per-direction AO from spatial filter
            float texelAO = ProbeRadianceInput.Load(int3(texelPos, 0)).a;

            OctIrradianceOutput[texelPos] = float4(irradiance, texelAO);
        }
    }
}
