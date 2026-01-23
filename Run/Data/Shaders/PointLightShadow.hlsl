// Point Light Cube Shadow Map Shader
// 输出线性深度 (distance / farPlane) 而非透视深度

cbuffer ModelConstants : register(b2)
{
    float4x4 ModelToWorldTransform;
    float4 ModelColor;
};

cbuffer ShadowConstants : register(b5)
{
    float4x4 LightWorldToCamera;
    float4x4 LightCameraToRender;
    float4x4 LightRenderToClip;
    float ShadowMapSize;
    float ShadowBias;
    float SoftnessFactor;
    float LightSize;
    // 点光源阴影额外数据
    float3 LightPosition;
    float FarPlane;
};

struct VSInput
{
    float3 position : POSITION;
};

struct VSOutput
{
    float4 clipPosition : SV_Position;
    float3 worldPosition : TEXCOORD0;
};

VSOutput VertexMain(VSInput input)
{
    VSOutput output;

    float4 worldPos = mul(ModelToWorldTransform, float4(input.position, 1.0));
    output.worldPosition = worldPos.xyz;

    float4 cameraPos = mul(LightWorldToCamera, worldPos);
    float4 renderPos = mul(LightCameraToRender, cameraPos);
    output.clipPosition = mul(LightRenderToClip, renderPos);

    return output;
}

// Pixel Shader 输出线性深度
float PixelMain(VSOutput input) : SV_Depth
{
    float distance = length(input.worldPosition - LightPosition);
    float linearDepth = distance / FarPlane;
    return saturate(linearDepth);
}
