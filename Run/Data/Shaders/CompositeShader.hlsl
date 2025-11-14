cbuffer CameraConstants : register(b1)
{
    float4x4 WorldToCameraTransform;
    float4x4 CameraToRenderTransform;
    float4x4 RenderToClipTransform;
    float3 CameraWorldPosition;
    float CameraPadding;
};

cbuffer RadianceCacheConstants : register(b13)
{
    uint RC_MaxProbes;
    uint RC_ActiveProbeCount;
    uint RC_UpdateProbeCount;
    uint RC_RaysPerProbe;
    
    float3 RC_CameraPosition;
    float RC_Padding0;
    
    float4x4 RC_ViewProj;
    float4x4 RC_ViewProjInverse;
    
    float RC_ScreenWidth;
    float RC_ScreenHeight;
    uint RC_CurrentFrame;
    float RC_TemporalBlend;
};

struct RadianceProbeGPU
{
    float3 WorldPosition;
    float Pad0;
    
    float SH_R[9];
    float SH_G[9];
    float SH_B[9];
    
    uint LastUpdateFrame;
    float Validity;
    float Weight;
    float Pad1;
};

Texture2D<float4> g_GBufferAlbedo : register(t200);
Texture2D<float4> g_GBufferNormal : register(t201);
Texture2D<float4> g_GBufferMaterial : register(t202);
Texture2D<float4> g_GBufferMotion : register(t203);

Texture2D<float> g_DepthBuffer : register(t204);

Texture2DArray<float4> g_SurfaceCacheAtlas : register(t205);

StructuredBuffer<RadianceProbeGPU> g_RadianceProbes : register(t209);

SamplerState PointSampler : register(s0);
SamplerState LinearSampler : register(s1);

struct VSOutput
{
    float4 Position : SV_POSITION;
    float2 TexCoord : TEXCOORD0;
};

VSOutput CompositeVS(uint vertexID : SV_VertexID)
{
    VSOutput output;
    
    float2 uv = float2((vertexID << 1) & 2, vertexID & 2);
    output.TexCoord = uv;
    output.Position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    
    return output;
}

// 从深度重建世界坐标
float3 ReconstructWorldPosition(float2 uv, float depth)
{
    float4 ndc = float4(uv * 2.0 - 1.0, depth, 1.0);
    ndc.y = -ndc.y;  // Flip Y
    
    float4 worldPos = mul(RC_ViewProjInverse, ndc);
    worldPos /= worldPos.w;
    
    return worldPos.xyz;
}

// 评估 SH 基函数
void EvaluateSHBasis(float3 dir, out float basis[9])
{
    basis[0] = 0.282095;
    basis[1] = 0.488603 * dir.y;
    basis[2] = 0.488603 * dir.z;
    basis[3] = 0.488603 * dir.x;
    basis[4] = 1.092548 * dir.x * dir.y;
    basis[5] = 1.092548 * dir.y * dir.z;
    basis[6] = 0.315392 * (3.0 * dir.z * dir.z - 1.0);
    basis[7] = 1.092548 * dir.x * dir.z;
    basis[8] = 0.546274 * (dir.x * dir.x - dir.y * dir.y);
}

// 从 SH 系数评估辐射度
float3 EvaluateSH(float sh_r[9], float sh_g[9], float sh_b[9], float3 dir)
{
    float basis[9];
    EvaluateSHBasis(dir, basis);
    
    float3 result = 0;
    
    [unroll]
    for (int i = 0; i < 9; i++)
    {
        result.r += sh_r[i] * basis[i];
        result.g += sh_g[i] * basis[i];
        result.b += sh_b[i] * basis[i];
    }
    
    return max(result, 0);
}

