cbuffer RadianceCacheConstants : register(b13)
{
    uint MaxProbes;
    uint ActiveProbeCount;
    uint UpdateProbeCount;
    uint RaysPerProbe;
    
    float3 CameraPosition;
    float Padding0;
    
    float4x4 ViewProj;
    float4x4 ViewProjInverse;
    
    float ScreenWidth;
    float ScreenHeight;
    uint CurrentFrame;
    float TemporalBlend;
    
    float MaxTraceDistance;
    float ProbeSpacing;
    uint ActiveCardCount;
    float Padding1;
    
    uint AtlasWidth;
    uint AtlasHeight;
    uint TileSize;
    uint BVHNodeCount;
};

// 1. 从每个 Probe 发射射线
// 2. 使用 BVH 加速追踪 Surface Cache
// 3. 累积辐射度到球谐系数
// 4. Temporal Blending

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

struct SurfaceCardMetadata
{
    uint AtlasX;
    uint AtlasY;
    uint ResolutionX;
    uint ResolutionY;
    
    float3 Origin;
    float Padding0;
    
    float3 AxisX;
    float Padding1;
    
    float3 AxisY;
    float Padding2;
    
    float3 Normal;
    float Padding3;
    
    float2 WorldSize;
    uint Direction;
    uint Padding4;
    
    uint LightMask[4];
};

struct GPUCardBVHNode
{
    float3 BoundsMin;
    float Padding0;
    float3 BoundsMax;
    float Padding1;
    
    uint LeftFirst;   // 内部节点：左孩子索引；叶子节点：Card 起始索引
    uint CardCount;   // 叶子节点：Card 数量；内部节点：0
    uint Padding2;
    uint Padding3;
};

// Previous Probe Buffer 
StructuredBuffer<RadianceProbeGPU> PreviousProbes : register(t7);

// Current Probe Buffer (UAV, u4)
RWStructuredBuffer<RadianceProbeGPU> CurrentProbes : register(u4);

// Update List (哪些 Probes 需要更新)
// 这个需要额外绑定，暂时假设直接更新所有 active probes
// StructuredBuffer<uint> UpdateList : register(t209);  // 可选

Texture2DArray<float4> SurfaceCacheAtlas : register(t8);

// Card Metadata (SRV, t6)
StructuredBuffer<SurfaceCardMetadata> CardMetadata : register(t6);

// Card BVH (SRV, t11 12)
StructuredBuffer<GPUCardBVHNode> CardBVH : register(t11);
StructuredBuffer<uint> CardBVHIndices : register(t12);

// ✅ Samplers
SamplerState PointSampler : register(s0);
SamplerState LinearSampler : register(s1);

// ========== Utility Functions ==========

// Fibonacci Sphere 均匀采样
float3 GetFibonacciSpherePoint(uint index, uint count)
{
    float phi = 3.14159265359 * (3.0 - sqrt(5.0));  // Golden angle
    float y = 1.0 - (float(index) / float(count - 1)) * 2.0;
    float radius = sqrt(1.0 - y * y);
    float theta = phi * float(index);
    
    float x = cos(theta) * radius;
    float z = sin(theta) * radius;
    
    return normalize(float3(x, y, z));
}

// 射线 vs AABB 相交测试（Slab method）
bool RayAABBIntersect(float3 origin, float3 dir, float3 boundsMin, float3 boundsMax, float maxDist)
{
    float3 invDir = 1.0 / (dir + float3(1e-10, 1e-10, 1e-10));
    float3 t0 = (boundsMin - origin) * invDir;
    float3 t1 = (boundsMax - origin) * invDir;
    
    float3 tmin = min(t0, t1);
    float3 tmax = max(t0, t1);
    
    float tNear = max(max(tmin.x, tmin.y), tmin.z);
    float tFar = min(min(tmax.x, tmax.y), tmax.z);
    
    return tNear <= tFar && tFar >= 0.0 && tNear <= maxDist;
}

