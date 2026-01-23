//=============================================================================
// ShadowCommon.hlsli
// 阴影系统通用定义和配置
//=============================================================================

#ifndef SHADOW_COMMON_HLSLI
#define SHADOW_COMMON_HLSLI

//-----------------------------------------------------------------------------
// 配置参数（可根据需要调整）
//-----------------------------------------------------------------------------

// Shadow Map 分辨率
#ifndef SHADOW_MAP_SIZE
#define SHADOW_MAP_SIZE 4096
#endif

// PCF 采样核大小 (3=3x3, 5=5x5, 7=7x7)
#ifndef PCF_KERNEL_SIZE
#define PCF_KERNEL_SIZE 5
#endif

// 基础深度偏移（防止shadow acne）
#ifndef SHADOW_BIAS
#define SHADOW_BIAS 0.005f
#endif

// 斜率缩放偏移（表面越倾斜偏移越大）
#ifndef SLOPE_BIAS
#define SLOPE_BIAS 0.01f
#endif

// 最大偏移限制
#ifndef MAX_SHADOW_BIAS
#define MAX_SHADOW_BIAS 0.05f
#endif

// 法线偏移（防止光线泄漏）- 关键！
#ifndef NORMAL_OFFSET
#define NORMAL_OFFSET 0.05f  // 增大偏移量（原来0.02，现在0.05）
#endif

// 软阴影半影大小（光源大小模拟）
#ifndef PENUMBRA_SIZE
#define PENUMBRA_SIZE 1.0f
#endif

// Cascaded Shadow Map 级数
#ifndef CASCADE_COUNT
#define CASCADE_COUNT 4
#endif

//-----------------------------------------------------------------------------
// 常量缓冲区定义
//-----------------------------------------------------------------------------

// 单光源阴影常量
struct ShadowConstants
{
    float4x4 LightViewProj;      // 光源视图投影矩阵
    float4x4 LightView;          // 光源视图矩阵
    float4x4 LightProj;          // 光源投影矩阵
    float ShadowMapSize;         // 阴影贴图尺寸
    float ShadowBias;            // 深度偏移
    float SoftnessFactor;        // 软度因子
    float LightSize;             // 光源大小（PCSS用）
};

// CSM常量
struct CSMConstants
{
    float4x4 CascadeViewProj[CASCADE_COUNT];  // 每级的VP矩阵
    float4 CascadeSplits;                      // 分割深度 (x,y,z,w)
    float4 CascadeScales[CASCADE_COUNT];       // 每级的缩放
    float4 CascadeOffsets[CASCADE_COUNT];      // 每级的偏移
    float ShadowMapSize;
    float ShadowBias;
    float2 Padding;
};

//-----------------------------------------------------------------------------
// 采样器声明（需要在主shader中定义）
//-----------------------------------------------------------------------------

// 注意：以下采样器需要在使用此头文件的shader中声明：
// SamplerComparisonState g_ShadowSampler : register(s1);
// SamplerState g_PointSampler : register(s0);

//-----------------------------------------------------------------------------
// 辅助函数
//-----------------------------------------------------------------------------

// 计算自适应深度偏移
float CalculateAdaptiveBias(float NdotL, float baseDepth)
{
    // 表面越倾斜（NdotL越小），偏移越大
    float slopeBias = SLOPE_BIAS * sqrt(1.0f - NdotL * NdotL) / max(NdotL, 0.001f);
    float bias = SHADOW_BIAS + slopeBias;
    
    // 根据深度调整（远处需要更大偏移）
    bias *= (1.0f + baseDepth * 0.5f);
    
    return min(bias, MAX_SHADOW_BIAS);
}

// 应用法线偏移（防止光线泄漏）
float3 ApplyNormalOffset(float3 worldPos, float3 worldNormal, float NdotL)
{
    float offsetScale = NORMAL_OFFSET;
    
    // 对于掠射角（grazing angles），更激进地偏移
    // 当NdotL接近0时（表面几乎垂直于光线），偏移量显著增加
    float grazingFactor = 1.0f - saturate(NdotL);
    offsetScale *= (1.0f + grazingFactor * 3.0f);  // 最多增大4倍
    
    // 沿着法线方向推离表面
    return worldPos + worldNormal * offsetScale;
}

// 应用法线+光线方向双重偏移（更强力，防止所有漏光）
float3 ApplyNormalOffsetWithLightDir(float3 worldPos, float3 worldNormal, float3 lightDir, float NdotL)
{
    float offsetScale = NORMAL_OFFSET;
    
    // 1. 法线方向偏移
    float grazingFactor = 1.0f - saturate(NdotL);
    float normalOffset = offsetScale * (1.0f + grazingFactor * 3.0f);
    
    // 2. 额外沿光线方向偏移（特别适合墙壁）
    float lightDirOffset = offsetScale * 0.5f * grazingFactor;
    
    // 组合两个偏移
    return worldPos + worldNormal * normalOffset + lightDir * lightDirOffset;
}

// 世界坐标转阴影UV（带法线偏移）
float3 WorldToShadowUV(float3 worldPos, float3 worldNormal, float NdotL, float4x4 lightViewProj)
{
    // 先应用法线偏移
    float3 offsetWorldPos = ApplyNormalOffset(worldPos, worldNormal, NdotL);
    
    // 修复：使用列向量形式 mul(matrix, vector) 以匹配Shadow.hlsl中的矩阵乘法顺序
    float4 lightSpacePos = mul(lightViewProj, float4(offsetWorldPos, 1.0f));
    lightSpacePos.xyz /= lightSpacePos.w;
    
    float2 shadowUV = lightSpacePos.xy * 0.5f + 0.5f;
    shadowUV.y = 1.0f - shadowUV.y;  // 翻转Y（DX坐标系）
    
    return float3(shadowUV, lightSpacePos.z);
}