float3 SampleRadianceCache(float3 worldPos, float3 normal)
{
    //找到最近的 4-8 个 Probes
    const int MAX_PROBES = 8;
    int nearbyIndices[MAX_PROBES];
    float distances[MAX_PROBES];
    
    [unroll]
    for (int i = 0; i < MAX_PROBES; i++)
    {
        nearbyIndices[i] = -1;
        distances[i] = 1e10;
    }
    
    // active probes（简化版：实际应该用空间数据结构）
    for (uint i = 0; i < RC_ActiveProbeCount && i < RC_MaxProbes; i++)
    {
        RadianceProbeGPU probe = g_RadianceProbes[i];
        
        float dist = distance(worldPos, probe.WorldPosition);
        
        // 插入到最近的 8 个
        [unroll]
        for (int k = 0; k < MAX_PROBES; k++)
        {
            if (dist < distances[k])
            {
                // Shift
                for (int m = MAX_PROBES - 1; m > k; m--)
                {
                    distances[m] = distances[m - 1];
                    nearbyIndices[m] = nearbyIndices[m - 1];
                }
                distances[k] = dist;
                nearbyIndices[k] = i;
                break;
            }
        }
    }
    
    float3 totalRadiance = 0;
    float totalWeight = 0;
    
    [unroll]
    for (int j = 0; j < MAX_PROBES; j++)
    {
        if (nearbyIndices[j] < 0)
            continue;
        
        RadianceProbeGPU probe = g_RadianceProbes[nearbyIndices[j]];
        
        // ✅ 从 SH 评估法线方向的辐射度
        float3 probeRadiance = EvaluateSH(
            probe.SH_R,
            probe.SH_G,
            probe.SH_B,
            normal
        );
        
        // ✅ 距离权重（inverse distance）
        float weight = 1.0 / (distances[j] + 0.1);
        
        totalRadiance += probeRadiance * weight * probe.Validity;
        totalWeight += weight * probe.Validity;
    }
    
    if (totalWeight > 0.01)
        return totalRadiance / totalWeight;
    
    return float3(0, 0, 0);
}

float3 SampleSurfaceCache(float3 worldPos, float3 normal)
{
    // ⚠️ 这个函数是可选的，用于直接可视化 Surface Cache
    // 实际上 GBuffer 已经包含了直接光照信息（如果在 GBuffer Pass 计算了）
    // 或者我们在 Card Capture 时已经计算了直接光照
    
    // 这里简化为返回 0（因为我们已经在 Card Capture 计算了直接光照）
    // 如果需要可视化，可以实现 Card 查询逻辑
    
    return float3(0, 0, 0);
}


float4 CompositePS(VSOutput input) : SV_TARGET
{
    uint2 pixelCoord = uint2(input.Position.xy);
    
    float depth = g_DepthBuffer[pixelCoord];
    
    if (depth >= 0.9999)
    {
        float3 viewDir = normalize(ReconstructWorldPosition(input.TexCoord, depth) - RC_CameraPosition);
        float skyFactor = saturate(viewDir.y * 0.5 + 0.5);
        float3 skyColor = lerp(float3(0.3, 0.5, 0.7), float3(0.05, 0.1, 0.2), skyFactor);
        return float4(skyColor, 1.0);
    }
    
    float3 worldPos = ReconstructWorldPosition(input.TexCoord, depth);
    
    float4 albedo = g_GBufferAlbedo[pixelCoord];
    float3 normal = normalize(g_GBufferNormal[pixelCoord].xyz * 2.0 - 1.0);
    float4 material = g_GBufferMaterial[pixelCoord];
    
    float roughness = material.r;
    float metallic = material.g;
    float ao = material.b;
    
    // ✅ 4. 采样直接光照
    // 方案 A：如果 GBuffer Pass 已经计算了光照，直接使用 albedo
    // 方案 B：如果需要从 Surface Cache 读取，调用 SampleSurfaceCache
    // 方案 C：在 Composite 中重新计算光照（最灵活）
    
    // 这里我们假设 GBuffer 的 albedo 已经包含了基础颜色
    // 直接光照可以从其他地方获取（例如额外的 light buffer）
    // 简化起见，我们只使用环境光
    float3 directLight = float3(0.1, 0.1, 0.1);  // 简单环境光

    // Radiance Cache 采样间接光照
    float3 indirectLight = SampleRadianceCache(worldPos, normal);
    
    float3 diffuseColor = albedo.rgb;
    
    float3 finalColor = diffuseColor * (directLight + indirectLight * ao);
    
    // 简单的色调映射（可选）
    finalColor = finalColor / (finalColor + 1.0);  // Reinhard
    
    // Gamma 校正
    finalColor = pow(finalColor, 1.0 / 2.2);
    
    return float4(finalColor, 1.0);
}
