//=============================================================================
// SimpleSSR.hlsl
// Screen Space Reflections 主追踪shader
//=============================================================================

#include "SSRCommon.hlsli"

//-----------------------------------------------------------------------------
// 常量缓冲区
//-----------------------------------------------------------------------------

cbuffer SSRConstantBuffer : register(b0)
{
    SSRConstants g_SSR;
};

//-----------------------------------------------------------------------------
// 资源
//-----------------------------------------------------------------------------

// GBuffer
Texture2D<float> g_Depth : register(t0);
Texture2D<float4> g_Normal : register(t1);      // RGB = Normal (世界空间)
Texture2D<float4> g_WorldPos : register(t2);    // RGB = Position (世界空间)
Texture2D<float4> g_Albedo : register(t3);      // RGB = Albedo

// Hi-Z + 上一帧颜色
Texture2D<float> g_HiZ : register(t4);
Texture2D<float4> g_PrevFrameColor : register(t5);

// 采样器
SamplerState g_PointSampler : register(s0);
SamplerState g_LinearSampler : register(s1);

// 输出
RWTexture2D<float4> g_Output : register(u0);  // RGB = 反射颜色, A = 置信度

//-----------------------------------------------------------------------------
// 线性屏幕空间追踪（简化版，无Hi-Z）
//-----------------------------------------------------------------------------

SSRTraceResult LinearTrace(float3 rayOrigin, float3 rayDir)
{
    SSRTraceResult result;
    result.IsHit = false;
    result.Confidence = 0.0f;
    result.HitColor = float3(0, 0, 0);
    result.HitUV = float2(0, 0);
    result.HitDepth = 0.0f;
    
    // 计算射线终点
    float3 rayEnd = rayOrigin + rayDir * g_SSR.MaxTraceDistance;
    
    // 变换到裁剪空间
    float4 startClip = mul(float4(rayOrigin, 1.0f), mul(g_SSR.ViewMatrix, g_SSR.ProjMatrix));
    float4 endClip = mul(float4(rayEnd, 1.0f), mul(g_SSR.ViewMatrix, g_SSR.ProjMatrix));
    
    // 透视除法
    startClip.xyz /= startClip.w;
    endClip.xyz /= endClip.w;
    
    // NDC to UV
    float2 startUV = startClip.xy * 0.5f + 0.5f;
    float2 endUV = endClip.xy * 0.5f + 0.5f;
    startUV.y = 1.0f - startUV.y;
    endUV.y = 1.0f - endUV.y;
    
    // 计算步进
    float2 delta = endUV - startUV;
    float stepCount = max(abs(delta.x) * g_SSR.ScreenWidth, abs(delta.y) * g_SSR.ScreenHeight);
    stepCount = min(stepCount, (float)g_SSR.MaxTraceSteps);
    
    if (stepCount < 1.0f)
        return result;
    
    float2 stepSize = delta / stepCount;
    float depthStep = (endClip.z - startClip.z) / stepCount;
    
    float2 currentUV = startUV;
    float currentDepth = startClip.z;
    
    // 线性步进
    for (uint i = 0; i < (uint)stepCount; ++i)
    {
        currentUV += stepSize;
        currentDepth += depthStep;
        
        // 边界检查
        if (!IsValidUV(currentUV))
            break;
        
        // 采样场景深度
        float sceneDepth = g_Depth.SampleLevel(g_PointSampler, currentUV, 0);
        
        // 相交检测（带厚度）
        float thickness = g_SSR.Thickness * (1.0f + (float)i * 0.01f);  // 距离越远厚度越大
        
        if (currentDepth > sceneDepth && currentDepth < sceneDepth + thickness)
        {
            // 命中！
            result.IsHit = true;
            result.HitUV = currentUV;
            result.HitDepth = sceneDepth;
            
            // 采样颜色
            result.HitColor = g_PrevFrameColor.SampleLevel(g_LinearSampler, currentUV, 0).rgb;
            
            // 计算置信度
            float traceProgress = (float)i / stepCount;
            float edgeFade = ScreenEdgeFade(currentUV);
            float distanceFade = DistanceFade(traceProgress * g_SSR.MaxTraceDistance, g_SSR.MaxTraceDistance);
            
            result.Confidence = edgeFade * distanceFade;
            
            break;
        }
    }
    
    return result;
}

