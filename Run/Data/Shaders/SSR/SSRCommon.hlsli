//=============================================================================
// SSRCommon.hlsli
// Screen Space Reflections 通用定义
//=============================================================================

#ifndef SSR_COMMON_HLSLI
#define SSR_COMMON_HLSLI

//-----------------------------------------------------------------------------
// 配置参数
//-----------------------------------------------------------------------------

// 追踪参数
#ifndef MAX_TRACE_STEPS
#define MAX_TRACE_STEPS 64
#endif

#ifndef MAX_TRACE_DISTANCE
#define MAX_TRACE_DISTANCE 500.0f  // 世界单位（厘米）
#endif

// 相交检测
#ifndef THICKNESS
#define THICKNESS 0.5f  // 表面厚度阈值
#endif

#ifndef THICKNESS_MULTIPLIER
#define THICKNESS_MULTIPLIER 2.0f  // 距离越远厚度越大
#endif

// Hi-Z 参数
#ifndef HIZ_MAX_LEVEL
#define HIZ_MAX_LEVEL 6  // Hi-Z最大mip级别
#endif

#ifndef HIZ_START_LEVEL
#define HIZ_START_LEVEL 0  // 起始mip级别
#endif

// 滤波参数
#ifndef SPATIAL_FILTER_RADIUS
#define SPATIAL_FILTER_RADIUS 4
#endif

#ifndef TEMPORAL_BLEND
#define TEMPORAL_BLEND 0.1f
#endif

// 效果参数
#ifndef REFLECTION_INTENSITY
#define REFLECTION_INTENSITY 0.5f
#endif

#ifndef EDGE_FADE_START
#define EDGE_FADE_START 0.8f  // 边缘衰减开始位置
#endif

#ifndef DISTANCE_FADE_START
#define DISTANCE_FADE_START 0.7f  // 距离衰减开始位置
#endif

//-----------------------------------------------------------------------------
// 常量缓冲区
//-----------------------------------------------------------------------------

struct SSRConstants
{
    float4x4 ViewMatrix;
    float4x4 ProjMatrix;
    float4x4 InvProjMatrix;
    float4x4 InvViewProjMatrix;
    float4x4 PrevViewProjMatrix;
    
    float3 CameraPosition;
    float MaxTraceDistance;
    
    float3 CameraForward;
    float Thickness;
    
    uint ScreenWidth;
    uint ScreenHeight;
    uint MaxTraceSteps;
    uint FrameIndex;
    
    float TemporalBlend;
    float ReflectionIntensity;
    float2 Padding;
};

//-----------------------------------------------------------------------------
// 追踪结果
//-----------------------------------------------------------------------------

struct SSRTraceResult
{
    float3 HitColor;
    float Confidence;
    float2 HitUV;
    float HitDepth;
    bool IsHit;
};

//-----------------------------------------------------------------------------
// 辅助函数
//-----------------------------------------------------------------------------

// 视空间坐标转屏幕UV
float2 ViewToScreenUV(float3 viewPos, float4x4 projMatrix)
{
    float4 clipPos = mul(float4(viewPos, 1.0f), projMatrix);
    clipPos.xy /= clipPos.w;
    
    float2 uv = clipPos.xy * 0.5f + 0.5f;
    uv.y = 1.0f - uv.y;  // DX坐标系翻转
    
    return uv;
}

// 屏幕UV转视空间坐标
float3 ScreenUVToView(float2 uv, float depth, float4x4 invProjMatrix)
{
    // UV to NDC
    float2 ndc;
    ndc.x = uv.x * 2.0f - 1.0f;
    ndc.y = (1.0f - uv.y) * 2.0f - 1.0f;
    
    float4 clipPos = float4(ndc, depth, 1.0f);
    float4 viewPos = mul(clipPos, invProjMatrix);
    viewPos.xyz /= viewPos.w;
    
    return viewPos.xyz;
}

// 世界坐标转屏幕UV
float3 WorldToScreenUV(float3 worldPos, float4x4 viewProjMatrix)
{
    float4 clipPos = mul(float4(worldPos, 1.0f), viewProjMatrix);
    clipPos.xyz /= clipPos.w;
    
    float2 uv = clipPos.xy * 0.5f + 0.5f;
    uv.y = 1.0f - uv.y;
    
    return float3(uv, clipPos.z);
}

// 检查UV是否有效
bool IsValidUV(float2 uv)
{
    return all(uv >= 0.0f) && all(uv <= 1.0f);
}

// 屏幕边缘衰减
float ScreenEdgeFade(float2 uv)
{
    float2 fade = smoothstep(0.0f, EDGE_FADE_START, uv) * 
                  smoothstep(0.0f, EDGE_FADE_START, 1.0f - uv);
    return fade.x * fade.y;
}

// 距离衰减
float DistanceFade(float traceLength, float maxDistance)
{
    float t = traceLength / maxDistance;
    return 1.0f - smoothstep(DISTANCE_FADE_START, 1.0f, t);
}

// 菲涅尔近似（用于反射强度）
float FresnelSchlick(float NdotV, float F0)
{
    return F0 + (1.0f - F0) * pow(1.0f - NdotV, 5.0f);
}

// 简化菲涅尔（固定F0=0.04）
float SimpleFresnel(float NdotV)
{
    return FresnelSchlick(NdotV, 0.04f);
}

//-----------------------------------------------------------------------------
// 随机采样（用于时间抖动）
//-----------------------------------------------------------------------------

// 低差异序列
float2 Hammersley(uint i, uint N)
{
    uint bits = i;
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    float radicalInverse = float(bits) * 2.3283064365386963e-10f;
    
    return float2(float(i) / float(N), radicalInverse);
}

// 蓝噪声采样偏移（基于屏幕位置和帧索引）
float2 GetBlueNoiseOffset(uint2 pixelCoord, uint frameIndex)
{
    // 简单的时间抖动
    uint index = (pixelCoord.x + pixelCoord.y * 16 + frameIndex) % 64;
    return Hammersley(index, 64) - 0.5f;
}

//-----------------------------------------------------------------------------
// 调试
//-----------------------------------------------------------------------------

float3 DebugVisualizeConfidence(float confidence)
{
    // 绿 = 高置信度, 红 = 低置信度
    return float3(1.0f - confidence, confidence, 0.0f);
}

float3 DebugVisualizeTraceLength(float length, float maxLength)
{
    // 蓝 = 近, 红 = 远
    float t = saturate(length / maxLength);
    return float3(t, 0.0f, 1.0f - t);
}

#endif // SSR_COMMON_HLSLI
