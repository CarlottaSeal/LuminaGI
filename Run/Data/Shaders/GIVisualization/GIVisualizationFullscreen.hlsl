
#define VIZ_FINAL_LIGHTING              0
#define VIZ_DIRECT_ONLY                 1
#define VIZ_INDIRECT_ONLY               2
// 3-7 是 Surface Cache (VS/PS)
#define VIZ_VOXEL_LIGHTING              8
#define VIZ_RADIOSITY_TRACE             9
#define VIZ_SCREEN_PROBE_BRDF_PDF       10
#define VIZ_SCREEN_PROBE_LIGHTING_PDF   11
#define VIZ_SCREEN_PROBE_MESH_SDF_TRACE 12
#define VIZ_SCREEN_PROBE_RADIANCE_OCT   13
#define VIZ_SCREEN_PROBE_FILTERED       14
#define VIZ_MESH_SDF_NORMAL             15

cbuffer VisualizationCB : register(b0)
{
    // 重建 WorldPosition 矩阵
    float4x4 ClipToRenderTransform;
    float4x4 RenderToCameraTransform;
    float4x4 CameraToWorldTransform;
    
    // 光照参数
    float4x4 LightWorldToCamera;
    float4x4 LightCameraToRender;
    float4x4 LightRenderToClip;
    
    float4 SunColor;
    float3 SunNormal;
    float ShadowMapSize;
    
    float3 AmbientColor;
    float AmbientIntensity;
    
    // 可视化参数
    uint g_Mode;
    float g_Exposure;
    uint g_ScreenWidth;
    uint g_ScreenHeight;
    
    // Screen Probe 参数
    uint g_ProbeGridWidth;
    uint g_ProbeGridHeight;
    uint g_ProbeSpacing;
    uint g_OctahedronSize;
    
    float g_DirectIntensity;
    float g_IndirectIntensity;
    float g_AOStrength;
    float g_Padding0;
    
    // Voxel 参数
    float3 g_VoxelGridMin;
    float g_VoxelSize;
    float3 g_VoxelGridMax;
    uint g_VoxelResolution;
    
    // Global SDF 参数
    float3 g_GlobalSDFCenter;
    float g_GlobalSDFExtent;
    float3 g_GlobalSDFInvExtent;
    uint g_GlobalSDFResolution;
    
    // Radiosity 参数
    uint g_RadiosityProbeGridWidth;
    uint g_RadiosityProbeGridHeight;
    uint g_AtlasWidth;
    uint g_AtlasHeight;
};

Texture2D<float4> g_GBufferAlbedo   : register(t214);
Texture2D<float4> g_GBufferNormal   : register(t215);
Texture2D<float4> g_GBufferMaterial : register(t216);
Texture2D<float4> g_GBufferMotion   : register(t217);
Texture2D<float>  g_DepthBuffer     : register(t218);

Texture2D<float> g_ShadowMap : register(t384);

Texture2D<float4> g_ScreenIndirectLighting : register(t430);

// Voxel & SDF (使用实际的 descriptor slot)
Texture3D<float>  g_GlobalSDF       : register(t378);
Texture3D<float4> g_VoxelLighting   : register(t379);

Texture2D<float4> g_RadiosityTraceResult : register(t393);

// Screen Probe 资源 (使用实际的 descriptor slot)
// BRDF_PDF 和 LightingPDF 是 StructuredBuffer<SH2CoeffsGPU>
struct SH2CoeffsGPU
{
    float R[4];
    float G[4];
    float B[4];
};
StructuredBuffer<SH2CoeffsGPU> g_ScreenProbeBRDF_PDF    : register(t417);
StructuredBuffer<SH2CoeffsGPU> g_ScreenProbeLightingPDF : register(t418);

// MeshTrace 是 StructuredBuffer<MeshTraceResult>
struct MeshTraceResult
{
    float3 HitPosition;
    float HitDistance;
    float3 HitNormal;
    float Validity;
    uint HitCardIndex;
    uint Padding0;
    uint Padding1;
    uint Padding2;
};
StructuredBuffer<MeshTraceResult> g_ScreenProbeMeshTrace : register(t422);

Texture2D<float4> g_ScreenProbeRadiance     : register(t424);
Texture2D<float4> g_ScreenProbeFiltered     : register(t426);