bool RayCardIntersect(
    float3 origin,
    float3 dir,
    SurfaceCardMetadata card,
    out float t,
    out float2 uv)
{
    t = 0.0;
    uv = float2(0, 0);
    
    // 平面相交
    float3 cardNormal = card.Normal;
    float denom = dot(dir, cardNormal);
    
    if (abs(denom) < 0.001)
        return false;
    
    t = dot(card.Origin - origin, cardNormal) / denom;
    
    if (t < 0.01)
        return false;
    
    // 计算交点
    float3 hitPos = origin + dir * t;
    
    // 转换到 Card 局部坐标
    float3 localVec = hitPos - card.Origin;
    float2 localUV;
    localUV.x = dot(localVec, card.AxisX) / card.WorldSize.x;
    localUV.y = dot(localVec, card.AxisY) / card.WorldSize.y;
    
    // 检查是否在 Card 范围内
    if (localUV.x < -0.5 || localUV.x > 0.5 ||
        localUV.y < -0.5 || localUV.y > 0.5)
        return false;
    
    uv = localUV;
    return true;
}

// 从 Card UV 采样 Surface Cache
float3 SampleCardAtUV(SurfaceCardMetadata card, float2 localUV)
{
    // 转换到 Atlas 像素坐标
    float2 pixelPos = float2(card.AtlasX, card.AtlasY) + 
                      (localUV + 0.5) * float2(card.ResolutionX, card.ResolutionY);
    
    // 转换到 Atlas UV [0, 1]
    float2 atlasUV = (pixelPos + 0.5) / float2(AtlasWidth, AtlasHeight);
    
    // ✅ 采样 DirectLight 层（Layer 3）
    float4 directLight = SurfaceCacheAtlas.SampleLevel(LinearSampler, float3(atlasUV, 3), 0);
    
    return directLight.rgb;
}

// ========== BVH 遍历 ==========

float3 TraceSurfaceCacheWithBVH(float3 origin, float3 dir, float maxDist)
{
    float closestT = maxDist;
    float3 hitRadiance = 0;
    bool hit = false;
    
    // ✅ 栈式遍历（避免递归）
    uint nodeStack[32];
    int stackPtr = 0;
    nodeStack[stackPtr++] = 0;  // 根节点
    
    while (stackPtr > 0 && stackPtr < 32)
    {
        uint nodeIndex = nodeStack[--stackPtr];
        
        if (nodeIndex >= BVHNodeCount)
            continue;
        
        GPUCardBVHNode node = CardBVH[nodeIndex];
        
        // ✅ 射线 vs AABB 测试
        if (!RayAABBIntersect(origin, dir, node.BoundsMin, node.BoundsMax, closestT))
            continue;
        
        if (node.CardCount > 0)  // 叶子节点
        {
            // ✅ 测试叶子节点的所有 Cards
            for (uint i = 0; i < node.CardCount; i++)
            {
                uint cardIndex = CardBVHIndices[node.LeftFirst + i];
                
                if (cardIndex >= ActiveCardCount)
                    continue;
                
                SurfaceCardMetadata card = CardMetadata[cardIndex];
                
                // ✅ 射线 vs Card 相交
                float t;
                float2 uv;
                bool intersect = false;
                intersect = RayCardIntersect(origin, dir, card, t, uv);
                if (intersect)
                {
                    if (t > 0.01 && t < closestT)
                    {
                        // ✅ 采样 Surface Cache
                        float3 radiance = SampleCardAtUV(card, uv);
                        
                        if (any(radiance > 0.01))
                        {
                            closestT = t;
                            hitRadiance = radiance;
                            hit = true;
                        }
                    }
                }
            }
        }
        else  // 内部节点
        {
            uint leftChild = node.LeftFirst;
            uint rightChild = leftChild + 1;
            
            // ✅ 压栈（右孩子先压，左孩子后压）
            if (rightChild < BVHNodeCount)
                nodeStack[stackPtr++] = rightChild;
            
            if (leftChild < BVHNodeCount)
                nodeStack[stackPtr++] = leftChild;
        }
    }
    
    // ✅ 如果没有击中，返回天空色
    if (!hit)
    {
        float skyFactor = saturate(dir.y * 0.5 + 0.5);
        hitRadiance = lerp(float3(0.3, 0.5, 0.7), float3(0.05, 0.1, 0.2), skyFactor);
    }
    
    return hitRadiance;
}

