cbuffer ModelConstants : register(b2)
{
    float4x4 ModelToWorldTransform;
    float4 ModelColor;
};

cbuffer ShadowConstants : register(b6)
{
    float4x4 LightWorldToCamera;     
    float4x4 LightCameraToRender;
    float4x4 LightRenderToClip;
    float ShadowMapSize;
    float ShadowBias;
    float2 Padding;
};
struct VSInput
{
    float3 position : POSITION;
    // 其他属性不需要，Shadow Pass 只关心位置
};

struct VSOutput
{
    float4 clipPosition : SV_Position;
};

VSOutput VertexMain(VSInput input)
{
    VSOutput output;
    
    float4 worldPos = mul(ModelToWorldTransform, float4(input.position, 1.0));
    
    float4 cameraPos = mul(LightWorldToCamera, worldPos);
    float4 renderPos = mul(LightCameraToRender, cameraPos);
    output.clipPosition = mul(LightRenderToClip, renderPos);
    
    return output;
}

// 无 Pixel Shader - 硬件自动写入深度到 Depth Buffer
// PSO 中 PS = nullptr
