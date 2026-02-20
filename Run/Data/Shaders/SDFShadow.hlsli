//=============================================================================
// SDFShadow.hlsli
// SDF-based soft shadows using Global SDF
//=============================================================================

#ifndef SDF_SHADOW_HLSLI
#define SDF_SHADOW_HLSLI

//-----------------------------------------------------------------------------
// 配置参数
//-----------------------------------------------------------------------------

#ifndef SDF_SHADOW_MAX_STEPS
#define SDF_SHADOW_MAX_STEPS 32
#endif

#ifndef SDF_SHADOW_MAX_DISTANCE
#define SDF_SHADOW_MAX_DISTANCE 100.0f
#endif

#ifndef SDF_SHADOW_MIN_DISTANCE
#define SDF_SHADOW_MIN_DISTANCE 0.1f
#endif

#ifndef SDF_SHADOW_SOFTNESS
#define SDF_SHADOW_SOFTNESS 8.0f  // 越大阴影越硬，越小越软
#endif

#ifndef SDF_SHADOW_BIAS
#define SDF_SHADOW_BIAS 1.0f  // 起始偏移，避免 self-shadowing（增大）
#endif

#ifndef SDF_SHADOW_HIT_THRESHOLD
#define SDF_SHADOW_HIT_THRESHOLD 0.01f  // 命中阈值
#endif

//-----------------------------------------------------------------------------
// 坐标转换 - 与 VoxelSDFTrace.hlsl 保持一致
//-----------------------------------------------------------------------------

float3 WorldToSDFUV_Shadow(float3 worldPos, float3 sdfCenter, float sdfExtent)
{
    // 正确公式：(worldPos - center) / extent + 0.5
    // 这里 extent 是半径，所以 UV 范围是 [0, 1] 对应 [center - extent, center + extent]
    return (worldPos - sdfCenter) / sdfExtent + 0.5f;
}

float SampleSDFDistance(Texture3D<float2> globalSDF, SamplerState sdfSampler,
                        float3 worldPos, float3 sdfCenter, float sdfExtent)
{
    float3 sdfUV = WorldToSDFUV_Shadow(worldPos, sdfCenter, sdfExtent);

    if (any(sdfUV < 0.0f) || any(sdfUV > 1.0f))
        return 1000.0f;

    // SDF 纹理存储的是归一化距离，需要乘以 extent 得到世界空间距离
    float normalizedDist = globalSDF.SampleLevel(sdfSampler, sdfUV, 0).r;
    return normalizedDist * sdfExtent;
}

//-----------------------------------------------------------------------------
// SDF 软阴影追踪
// 基于 Inigo Quilez 的软阴影算法
// https://iquilezles.org/articles/rmshadows/
//-----------------------------------------------------------------------------

float TraceSDFSoftShadow(
    Texture3D<float2> globalSDF,
    SamplerState sdfSampler,
    float3 sdfCenter,
    float sdfExtent,
    float3 rayOrigin,
    float3 rayDir,
    float maxDist,
    float softness)
{
    float shadow = 1.0f;
    float t = SDF_SHADOW_BIAS;

    [loop]
    for (int i = 0; i < SDF_SHADOW_MAX_STEPS && t < maxDist; i++)
    {
        float3 pos = rayOrigin + rayDir * t;

        float dist = SampleSDFDistance(globalSDF, sdfSampler, pos, sdfCenter, sdfExtent);

        // 超出范围
        if (dist >= 999.0f)
            break;

        // 命中表面
        if (dist < SDF_SHADOW_HIT_THRESHOLD)
            return 0.0f;

        // 软阴影计算
        float penumbra = softness * dist / t;
        shadow = min(shadow, penumbra);

        // 步进（世界空间距离）
        t += max(dist * 0.9f, 0.1f);
    }

    return saturate(shadow);
}