void EvaluateSHBasis(float3 dir, out float basis[9])
{
    basis[0] = 0.282095;                                    // L0
    basis[1] = 0.488603 * dir.y;                           // L1
    basis[2] = 0.488603 * dir.z;
    basis[3] = 0.488603 * dir.x;
    basis[4] = 1.092548 * dir.x * dir.y;                   // L2
    basis[5] = 1.092548 * dir.y * dir.z;
    basis[6] = 0.315392 * (3.0 * dir.z * dir.z - 1.0);
    basis[7] = 1.092548 * dir.x * dir.z;
    basis[8] = 0.546274 * (dir.x * dir.x - dir.y * dir.y);
}

void AccumulateSH(
    inout float sh_r[9],
    inout float sh_g[9],
    inout float sh_b[9],
    float3 dir,
    float3 radiance)
{
    float basis[9];
    EvaluateSHBasis(dir, basis);
    
    [unroll]
    for (int i = 0; i < 9; i++)
    {
        sh_r[i] += radiance.r * basis[i];
        sh_g[i] += radiance.g * basis[i];
        sh_b[i] += radiance.b * basis[i];
    }
}

void NormalizeSH(inout float sh_r[9], inout float sh_g[9], inout float sh_b[9], uint rayCount)
{
    float scale = 4.0 * 3.14159265359 / float(rayCount);
    
    [unroll]
    for (int i = 0; i < 9; i++)
    {
        sh_r[i] *= scale;
        sh_g[i] *= scale;
        sh_b[i] *= scale;
    }
}

[numthreads(64, 1, 1)]
void CSMain(uint3 DTid : SV_DispatchThreadID)
{
    if (DTid.x >= UpdateProbeCount)
        return;
    
    // 获取要更新的 Probe
    uint probeIndex = DTid.x;  // 简化：直接使用索引
    
    if (probeIndex >= MaxProbes)
        return;
    
    RadianceProbeGPU prevProbe = PreviousProbes[probeIndex];
    
    // 初始化 SH 系数
    float sh_r[9] = { 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    float sh_g[9] = { 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    float sh_b[9] = { 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    
    // 发射射线（Fibonacci Sphere）
    for (uint i = 0; i < RaysPerProbe; i++)
    {
        float3 rayDir = GetFibonacciSpherePoint(i, RaysPerProbe);
        
        float3 hitRadiance = TraceSurfaceCacheWithBVH(
            prevProbe.WorldPosition,
            rayDir,
            MaxTraceDistance
        );
        
        // 累积到 SH
        AccumulateSH(sh_r, sh_g, sh_b, rayDir, hitRadiance);
    }
    
    //归一化 SH
    NormalizeSH(sh_r, sh_g, sh_b, RaysPerProbe);
    
    //Temporal Blending (Lumen 策略：0.9)
    if (TemporalBlend > 0.01)
    {
        [unroll]
        for (uint c = 0; c < 9; c++)
        {
            sh_r[c] = lerp(sh_r[c], prevProbe.SH_R[c], TemporalBlend);
            sh_g[c] = lerp(sh_g[c], prevProbe.SH_G[c], TemporalBlend);
            sh_b[c] = lerp(sh_b[c], prevProbe.SH_B[c], TemporalBlend);
        }
    }
    
    // 6. 写回
    RadianceProbeGPU newProbe = (RadianceProbeGPU)0;
    newProbe.WorldPosition = prevProbe.WorldPosition;
    
    [unroll]
    for (uint c = 0; c < 9; c++)
    {
        newProbe.SH_R[c] = sh_r[c];
        newProbe.SH_G[c] = sh_g[c];
        newProbe.SH_B[c] = sh_b[c];
    }
    
    newProbe.LastUpdateFrame = CurrentFrame;
    newProbe.Validity = 1.0;
    newProbe.Weight = 1.0;
    
    CurrentProbes[probeIndex] = newProbe;
}