//-----------------------------------------------------------------------------
// Hi-Z加速追踪
//-----------------------------------------------------------------------------

SSRTraceResult HiZTrace(float3 rayOrigin, float3 rayDir)
{
    SSRTraceResult result;
    result.IsHit = false;
    result.Confidence = 0.0f;
    result.HitColor = float3(0, 0, 0);
    result.HitUV = float2(0, 0);
    result.HitDepth = 0.0f;
    
    // 变换起点和方向到屏幕空间
    float4 startClip = mul(float4(rayOrigin, 1.0f), mul(g_SSR.ViewMatrix, g_SSR.ProjMatrix));
    float3 rayEndWorld = rayOrigin + rayDir * g_SSR.MaxTraceDistance;
    float4 endClip = mul(float4(rayEndWorld, 1.0f), mul(g_SSR.ViewMatrix, g_SSR.ProjMatrix));
    
    // 透视除法
    if (startClip.w <= 0.0f || endClip.w <= 0.0f)
        return result;
    
    startClip.xyz /= startClip.w;
    endClip.xyz /= endClip.w;
    
    // NDC to UV
    float2 startUV = startClip.xy * 0.5f + 0.5f;
    float2 endUV = endClip.xy * 0.5f + 0.5f;
    startUV.y = 1.0f - startUV.y;
    endUV.y = 1.0f - endUV.y;
    
    // 射线参数
    float2 rayUV = endUV - startUV;
    float rayDepth = endClip.z - startClip.z;
    
    // 确定主轴
    float2 absRayUV = abs(rayUV);
    bool useX = absRayUV.x > absRayUV.y;
    float rayLength = useX ? absRayUV.x : absRayUV.y;
    
    if (rayLength < 0.001f)
        return result;
    
    // Hi-Z追踪参数
    int mipLevel = HIZ_START_LEVEL;
    float2 currentUV = startUV;
    float currentDepth = startClip.z;
    
    float2 stepDir = normalize(rayUV);
    float depthPerPixel = rayDepth / (rayLength * g_SSR.ScreenWidth);
    
    uint iteration = 0;
    uint maxIterations = g_SSR.MaxTraceSteps;
    
    while (iteration < maxIterations)
    {
        // 边界检查
        if (!IsValidUV(currentUV))
            break;
        
        // 计算当前Mip的像素大小
        float mipScale = pow(2.0f, (float)mipLevel);
        float2 cellSize = mipScale / float2(g_SSR.ScreenWidth, g_SSR.ScreenHeight);
        
        // 采样Hi-Z
        float hiZDepth = g_HiZ.SampleLevel(g_PointSampler, currentUV, mipLevel);
        
        // 如果射线在Hi-Z之上，可以安全跳过
        if (currentDepth < hiZDepth)
        {
            // 跳到下一个cell边界
            float2 cellMin = floor(currentUV / cellSize) * cellSize;
            float2 cellMax = cellMin + cellSize;
            
            float2 tMin = (cellMin - currentUV) / stepDir;
            float2 tMax = (cellMax - currentUV) / stepDir;
            
            float2 t = max(tMin, tMax);
            float tStep = min(t.x, t.y) + 0.001f;
            
            currentUV += stepDir * tStep;
            currentDepth += depthPerPixel * tStep * g_SSR.ScreenWidth;
            
            // 降低Mip级别（更精细）
            mipLevel = max(mipLevel - 1, 0);
        }
        else
        {
            // 射线在Hi-Z之下，可能有交点
            if (mipLevel == 0)
            {
                // 最精细级别，进行精确检测
                float thickness = g_SSR.Thickness;
                
                if (currentDepth < hiZDepth + thickness)
                {
                    // 命中！
                    result.IsHit = true;
                    result.HitUV = currentUV;
                    result.HitDepth = hiZDepth;
                    result.HitColor = g_PrevFrameColor.SampleLevel(g_LinearSampler, currentUV, 0).rgb;
                    
                    // 计算置信度
                    float edgeFade = ScreenEdgeFade(currentUV);
                    float progress = length(currentUV - startUV) / length(rayUV);
                    float distanceFade = DistanceFade(progress * g_SSR.MaxTraceDistance, g_SSR.MaxTraceDistance);
                    
                    result.Confidence = edgeFade * distanceFade;
                    break;
                }
                else
                {
                    // 穿过了表面，继续前进
                    currentUV += stepDir * cellSize;
                    currentDepth += depthPerPixel * cellSize.x * g_SSR.ScreenWidth;
                }
            }
            else
            {
                // 提高Mip级别（更粗糙，进一步细化搜索）
                mipLevel = min(mipLevel + 1, HIZ_MAX_LEVEL);
            }
        }
        
        iteration++;
    }
    
    return result;
}