// Samplers
SamplerState g_PointSampler : register(s0);
SamplerState g_LinearSampler : register(s1);
SamplerComparisonState g_ShadowSampler : register(s2);

// Output (432)
RWTexture2D<float4> g_Output : register(u0);

//=============================================================================
// Helper Functions
//=============================================================================
float3 ReconstructWorldPosition(float2 uv, float depth)
{
    float4 clipPos = float4(uv * 2.0 - 1.0, depth, 1.0);
    clipPos.y = -clipPos.y;
    
    float4 renderPos = mul(ClipToRenderTransform, clipPos);
    float4 cameraPos = mul(RenderToCameraTransform, renderPos);
    float4 worldPos = mul(CameraToWorldTransform, cameraPos);
    
    return worldPos.xyz / worldPos.w;
}

float3 DecodeNormal(float3 encoded)
{
    return normalize(encoded * 2.0 - 1.0);
}

float3 VisualizeNormal(float3 n)
{
    return n * 0.5 + 0.5;
}

float3 ToneMapACES(float3 color)
{
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return saturate((color * (a * color + b)) / (color * (c * color + d) + e));
}

float3 Heatmap(float t)
{
    t = saturate(t);
    if (t < 0.25) return lerp(float3(0,0,1), float3(0,1,1), t*4.0);
    if (t < 0.5)  return lerp(float3(0,1,1), float3(0,1,0), (t-0.25)*4.0);
    if (t < 0.75) return lerp(float3(0,1,0), float3(1,1,0), (t-0.5)*4.0);
    return lerp(float3(1,1,0), float3(1,0,0), (t-0.75)*4.0);
}

float SampleShadowPCF(float3 worldPos, float3 normal)
{
    // 矩阵乘法顺序：RenderToClip * CameraToRender * WorldToCamera
    float4x4 lightViewProj = mul(LightRenderToClip, mul(LightCameraToRender, LightWorldToCamera));
    float4 lightClipPos = mul(lightViewProj, float4(worldPos, 1.0));
    lightClipPos.xyz /= lightClipPos.w;

    float2 shadowUV = lightClipPos.xy * 0.5 + 0.5;
    shadowUV.y = 1.0 - shadowUV.y;

    if (shadowUV.x < 0 || shadowUV.x > 1 || shadowUV.y < 0 || shadowUV.y > 1)
        return 1.0;

    // 使用与Composite相同的bias
    float receiverDepth = lightClipPos.z;
    float bias = 0.005;
    receiverDepth -= bias;

    // 单次采样（与Composite一致）
    return g_ShadowMap.SampleCmpLevelZero(g_ShadowSampler, shadowUV, receiverDepth);
}

float3 CalculateDirectLighting(float3 worldPos, float3 normal, float3 albedo, float shadow)
{
    float NdotL = saturate(dot(normal, -SunNormal));
    float3 sunLight = SunColor.rgb * SunColor.a * NdotL * shadow;
    float3 ambient = AmbientColor * AmbientIntensity;
    return albedo * (sunLight + ambient);
}

float3 GetSkyColor(float3 viewDir)
{
    float skyFactor = saturate(viewDir.z * 0.5 + 0.5);
    float3 horizonColor = float3(0.02, 0.03, 0.08);
    float3 zenithColor = float3(0.05, 0.08, 0.15);
    return lerp(horizonColor, zenithColor, skyFactor);
}

// 计算 Screen Probe Atlas 坐标
uint2 GetProbeAtlasCoord(uint2 pixelCoord)
{
    uint2 probeCoord = pixelCoord / g_ProbeSpacing;
    probeCoord = min(probeCoord, uint2(g_ProbeGridWidth - 1, g_ProbeGridHeight - 1));
    uint2 localOffset = (pixelCoord % g_ProbeSpacing) * g_OctahedronSize / g_ProbeSpacing;
    return probeCoord * g_OctahedronSize + localOffset;
}

// SDF 采样
float3 WorldToSdfUV(float3 worldPos)
{
    float3 sdfMin = g_GlobalSDFCenter - float3(g_GlobalSDFExtent, g_GlobalSDFExtent, g_GlobalSDFExtent);
    float3 sdfMax = g_GlobalSDFCenter + float3(g_GlobalSDFExtent, g_GlobalSDFExtent, g_GlobalSDFExtent);
    return (worldPos - sdfMin) / (sdfMax - sdfMin);
}

