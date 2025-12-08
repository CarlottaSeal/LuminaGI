struct GPUBVHNode
{
    float3 boundsMin;
    uint leftFirst;
    float3 boundsMax;
    uint triCount;
    uint rightChild;  
    uint3 padding;
};

struct Vertex
{
    float3 position;
    uint color;          
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
    uint numVertices;     
    uint numBVHNodes;     
    float padding[2];   
};

StructuredBuffer<Vertex> g_vertices : register(t0);
StructuredBuffer<uint> g_indices : register(t1);
StructuredBuffer<GPUBVHNode> g_bvhNodes : register(t2);
StructuredBuffer<uint> g_bvhTriIndices : register(t3);

RWTexture3D<float> g_sdfOutput : register(u0);

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
    
    // 投影点在三角形外，找最近的边或顶点
    float minDist = 1e10;
    
    // 检查三个顶点
    minDist = min(minDist, length(p - v0));
    minDist = min(minDist, length(p - v1));
    minDist = min(minDist, length(p - v2));
    
    // 检查三条边
    // 边 v0-v1
    float t = saturate(dot(p - v0, e0) / max(d00, 1e-6));
    float3 closest = v0 + t * e0;
    minDist = min(minDist, length(p - closest));
    
    // 边 v1-v2
    float3 e1_edge = v2 - v1;
    t = saturate(dot(p - v1, e1_edge) / max(dot(e1_edge, e1_edge), 1e-6));
    closest = v1 + t * e1_edge;
    minDist = min(minDist, length(p - closest));
    
    // 边 v2-v0
    float3 e2 = v0 - v2;
    t = saturate(dot(p - v2, e2) / max(dot(e2, e2), 1e-6));
    closest = v2 + t * e2;
    minDist = min(minDist, length(p - closest));
    
    return minDist;
}

#define MAX_STACK_SIZE 32  

float TraverseBVH_Optimized(float3 pos)
{
    float minDist = 1e10;
    uint stack[MAX_STACK_SIZE];
    int stackPtr = 0;
    stack[stackPtr++] = 0;
    
    while (stackPtr > 0)
    {
        uint nodeIdx = stack[--stackPtr];
    
        if (nodeIdx >= (uint)g_bvhNodes.Length)
            continue;
    
        GPUBVHNode node = g_bvhNodes[nodeIdx];

        float3 expandedMin = node.boundsMin - minDist;
        float3 expandedMax = node.boundsMax + minDist;
        if (any(pos < expandedMin) || any(pos > expandedMax))
            continue;
    
        if (node.triCount > 0)
        {
            // 叶子节点：遍历三角形
            for (uint i = 0; i < node.triCount; i++)
            {
                uint indexOffset = g_bvhTriIndices[node.leftFirst + i];
    
                if (indexOffset + 2 >= (uint)g_indices.Length)
                    continue;
    
                uint i0 = g_indices[indexOffset];
                uint i1 = g_indices[indexOffset + 1];
                uint i2 = g_indices[indexOffset + 2];
    
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
            // 内部节点：将子节点压入栈

            // ✅ 重要：先压入较远的子节点，后压入较近的子节点
            // 这样较近的子节点会先被处理，可以更快找到更小的距离

            uint leftChild = node.leftFirst;
            uint rightChild = node.rightChild;

            bool hasLeft = (leftChild < (uint)g_bvhNodes.Length);
            bool hasRight = (rightChild != 0xFFFFFFFF && rightChild < (uint)g_bvhNodes.Length);

            if (hasLeft && hasRight)
            {
                // 计算点到两个子节点 AABB 的距离
                GPUBVHNode leftNode = g_bvhNodes[leftChild];
                GPUBVHNode rightNode = g_bvhNodes[rightChild];
    
                // 简化的距离计算（点到 AABB 的距离）
                float3 leftCenter = (leftNode.boundsMin + leftNode.boundsMax) * 0.5;
                float3 rightCenter = (rightNode.boundsMin + rightNode.boundsMax) * 0.5;
                float leftDist = length(pos - leftCenter);
                float rightDist = length(pos - rightCenter);
    
                // 先压入较远的，后压入较近的
                if (leftDist < rightDist)
                {
                    if (stackPtr < MAX_STACK_SIZE)
                        stack[stackPtr++] = rightChild;
                    if (stackPtr < MAX_STACK_SIZE)
                        stack[stackPtr++] = leftChild;
                }
                else
                {
                    if (stackPtr < MAX_STACK_SIZE)
                        stack[stackPtr++] = leftChild;
                    if (stackPtr < MAX_STACK_SIZE)
                        stack[stackPtr++] = rightChild;
                }
            }
            else if (hasLeft)
            {
                if (stackPtr < MAX_STACK_SIZE)
                    stack[stackPtr++] = leftChild;
            }
            else if (hasRight)
            {
                if (stackPtr < MAX_STACK_SIZE)
                    stack[stackPtr++] = rightChild;
            }
        }
    }
    return minDist;
}

// ========== 旧的暴力遍历方法（作为参考/调试用） ==========
float TraverseBVH_BruteForce(float3 pos)
{
    float minDist = 1e10;
    
    // 暴力遍历所有节点
    for (uint nodeIdx = 0; nodeIdx < (uint)g_bvhNodes.Length; nodeIdx++)
    {
        GPUBVHNode node = g_bvhNodes[nodeIdx];
        
        if (node.triCount == 0)
            continue;  // 跳过内部节点
        
        // 只处理叶子节点
        for (uint i = 0; i < node.triCount; i++)
        {
            uint indexOffset = g_bvhTriIndices[node.leftFirst + i];
            
            if (indexOffset + 2 >= (uint)g_indices.Length)
                continue;
            
            uint i0 = g_indices[indexOffset];
            uint i1 = g_indices[indexOffset + 1];
            uint i2 = g_indices[indexOffset + 2];
            
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
    
    return minDist;
}


[numthreads(8, 8, 8)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{   
    // 正常 SDF 计算
    float3 uvw = (float3(dispatchThreadID) + 0.5) / float(resolution);
    float3 worldPos = lerp(boundsMin, boundsMax, uvw);
    
    float distance = TraverseBVH_Optimized(worldPos);
    
    // 如果需要调试，可以切换回暴力方法对比结果
    // float distance = TraverseBVH_BruteForce(worldPos);
    
    g_sdfOutput[dispatchThreadID] = distance;
}
