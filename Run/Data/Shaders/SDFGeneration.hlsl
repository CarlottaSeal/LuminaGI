// Data/Shaders/SDFGenerate.hlsl
struct GPUBVHNode
{
    float3 boundsMin;
    uint leftFirst;
    float3 boundsMax;
    uint triCount;
};

struct Vertex
{
    float3 position;
    uint color;          // RGBA8 packed
    float2 uvTexCoords;
    float3 tangent;
    float3 bitangent;
    float3 normal;
};

cbuffer SDFGenConstants : register(b0)
{
    float3 boundsMin;
    uint resolution;
    float3 boundsMax;
    uint numTriangles;
};

StructuredBuffer<Vertex> g_vertices : register(t0);
StructuredBuffer<uint> g_indices : register(t1);
StructuredBuffer<GPUBVHNode> g_bvhNodes : register(t2);
StructuredBuffer<uint> g_bvhTriIndices : register(t3);

RWTexture3D<float> g_sdfOutput : register(u0);

// 点到三角形的最短距离
float PointToTriangleDistance(float3 p, float3 v0, float3 v1, float3 v2)
{
    float3 e0 = v1 - v0;
    float3 e1 = v2 - v0;
    float3 v0p = p - v0;
    
    float d00 = dot(e0, e0);
    float d01 = dot(e0, e1);
    float d11 = dot(e1, e1);
    float d20 = dot(v0p, e0);
    float d21 = dot(v0p, e1);
    
    float denom = d00 * d11 - d01 * d01;
    
    // 避免除零
    if (abs(denom) < 1e-6)
        return length(v0p);
    
    float v = (d11 * d20 - d01 * d21) / denom;
    float w = (d00 * d21 - d01 * d20) / denom;
    float u = 1.0 - v - w;
    
    // 投影点在三角形内
    if (u >= 0 && v >= 0 && w >= 0)
    {
        float3 closest = v0 * u + v1 * v + v2 * w;
        return length(p - closest);
    }
    
    // 投影点在三角形外，找最近的边
    float3 e2 = v0 - v2;
    
    // 边 v0-v1
    float t0 = saturate(dot(v0p, e0) / d00);
    float3 c0 = v0 + t0 * e0;
    float dist0 = length(p - c0);
    
    // 边 v1-v2
    float3 e1_edge = v2 - v1;
    float3 v1p = p - v1;
    float t1 = saturate(dot(v1p, e1_edge) / dot(e1_edge, e1_edge));
    float3 c1 = v1 + t1 * e1_edge;
    float dist1 = length(p - c1);
    
    // 边 v2-v0
    float3 v2p = p - v2;
    float t2 = saturate(dot(v2p, e2) / dot(e2, e2));
    float3 c2 = v2 + t2 * e2;
    float dist2 = length(p - c2);
    
    return min(dist0, min(dist1, dist2));
}

// BVH遍历查找最近三角形
float TraverseBVH(float3 pos)
{
    float minDist = 1e10;
    
    // 使用栈模拟递归
    uint stack[32];
    int stackPtr = 0;
    stack[stackPtr++] = 0; // 根节点
    
    while (stackPtr > 0)
    {
        uint nodeIdx = stack[--stackPtr];
        
        // 防止越界
        if (nodeIdx >= (uint)g_bvhNodes.Length)
            continue;
        
        GPUBVHNode node = g_bvhNodes[nodeIdx];
        
        // 计算点到AABB的距离（用于剪枝）
        float3 toMin = node.boundsMin - pos;
        float3 toMax = pos - node.boundsMax;
        float3 offset = max(max(toMin, toMax), 0.0);
        float distToBounds = length(offset);
        
        // 剪枝：如果到AABB的距离已经大于当前最小距离，跳过
        if (distToBounds > minDist)
            continue;
        
        if (node.triCount > 0)
        {
            // 叶子节点：检查所有三角形
            for (uint i = 0; i < node.triCount; i++)
            {
                uint triIdx = g_bvhTriIndices[node.leftFirst + i];
                
                // 防止越界
                if (triIdx + 2 >= numTriangles * 3)
                    continue;
                
                uint i0 = g_indices[triIdx];
                uint i1 = g_indices[triIdx + 1];
                uint i2 = g_indices[triIdx + 2];
                
                // 防止顶点索引越界
                if (i0 >= (uint)g_vertices.Length || 
                    i1 >= (uint)g_vertices.Length || 
                    i2 >= (uint)g_vertices.Length)
                    continue;
                
                float3 v0 = g_vertices[i0].position;
                float3 v1 = g_vertices[i1].position;
                float3 v2 = g_vertices[i2].position;
                
                float dist = PointToTriangleDistance(pos, v0, v1, v2);
                minDist = min(minDist, dist);
            }
        }
        else
        {
            // 内部节点：压栈子节点
            uint leftChild = node.leftFirst;
            uint rightChild = leftChild + 1;
            
            // 防止栈溢出
            if (stackPtr >= 30)
                break;
            
            // 右孩子先压栈（后访问）
            if (rightChild < (uint)g_bvhNodes.Length)
                stack[stackPtr++] = rightChild;
            
            // 左孩子后压栈（先访问）
            stack[stackPtr++] = leftChild;
        }
    }
    
    return minDist;
}

[numthreads(8, 8, 8)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    if (any(dispatchThreadID >= resolution))
        return;
    
    // 计算voxel的世界坐标
    float3 uvw = (float3(dispatchThreadID) + 0.5) / float(resolution);
    float3 worldPos = lerp(boundsMin, boundsMax, uvw);
    
    // 使用BVH查找最近距离
    float distance = TraverseBVH(worldPos);
    
    // 写入SDF（可选：归一化）
    g_sdfOutput[dispatchThreadID] = distance;
}