float SampleSDF(float3 worldPos)
{
    float3 sdfUV = WorldToSdfUV(worldPos);
    if (any(sdfUV < 0.0) || any(sdfUV > 1.0))
        return 1000.0;
    return g_GlobalSDF.SampleLevel(g_LinearSampler, sdfUV, 0);
}

float3 CalculateSDFNormal(float3 worldPos)
{
    // 保护：确保 resolution 有效
    uint resolution = max(g_GlobalSDFResolution, 64u);
    float eps = g_GlobalSDFExtent / float(resolution) * 2.0;
    eps = max(eps, 0.01);  // 最小 epsilon
    
    float dx = SampleSDF(worldPos + float3(eps, 0, 0)) - SampleSDF(worldPos - float3(eps, 0, 0));
    float dy = SampleSDF(worldPos + float3(0, eps, 0)) - SampleSDF(worldPos - float3(0, eps, 0));
    float dz = SampleSDF(worldPos + float3(0, 0, eps)) - SampleSDF(worldPos - float3(0, 0, eps));
    
    float3 gradient = float3(dx, dy, dz);
    float len = length(gradient);
    
    // 如果梯度太小，返回默认法线
    if (len < 0.0001)
        return float3(0, 1, 0);  // 默认向上
    
    return gradient / len;
}

// 从相机矩阵获取相机世界位置
float3 GetCameraPosition()
{
    // CameraToWorldTransform 将相机空间原点(0,0,0,1)变换到世界空间
    // 尝试两种方式，根据矩阵布局选择正确的
    // 方式1：行主矩阵，位置在最后一行
    // return float3(CameraToWorldTransform[3][0], CameraToWorldTransform[3][1], CameraToWorldTransform[3][2]);
    // 方式2：列主矩阵，位置在最后一列
    return float3(CameraToWorldTransform[0][3], CameraToWorldTransform[1][3], CameraToWorldTransform[2][3]);
}

// 计算屏幕像素对应的视线方向
float3 GetViewRayDirection(float2 uv)
{
    // 使用近平面和远平面两点计算射线方向
    float4 clipNear = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    float4 clipFar = float4(uv * 2.0 - 1.0, 1.0, 1.0);
    clipNear.y = -clipNear.y;
    clipFar.y = -clipFar.y;
    
    // 变换到世界空间
    float4 renderNear = mul(ClipToRenderTransform, clipNear);
    float4 cameraNear = mul(RenderToCameraTransform, renderNear);
    float4 worldNear = mul(CameraToWorldTransform, cameraNear);
    worldNear /= worldNear.w;
    
    float4 renderFar = mul(ClipToRenderTransform, clipFar);
    float4 cameraFar = mul(RenderToCameraTransform, renderFar);
    float4 worldFar = mul(CameraToWorldTransform, cameraFar);
    worldFar /= worldFar.w;
    
    return normalize(worldFar.xyz - worldNear.xyz);
}

// SimLumen 风格：Ray March Global SDF
bool TraceGlobalSDF(float3 rayOrigin, float3 rayDir, float maxDist, out float hitDist, out float3 hitNormal)
{
    hitDist = maxDist;
    hitNormal = float3(0, 0, 1);
    
    // 保护：确保 resolution 有效
    uint resolution = max(g_GlobalSDFResolution, 64u);
    float voxelSize = g_GlobalSDFExtent * 2.0 / float(resolution);
    float hitThreshold = voxelSize * 0.5;
    float minStep = voxelSize * 0.25;
    
    float t = 0.0;
    
    for (uint step = 0; step < 128; step++)
    {
        if (t > maxDist)
            break;
            
        float3 pos = rayOrigin + rayDir * t;
        float dist = SampleSDF(pos);
        
        // 如果在 SDF 体积外，快速步进
        if (dist > 100.0)
        {
            t += voxelSize * 4.0;
            continue;
        }
        
        if (dist < hitThreshold)
        {
            hitDist = t;
            hitNormal = CalculateSDFNormal(pos);
            return true;
        }
        
        t += max(dist, minStep);
    }
    
    return false;
}