//-----------------------------------------------------------------------------
// 主入口
//-----------------------------------------------------------------------------

[numthreads(8, 8, 1)]
void CSTrace(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pixelCoord = dispatchThreadID.xy;
    
    if (pixelCoord.x >= g_SSR.ScreenWidth || pixelCoord.y >= g_SSR.ScreenHeight)
        return;
    
    float2 uv = (float2(pixelCoord) + 0.5f) / float2(g_SSR.ScreenWidth, g_SSR.ScreenHeight);
    
    // 读取GBuffer
    float depth = g_Depth[pixelCoord];
    
    // 天空跳过
    if (depth >= 1.0f)
    {
        g_Output[pixelCoord] = float4(0, 0, 0, 0);
        return;
    }
    
    float3 worldPos = g_WorldPos[pixelCoord].xyz;
    float3 worldNormal = normalize(g_Normal[pixelCoord].xyz * 2.0f - 1.0f);
    
    // 计算视线方向
    float3 viewDir = normalize(worldPos - g_SSR.CameraPosition);
    
    // 计算反射方向
    float3 reflectDir = reflect(viewDir, worldNormal);
    
    // 检查反射方向是否指向相机（无效）
    if (dot(reflectDir, -viewDir) < 0.0f)
    {
        g_Output[pixelCoord] = float4(0, 0, 0, 0);
        return;
    }
    
    // 添加时间抖动（减少条纹）
    float2 jitter = GetBlueNoiseOffset(pixelCoord, g_SSR.FrameIndex) * 0.001f;
    float3 jitteredOrigin = worldPos + worldNormal * 0.01f;  // 偏移避免自相交
    
    // 执行追踪
    SSRTraceResult traceResult;
    
#if USE_HIZ
    traceResult = HiZTrace(jitteredOrigin, reflectDir);
#else
    traceResult = LinearTrace(jitteredOrigin, reflectDir);
#endif
    
    // 计算菲涅尔
    float NdotV = saturate(dot(worldNormal, -viewDir));
    float fresnel = SimpleFresnel(NdotV);
    
    // 输出
    float3 reflectionColor = traceResult.HitColor * fresnel * g_SSR.ReflectionIntensity;
    float confidence = traceResult.Confidence * (traceResult.IsHit ? 1.0f : 0.0f);
    
    g_Output[pixelCoord] = float4(reflectionColor, confidence);
}

//-----------------------------------------------------------------------------
// 调试可视化
//-----------------------------------------------------------------------------

[numthreads(8, 8, 1)]
void CSDebugConfidence(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pixelCoord = dispatchThreadID.xy;
    
    if (pixelCoord.x >= g_SSR.ScreenWidth || pixelCoord.y >= g_SSR.ScreenHeight)
        return;
    
    float4 ssr = g_Output[pixelCoord];
    g_Output[pixelCoord] = float4(DebugVisualizeConfidence(ssr.a), 1.0f);
}