// 世界坐标转阴影UV（带法线+光线方向双重偏移，更强力）
float3 WorldToShadowUVWithLightDir(float3 worldPos, float3 worldNormal, float3 lightDir, float NdotL, float4x4 lightViewProj)
{
    // 应用双重偏移
    float3 offsetWorldPos = ApplyNormalOffsetWithLightDir(worldPos, worldNormal, lightDir, NdotL);
    
    float4 lightSpacePos = mul(lightViewProj, float4(offsetWorldPos, 1.0f));
    lightSpacePos.xyz /= lightSpacePos.w;
    
    float2 shadowUV = lightSpacePos.xy * 0.5f + 0.5f;
    shadowUV.y = 1.0f - shadowUV.y;
    
    return float3(shadowUV, lightSpacePos.z);
}

// 世界坐标转阴影UV（不带法线偏移，兼容旧代码）
float3 WorldToShadowUV(float3 worldPos, float4x4 lightViewProj)
{
    // 修复：使用列向量形式 mul(matrix, vector) 以匹配Shadow.hlsl中的矩阵乘法顺序
    float4 lightSpacePos = mul(lightViewProj, float4(worldPos, 1.0f));
    lightSpacePos.xyz /= lightSpacePos.w;
    
    float2 shadowUV = lightSpacePos.xy * 0.5f + 0.5f;
    shadowUV.y = 1.0f - shadowUV.y;  // 翻转Y（DX坐标系）
    
    return float3(shadowUV, lightSpacePos.z);
}

// 检查UV是否在有效范围内
bool IsValidShadowUV(float2 uv)
{
    return all(uv >= 0.0f) && all(uv <= 1.0f);
}

// 边缘衰减（避免边缘硬切）
float ShadowEdgeFade(float2 uv)
{
    float2 fade = saturate((0.5f - abs(uv - 0.5f)) * 10.0f);
    return fade.x * fade.y;
}

//-----------------------------------------------------------------------------
// Poisson Disk 采样点（用于高质量PCF/PCSS）
//-----------------------------------------------------------------------------

static const float2 PoissonDisk16[16] = 
{
    float2(-0.94201624f, -0.39906216f),
    float2(0.94558609f, -0.76890725f),
    float2(-0.09418410f, -0.92938870f),
    float2(0.34495938f,  0.29387760f),
    float2(-0.91588581f,  0.45771432f),
    float2(-0.81544232f, -0.87912464f),
    float2(-0.38277543f,  0.27676845f),
    float2(0.97484398f,  0.75648379f),
    float2(0.44323325f, -0.97511554f),
    float2(0.53742981f, -0.47373420f),
    float2(-0.26496911f, -0.41893023f),
    float2(0.79197514f,  0.19090188f),
    float2(-0.24188840f,  0.99706507f),
    float2(-0.81409955f,  0.91437590f),
    float2(0.19984126f,  0.78641367f),
    float2(0.14383161f, -0.14100790f)
};

static const float2 PoissonDisk32[32] = 
{
    float2(-0.975402f, -0.0711386f),
    float2(-0.920347f, -0.41142f),
    float2(-0.883908f, 0.217872f),
    float2(-0.884518f, 0.568041f),
    float2(-0.811945f, 0.90521f),
    float2(-0.792474f, -0.779962f),
    float2(-0.614856f, 0.386578f),
    float2(-0.580859f, -0.208777f),
    float2(-0.53795f, 0.716666f),
    float2(-0.515427f, 0.0899991f),
    float2(-0.454634f, -0.707938f),
    float2(-0.420942f, -0.418699f),
    float2(-0.31657f, -0.949413f),
    float2(-0.274946f, 0.41893f),
    float2(-0.239518f, -0.107773f),
    float2(-0.215309f, 0.789183f),
    float2(-0.152287f, -0.542021f),
    float2(-0.0307879f, 0.0875881f),
    float2(-0.0270295f, -0.850922f),
    float2(0.0225632f, 0.530593f),
    float2(0.0932482f, -0.259661f),
    float2(0.180892f, -0.615657f),
    float2(0.235709f, 0.893421f),
    float2(0.262908f, 0.263953f),
    float2(0.316597f, -0.945052f),
    float2(0.395019f, -0.310498f),
    float2(0.469718f, 0.576879f),
    float2(0.545636f, -0.667946f),
    float2(0.622693f, 0.175629f),
    float2(0.751933f, 0.682416f),
    float2(0.790721f, -0.379812f),
    float2(0.941635f, 0.195766f)
};

//-----------------------------------------------------------------------------
// 随机旋转（用于采样抖动）
//-----------------------------------------------------------------------------

// 基于屏幕位置的伪随机旋转角度
float GetRandomRotation(float2 screenPos)
{
    return frac(sin(dot(screenPos, float2(12.9898f, 78.233f))) * 43758.5453f) * 6.283185f;
}

// 旋转2D向量
float2 RotateVector(float2 v, float angle)
{
    float s = sin(angle);
    float c = cos(angle);
    return float2(v.x * c - v.y * s, v.x * s + v.y * c);
}

#endif // SHADOW_COMMON_HLSLI