// SimLumen 风格法线着色
float3 SimLumenNormalColor(float3 n)
{
    if (n.x > 0.5)
        return float3(1.0, 0.0, 0.0);      // +X 红
    else if (n.x < -0.5)
        return float3(0.2, 0.0, 0.0);      // -X 暗红
    else if (n.y > 0.5)
        return float3(0.0, 1.0, 0.0);      // +Y 绿
    else if (n.y < -0.5)
        return float3(0.0, 0.2, 0.0);      // -Y 暗绿
    else if (n.z > 0.5)
        return float3(0.0, 0.0, 1.0);      // +Z 蓝
    else if (n.z < -0.5)
        return float3(0.0, 0.0, 0.2);      // -Z 暗蓝
    else
        return normalize(n) * 0.5 + 0.5;
}

// 法线方向着色
float3 NormalToColor(float3 n)
{
    float3 absN = abs(n);
    if (absN.x > absN.y && absN.x > absN.z)
        return n.x > 0 ? float3(1.0, 0.2, 0.2) : float3(0.5, 0.1, 0.1);
    else if (absN.y > absN.z)
        return n.y > 0 ? float3(0.2, 1.0, 0.2) : float3(0.1, 0.5, 0.1);
    else
        return n.z > 0 ? float3(0.2, 0.2, 1.0) : float3(0.1, 0.1, 0.5);
}

// SH2 (L0 + L1) 评估 - 4个系数
// Y00 = 0.282095 (常数项)
// Y1-1 = 0.488603 * y
// Y10 = 0.488603 * z
// Y11 = 0.488603 * x
float EvaluateSH2(float coeffs[4], float3 dir)
{
    const float Y00 = 0.282095f;
    const float Y1x = 0.488603f;

    return coeffs[0] * Y00 +
           coeffs[1] * Y1x * dir.y +
           coeffs[2] * Y1x * dir.z +
           coeffs[3] * Y1x * dir.x;
}

float3 EvaluateSH2RGB(SH2CoeffsGPU sh, float3 dir)
{
    return float3(
        EvaluateSH2(sh.R, dir),
        EvaluateSH2(sh.G, dir),
        EvaluateSH2(sh.B, dir)
    );
}

// 计算 SH2 总能量（用于可视化PDF分布）
float GetSH2Energy(float coeffs[4])
{
    // L0 能量 + L1 能量的近似
    return abs(coeffs[0]) + (abs(coeffs[1]) + abs(coeffs[2]) + abs(coeffs[3])) * 0.5f;
}

