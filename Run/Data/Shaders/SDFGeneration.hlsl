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
    uint zSliceOffset;
    float padding;
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
    
    // Projection point is inside triangle
    if (u >= 0 && v >= 0 && w >= 0)
    {
        float3 closest = v0 * u + v1 * v + v2 * w;
        return length(p - closest);
    }

    // Projection outside triangle; find nearest edge or vertex
    float minDist = 1e10;

    // Check three vertices
    minDist = min(minDist, length(p - v0));
    minDist = min(minDist, length(p - v1));
    minDist = min(minDist, length(p - v2));

    // Check three edges
    // Edge v0-v1
    float t = saturate(dot(p - v0, e0) / max(d00, 1e-6));
    float3 closest = v0 + t * e0;
    minDist = min(minDist, length(p - closest));

    // Edge v1-v2
    float3 e1_edge = v2 - v1;
    t = saturate(dot(p - v1, e1_edge) / max(dot(e1_edge, e1_edge), 1e-6));
    closest = v1 + t * e1_edge;
    minDist = min(minDist, length(p - closest));

    // Edge v2-v0
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
            // Leaf node: iterate triangles
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
            // Internal node: push child nodes onto stack

            // Push farther child first so the closer child is processed first —
            // tightens the distance bound sooner and prunes more nodes

            uint leftChild = node.leftFirst;
            uint rightChild = node.rightChild;

            bool hasLeft = (leftChild < (uint)g_bvhNodes.Length);
            bool hasRight = (rightChild != 0xFFFFFFFF && rightChild < (uint)g_bvhNodes.Length);

            if (hasLeft && hasRight)
            {
                // Compute point-to-AABB distance for both children
                GPUBVHNode leftNode = g_bvhNodes[leftChild];
                GPUBVHNode rightNode = g_bvhNodes[rightChild];
    
                // Simplified point-to-AABB distance (center distance)
                float3 leftCenter = (leftNode.boundsMin + leftNode.boundsMax) * 0.5;
                float3 rightCenter = (rightNode.boundsMin + rightNode.boundsMax) * 0.5;
                float leftDist = length(pos - leftCenter);
                float rightDist = length(pos - rightCenter);
    
                // Push farther first, closer second
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



[numthreads(8, 8, 8)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    // Z-slice partitioning: actual voxel coord = dispatch coord + Z offset
    uint3 voxelCoord = uint3(dispatchThreadID.xy, dispatchThreadID.z + zSliceOffset);

    if (voxelCoord.x >= resolution || voxelCoord.y >= resolution || voxelCoord.z >= resolution)
        return;

    // Normal SDF computation
    float3 uvw = (float3(voxelCoord) + 0.5) / float(resolution);
    float3 worldPos = lerp(boundsMin, boundsMax, uvw);

    float distance = TraverseBVH_Optimized(worldPos);


    g_sdfOutput[voxelCoord] = distance;
}