// 改进版软阴影 - 更平滑的半影过渡
float TraceSDFSoftShadowImproved(
    Texture3D<float2> globalSDF,
    SamplerState sdfSampler,
    float3 sdfCenter,
    float sdfExtent,
    float3 rayOrigin,
    float3 rayDir,
    float maxDist,
    float softness)
{
    float shadow = 1.0f;
    float t = SDF_SHADOW_BIAS;

    [loop]
    for (int i = 0; i < SDF_SHADOW_MAX_STEPS && t < maxDist; i++)
    {
        float3 pos = rayOrigin + rayDir * t;

        float dist = SampleSDFDistance(globalSDF, sdfSampler, pos, sdfCenter, sdfExtent);

        // 超出 SDF 范围，停止追踪（假设无遮挡）
        if (dist >= 999.0f)
            break;

        // 如果距离为负或很小，说明在几何体内部或命中
        // 但不要返回完全黑，保留一些软阴影
        if (dist < SDF_SHADOW_HIT_THRESHOLD)
        {
            shadow = min(shadow, 0.1f);  // 不完全黑，避免 acne
            break;
        }

        // 软阴影计算（简化版，更稳定）
        float penumbra = softness * dist / t;
        shadow = min(shadow, saturate(penumbra));

        // 步进
        t += max(dist * 0.8f, 0.2f);
    }

    // 平滑输出
    return smoothstep(0.0f, 1.0f, shadow);
}

//-----------------------------------------------------------------------------
// 便捷函数 - 常用场景
//-----------------------------------------------------------------------------

// 太阳光 SDF 阴影（平行光）
float SampleSDFSunShadow(
    Texture3D<float2> globalSDF,
    SamplerState sdfSampler,
    float3 sdfCenter,
    float sdfExtent,
    float3 worldPos,
    float3 worldNormal,
    float3 sunDir)  // 指向太阳的方向（与 SunNormal 相反）
{
    // 沿法线偏移起点，避免 self-shadowing
    float3 rayOrigin = worldPos + worldNormal * SDF_SHADOW_BIAS;

    return TraceSDFSoftShadowImproved(
        globalSDF,
        sdfSampler,
        sdfCenter,
        sdfExtent,
        rayOrigin,
        sunDir,
        SDF_SHADOW_MAX_DISTANCE,
        SDF_SHADOW_SOFTNESS
    );
}

// 点光源 SDF 阴影
float SampleSDFPointShadow(
    Texture3D<float2> globalSDF,
    SamplerState sdfSampler,
    float3 sdfCenter,
    float sdfExtent,
    float3 worldPos,
    float3 worldNormal,
    float3 lightPos)
{
    float3 toLight = lightPos - worldPos;
    float lightDist = length(toLight);
    float3 lightDir = toLight / lightDist;

    // 沿法线偏移
    float3 rayOrigin = worldPos + worldNormal * SDF_SHADOW_BIAS;

    // 点光源的软度随距离变化（近处更软）
    float softness = SDF_SHADOW_SOFTNESS * (1.0f + 10.0f / lightDist);

    return TraceSDFSoftShadowImproved(
        globalSDF,
        sdfSampler,
        sdfCenter,
        sdfExtent,
        rayOrigin,
        lightDir,
        lightDist - SDF_SHADOW_BIAS,  // 不要超过光源
        softness
    );
}

//-----------------------------------------------------------------------------
// 混合阴影 - Shadow Map + SDF
//-----------------------------------------------------------------------------

// 混合策略 1：取最小值（更安全，避免漏光）
float CombineShadowMin(float shadowMap, float sdfShadow)
{
    return min(shadowMap, sdfShadow);
}

// 混合策略 2：相乘（更软的效果）
float CombineShadowMultiply(float shadowMap, float sdfShadow)
{
    return shadowMap * sdfShadow;
}

// 混合策略 3：距离混合（近处用 Shadow Map，远处用 SDF）
float CombineShadowDistanceBased(float shadowMap, float sdfShadow, float depth, float nearDist, float farDist)
{
    float blend = saturate((depth - nearDist) / (farDist - nearDist));
    return lerp(shadowMap, sdfShadow, blend);
}

// 推荐：自适应混合
// Shadow Map 提供近距离精确接触阴影
// SDF 提供远距离软阴影和防止 peter panning
float CombineShadowAdaptive(float shadowMap, float sdfShadow, float NdotL)
{
    // 对于掠射角（NdotL 小），更多依赖 SDF（避免 shadow acne）
    // 对于正面（NdotL 大），可以信任 shadow map
    float sdfWeight = 1.0f - NdotL * NdotL;  // 掠射角时 SDF 权重更高

    float combined = lerp(
        min(shadowMap, sdfShadow),      // 正面：取最小
        sdfShadow,                       // 掠射：用 SDF
        sdfWeight * 0.5f                 // 平滑过渡
    );

    return combined;
}

#endif // SDF_SHADOW_HLSLI