//=============================================================================
// Main
//=============================================================================
[numthreads(8, 8, 1)]
void CSMain(uint3 dispatchID : SV_DispatchThreadID)
{
    uint2 pixelCoord = dispatchID.xy;
    if (pixelCoord.x >= g_ScreenWidth || pixelCoord.y >= g_ScreenHeight)
        return;
    
    float2 uv = (float2(pixelCoord) + 0.5) / float2(g_ScreenWidth, g_ScreenHeight);
    float depth = g_DepthBuffer[pixelCoord];
    
    float3 result = float3(0, 0, 0);
    bool isSky = (depth >= 0.9999);
    
    // 读取 GBuffer
    float3 albedo = g_GBufferAlbedo[pixelCoord].rgb;
    float3 worldNormal = DecodeNormal(g_GBufferNormal[pixelCoord].rgb);
    float4 materialData = g_GBufferMaterial[pixelCoord];
    float metallic = materialData.g;
    float ao = materialData.b;
    float3 worldPos = ReconstructWorldPosition(uv, depth);
    
    switch (g_Mode)
    {
        //=================================================================
        // Output Modes (0-2)
        //=================================================================
        case VIZ_FINAL_LIGHTING:
        {
            if (isSky)
            {
                result = float3(0, 0, 0);
            }
            else
            {
                float shadow = SampleShadowPCF(worldPos, worldNormal);
                float3 directLighting = CalculateDirectLighting(worldPos, worldNormal, albedo, shadow);
                directLighting *= g_DirectIntensity;
                
                float3 indirectLighting = g_ScreenIndirectLighting[pixelCoord].rgb;
                indirectLighting *= g_IndirectIntensity;
                indirectLighting *= lerp(1.0, ao, g_AOStrength);
                float3 diffuseColor = albedo * (1.0 - metallic);
                indirectLighting *= diffuseColor;
                
                result = directLighting + indirectLighting;
                result = ToneMapACES(result);
                result = pow(saturate(result), 1.0 / 2.2);
            }
            break;
        }
        
        case VIZ_DIRECT_ONLY:
        {
            if (isSky)
            {
                result = float3(0, 0, 0);
            }
            else
            {
                float shadow = SampleShadowPCF(worldPos, worldNormal);
                result = CalculateDirectLighting(worldPos, worldNormal, albedo, shadow);
                result *= g_DirectIntensity;
                result = ToneMapACES(result);
                result = pow(saturate(result), 1.0 / 2.2);
            }
            break;
        }
        
        case VIZ_INDIRECT_ONLY:
        {
            if (isSky)
            {
                result = float3(0, 0, 0);
            }
            else
            {
                float3 indirectLighting = g_ScreenIndirectLighting[pixelCoord].rgb;
                indirectLighting *= g_IndirectIntensity;
                indirectLighting *= lerp(1.0, ao, g_AOStrength);
                float3 diffuseColor = albedo * (1.0 - metallic);
                result = indirectLighting * diffuseColor;
                result = ToneMapACES(result);
                result = pow(saturate(result), 1.0 / 2.2);
            }
            break;
        }
        
        //=================================================================
        // Voxel Lighting (8)
        // 在 GBuffer 表面位置采样 Voxel Lighting 贴到场景上
        //=================================================================
        case VIZ_VOXEL_LIGHTING:
        {
            if (isSky)
            {
                result = float3(0, 0, 0);
                break;
            }

            // 计算 Voxel UV - 使用 VoxelGrid 参数
            float3 voxelMin = g_VoxelGridMin;
            float3 voxelMax = g_VoxelGridMax;
            float3 gridSize = voxelMax - voxelMin;

            // 如果 VoxelGrid 参数无效，使用 GlobalSDF 范围作为 fallback
            if (length(gridSize) < 1.0)
            {
                voxelMin = g_GlobalSDFCenter - g_GlobalSDFExtent;
                voxelMax = g_GlobalSDFCenter + g_GlobalSDFExtent;
                gridSize = voxelMax - voxelMin;
            }

            // 在 GBuffer 世界坐标处采样 VoxelLighting
            float3 voxelUV = (worldPos - voxelMin) / gridSize;

            if (all(voxelUV >= 0.0) && all(voxelUV <= 1.0))
            {
                float4 voxelData = g_VoxelLighting.SampleLevel(g_LinearSampler, voxelUV, 0);
                result = voxelData.rgb;

                // Tone mapping 和 gamma 校正
                result = ToneMapACES(result);
                result = pow(saturate(result), 1.0 / 2.2);
            }
            else
            {
                // 超出体素范围 - 显示暗红色边界指示
                result = float3(0.15, 0.0, 0.0);
            }
            break;
        }
        
        //=================================================================
        // Radiosity Trace Result (9)
        // RadiosityTraceResult 是 SurfaceCache 上的 ProbeGrid (1024x1024)
        // 直接显示纹理内容，用屏幕UV采样
        //=================================================================
        case VIZ_RADIOSITY_TRACE:
        {
            if (isSky)
            {
                result = float3(0, 0, 0);
                break;
            }

            // 直接用屏幕UV采样RadiosityTraceResult纹理
            // 这样可以看到整个ProbeGrid的间接光照分布

            uint probeGridW = g_RadiosityProbeGridWidth;
            uint probeGridH = g_RadiosityProbeGridHeight;

            // 如果参数未设置，使用默认值
            if (probeGridW == 0) probeGridW = 1024;
            if (probeGridH == 0) probeGridH = 1024;

            // 用屏幕UV直接采样ProbeGrid
            float2 probeUV = float2(pixelCoord) / float2(g_ScreenWidth, g_ScreenHeight);
            uint2 probeCoord = uint2(probeUV * float2(probeGridW, probeGridH));
            probeCoord = min(probeCoord, uint2(probeGridW - 1, probeGridH - 1));

            // 采样RadiosityTraceResult
            float4 radData = g_RadiosityTraceResult.Load(int3(probeCoord, 0));

            if (radData.w > 0.01f)
            {
                // 有效数据 - 显示间接光照
                result = radData.rgb;
                result = ToneMapACES(result);
                result = pow(saturate(result), 1.0 / 2.2);
            }
            else if (length(radData.rgb) > 0.001f)
            {
                // 有颜色但validity低 - 稍暗显示
                result = radData.rgb * 0.5;
                result = ToneMapACES(result);
                result = pow(saturate(result), 1.0 / 2.2);
            }
            else
            {
                // 空数据 - 纯黑
                result = float3(0, 0, 0);
            }
            break;
        }
        
        //=================================================================
        // Screen Probe Modes (10-14)
        //=================================================================
        case VIZ_SCREEN_PROBE_BRDF_PDF:
        {
            if (isSky)
            {
                result = float3(0.0, 0.0, 0.0);
            }
            else
            {
                // 计算当前像素所属的 probe 索引
                uint2 probeCoord = pixelCoord / g_ProbeSpacing;
                probeCoord = min(probeCoord, uint2(g_ProbeGridWidth - 1, g_ProbeGridHeight - 1));
                uint probeIndex = probeCoord.y * g_ProbeGridWidth + probeCoord.x;

                // 读取 SH 系数
                SH2CoeffsGPU brdfSH = g_ScreenProbeBRDF_PDF[probeIndex];

                // 计算总能量用于热力图显示
                float energy = GetSH2Energy(brdfSH.R) + GetSH2Energy(brdfSH.G) + GetSH2Energy(brdfSH.B);
                energy /= 3.0f;  // 归一化

                if (energy > 0.001f)
                {
                    // 在表面法线方向评估 BRDF PDF
                    float3 evalDir = worldNormal;
                    float3 shValue = EvaluateSH2RGB(brdfSH, evalDir);

                    // 显示热力图（基于能量）和方向值
                    float heatValue = saturate(energy * 2.0f);
                    float3 heatColor = Heatmap(heatValue);

                    // 混合：热力图显示能量，实际值调制颜色
                    result = heatColor * max(0.3f, saturate(length(shValue)));
                }
                else
                {
                    // 没有数据 - 显示暗灰色
                    result = float3(0.05, 0.05, 0.05);
                }
            }
            break;
        }
        
        case VIZ_SCREEN_PROBE_LIGHTING_PDF:
        {
            if (isSky)
            {
                result = float3(0.0, 0.0, 0.0);
            }
            else
            {
                // 计算当前像素所属的 probe 索引
                uint2 probeCoord = pixelCoord / g_ProbeSpacing;
                probeCoord = min(probeCoord, uint2(g_ProbeGridWidth - 1, g_ProbeGridHeight - 1));
                uint probeIndex = probeCoord.y * g_ProbeGridWidth + probeCoord.x;

                // 读取 Lighting PDF SH 系数
                SH2CoeffsGPU lightingSH = g_ScreenProbeLightingPDF[probeIndex];

                // 计算总能量用于热力图显示
                float energy = GetSH2Energy(lightingSH.R) + GetSH2Energy(lightingSH.G) + GetSH2Energy(lightingSH.B);
                energy /= 3.0f;  // 归一化

                if (energy > 0.001f)
                {
                    // 在太阳光方向评估 Lighting PDF（显示主光源方向的贡献）
                    float3 evalDir = -normalize(SunNormal);  // 朝向光源的方向
                    float3 shValue = EvaluateSH2RGB(lightingSH, evalDir);

                    // 显示热力图（基于能量）
                    float heatValue = saturate(energy * 2.0f);
                    float3 heatColor = Heatmap(heatValue);

                    // 也可以直接显示 SH 在光源方向的评估值
                    float3 lightingValue = max(float3(0, 0, 0), shValue);
                    result = lerp(heatColor, lightingValue, 0.5f);
                }
                else
                {
                    // 没有数据 - 显示暗灰色
                    result = float3(0.05, 0.05, 0.05);
                }
            }
            break;
        }
        
        case VIZ_SCREEN_PROBE_MESH_SDF_TRACE:
        {
            // 显示 MeshSDFTrace Pass 的实际追踪结果
            // 综合显示: 命中法线(颜色) + 命中距离(亮度) + 命中率(饱和度)

            if (isSky)
            {
                result = float3(0, 0, 0);
                break;
            }

            // 计算当前像素对应的 Probe
            uint2 probeCoord = pixelCoord / g_ProbeSpacing;
            probeCoord = min(probeCoord, uint2(g_ProbeGridWidth - 1, g_ProbeGridHeight - 1));
            uint probeIndex = probeCoord.y * g_ProbeGridWidth + probeCoord.x;

            // 统计该 Probe 所有射线的命中情况
            uint hitCount = 0;
            float avgDistance = 0;
            float3 avgNormal = float3(0, 0, 0);
            float minDistance = 10000.0;

            const uint raysPerProbe = 64;
            const float meshTraceMaxDist = 100.0;

            [loop]
            for (uint i = 0; i < raysPerProbe; i++)
            {
                uint sampleIndex = probeIndex * raysPerProbe + i;
                MeshTraceResult tr = g_ScreenProbeMeshTrace[sampleIndex];

                if (tr.Validity > 0.5)
                {
                    hitCount++;
                    avgDistance += tr.HitDistance;
                    avgNormal += tr.HitNormal;
                    minDistance = min(minDistance, tr.HitDistance);
                }
            }

            if (hitCount > 0)
            {
                avgDistance /= float(hitCount);
                avgNormal = normalize(avgNormal);

                // 计算各项指标
                float hitRate = float(hitCount) / float(raysPerProbe);
                float normalizedDist = saturate(avgDistance / meshTraceMaxDist);

                // === 综合可视化方案 ===
                // 1. 法线着色 (SimLumen 风格 - 主要信息)
                float3 normalColor = SimLumenNormalColor(avgNormal);

                // 2. 距离热力图 (近=红/黄, 远=蓝/青)
                float3 distColor = Heatmap(1.0 - normalizedDist);

                // 3. 混合: 法线70% + 距离30%, 命中率影响整体亮度
                result = normalColor * 0.7 + distColor * 0.3;
                result *= (0.4 + hitRate * 0.6); // 命中率越高越亮

                // 4. 低命中率区域加紫色警告
                if (hitRate < 0.15)
                {
                    result = lerp(result, float3(0.4, 0.0, 0.4), 0.5);
                }
            }
            else
            {
                // 完全没有命中 - 纯黑
                result = float3(0, 0, 0);
            }
            break;
        }
        
        case VIZ_SCREEN_PROBE_RADIANCE_OCT:
        {
            if (isSky)
            {
                result = float3(0, 0, 0);
                break;
            }
            uint2 atlasCoord = GetProbeAtlasCoord(pixelCoord);
            result = g_ScreenProbeRadiance[atlasCoord].rgb;
            break;
        }

        case VIZ_SCREEN_PROBE_FILTERED:
        {
            if (isSky)
            {
                result = float3(0, 0, 0);
                break;
            }
            uint2 atlasCoord = GetProbeAtlasCoord(pixelCoord);
            result = g_ScreenProbeFiltered[atlasCoord].rgb;
            break;
        }
        
        //=================================================================
        // Mesh SDF Normal (15)
        //=================================================================
        case VIZ_MESH_SDF_NORMAL:
        {
            if (isSky)
            {
                result = float3(0, 0, 0);
            }
            else
            {
                float3 sdfMin = g_GlobalSDFCenter - float3(g_GlobalSDFExtent, g_GlobalSDFExtent, g_GlobalSDFExtent);
                float3 sdfMax = g_GlobalSDFCenter + float3(g_GlobalSDFExtent, g_GlobalSDFExtent, g_GlobalSDFExtent);
                
                if (all(worldPos >= sdfMin) && all(worldPos <= sdfMax))
                {
                    float3 n = CalculateSDFNormal(worldPos);
                    result = SimLumenNormalColor(n);
                }
                else
                {
                    result = float3(0, 0, 0);
                }
            }
            break;
        }
        
        default:
            result = float3(1, 0, 1);  // Magenta = 未知模式
            break;
    }
    
    result *= g_Exposure;
    g_Output[pixelCoord] = float4(result, 1.0);
}
