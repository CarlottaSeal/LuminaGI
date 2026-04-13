cbuffer ShadowConstants : register(b5)
{
    float4x4 LightWorldToCamera;
    float4x4 LightCameraToRender;
    float4x4 LightRenderToClip;
    float ShadowMapSize;
    float ShadowBias;
    float SoftnessFactor;
    float LightSize;
    float3 LightPosition;
    float FarPlane;
    int4 ShadowLightIndices;
    float4 ShadowFarPlanes;
    float PointShadowBias;
    float PointShadowSoftness;
    int NumShadowCastingLights;
    float PLShadowPadding;
};

cbuffer DrawConstants : register(b21)
{
    uint InstanceOffset;
};

struct InstanceData
{
    float4x4 ModelToWorld;
    float4 Color;
};
StructuredBuffer<InstanceData> g_Instances : register(t243);

struct VSInput
{
    float3 position : POSITION;
    uint InstanceID : SV_InstanceID;
};

struct VSOutput
{
    float4 clipPosition : SV_Position;
};

VSOutput VertexMain(VSInput input)
{
    VSOutput output;

    InstanceData inst = g_Instances[input.InstanceID + InstanceOffset];
    float4 worldPos = mul(inst.ModelToWorld, float4(input.position, 1.0));

    float4 cameraPos = mul(LightWorldToCamera, worldPos);
    float4 renderPos = mul(LightCameraToRender, cameraPos);
    output.clipPosition = mul(LightRenderToClip, renderPos);

    return output;
}
