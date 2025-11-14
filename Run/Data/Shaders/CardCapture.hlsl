#define MAX_TEXTURE_COUNT 200
cbuffer CardCaptureConstants : register(b10)
{
    float3 CardOrigin;
    float padding0;
    float3 CardAxisX;
    float padding1;
    float3 CardAxisY;
    float padding2;
    float3 CardNormal;
    float CaptureDepth;
    
    float2 CardSize;
    uint CaptureDirection;
    uint Resolution;
    
    uint LightMask[4];
};

cbuffer ModelConstants : register(b9)
{
    float4x4 ModelMatrix; 
    float4 ModelColor;
};

cbuffer MaterialConstants : register(b3)
{
    int DiffuseId;
    int NormalId;
    int SpecularId;
    float materialPadding;
};

cbuffer CameraConstants : register(b1)
{
    float4x4 WorldToCameraTransform;
    float4x4 CameraToRenderTransform;
    float4x4 RenderToClipTransform;
    float3 CameraWorldPosition;
    float cameraPadding;
};

struct Light
{
    float4 Color;          
    float3 WorldPosition;
    float EMPTY_PADDING;
    float3 SpotForward;
    float Ambience;
    float InnerRadius;
    float OuterRadius;
    float InnerDotThreshold;
    float OuterDotThreshold;
};

cbuffer GeneralLightConstants : register(b4)
{
    float4 SunColor; 
    float3 SunNormal;
    int NumLights;
    Light LightsArray[128];  
};

Texture2D g_textures[MAX_TEXTURE_COUNT]: register(t0);
SamplerState MaterialSampler : register(s0);

float RangeMap(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (value - inMin) * (outMax - outMin) / (inMax - inMin);
}

float SmoothStep3(float t)
{
    return t * t * (3.0 - 2.0 * t);
}

bool IsLightEnabled(uint lightIndex)
{
    if (lightIndex >= 128)
        return false;
    
    uint maskIndex = lightIndex / 32;
    uint bitIndex = lightIndex % 32;
    
    return (LightMask[maskIndex] & (1u << bitIndex)) != 0;
}

struct VSInput
{
    float3 position : POSITION;
    float4 color : COLOR;
    float2 texcoord : TEXCOORD0;
    float3 tangent : TANGENT;
    float3 bitangent : BITANGENT;
    float3 normal : NORMAL;
};

struct PSInput
{
    float4 position : SV_Position;
    float3 worldPos : POSITION0;
    float3 worldNormal : NORMAL0;
    float3 worldTangent : TANGENT0;
    float3 worldBitangent : BITANGENT0;
    float2 texcoord : TEXCOORD0;
};

PSInput CardCaptureVS(VSInput input)
{
    PSInput output;
    
    // ========================================
    // 步骤 1: 转换到世界空间
    // ========================================
    float4 worldPos = mul( ModelMatrix,float4(input.position, 1.0));
    output.worldPos = worldPos.xyz;
    
    float3x3 modelMatrix3x3 = (float3x3)ModelMatrix;
    float3 worldNormal = normalize(mul(modelMatrix3x3, input.normal));
    float3 worldTangent = normalize(mul(modelMatrix3x3, input.tangent));
    float3 worldBitangent = normalize(mul(modelMatrix3x3, input.bitangent));
    
    output.worldNormal = worldNormal;
    output.worldTangent = worldTangent;
    output.worldBitangent = worldBitangent;
    output.texcoord = input.texcoord;
    
    // ========================================
    // 步骤 2: 转换到 Card 局部空间
    // ========================================
    // 世界坐标相对于 Card 原点的偏移
    float3 worldOffset = worldPos.xyz - CardOrigin;
    
    // 使用点积投影到 Card 的三个轴上（最直观的方法）
    float3 localPos;
    localPos.x = dot(worldOffset, CardAxisX);   // 沿 CardAxisX 的距离
    localPos.y = dot(worldOffset, CardAxisY);   // 沿 CardAxisY 的距离
    localPos.z = dot(worldOffset, CardNormal);  // 沿 CardNormal 的距离（深度）
    
    // 此时：
    // localPos.x: 在 Card X 轴上的投影 (水平方向)
    // localPos.y: 在 Card Y 轴上的投影 (垂直方向)
    // localPos.z: 在 Card 法线上的投影 (深度方向)
    
    // ========================================
    // 步骤 3: 正交投影到 NDC 空间 [-1, 1]
    // ========================================
    float2 ndc;
    
    // X 轴：[-CardSize.x/2, CardSize.x/2] -> [-1, 1]
    ndc.x = localPos.x / (CardSize.x * 0.5);
    
    // Y 轴：DirectX 左手坐标系，屏幕空间 Y 向下
    // [-CardSize.y/2, CardSize.y/2] -> [1, -1] (注意翻转)
    ndc.y = -localPos.y / (CardSize.y * 0.5);
    
    // ========================================
    // 步骤 4: 深度计算
    // ========================================
    // 深度范围：从 Card 表面 (0) 到 CaptureDepth (1)
    float depth = localPos.z / CaptureDepth;
    depth = saturate(depth);  // 钳制到 [0, 1]
    
    // ========================================
    // 步骤 5: 背面剔除优化
    // ========================================
    // 只捕获朝向 Card 的面，背面推到 far plane 外
    float facing = dot(worldNormal, CardNormal);
    
    if (facing < -0.05)  // 背对 Card (容差 ~3°)
    {
        depth = 1.1;  // 推到 far plane 外，会被剔除
    }
    
    // ========================================
    // 步骤 6: 输出裁剪空间位置
    // ========================================
    output.position = float4(ndc.x, ndc.y, depth, 1.0);
    
    return output;
}

struct PSOutput
{
    float4 albedo : SV_Target0;        // Layer 0: Albedo (RGB + Alpha)
    float4 normal : SV_Target1;        // Layer 1: World Normal [0,1]
    float4 material : SV_Target2;      // Layer 2: Roughness, Metallic, AO
    float4 directLight : SV_Target3;   // Layer 3: Direct Lighting
};

PSOutput CardCapturePS(PSInput input)
{
    PSOutput output;

    output.albedo = g_textures[DiffuseId].Sample(MaterialSampler, input.texcoord);
    
    // Alpha test
    if (output.albedo.a < 0.1)
        discard;
    
    float3 tangentNormal = g_textures[NormalId].Sample(MaterialSampler, input.texcoord).xyz;
    tangentNormal = tangentNormal * 2.0 - 1.0;  // [0,1] -> [-1,1]
    
    float3 N = normalize(input.worldNormal);
    float3 T = normalize(input.worldTangent);
    T = normalize(T - dot(T, N) * N);  // Gram-Schmidt 正交化
    float3 B = normalize(input.worldBitangent);
    
    float3x3 TBN = float3x3(T, B, N);
    float3 worldNormal = mul(tangentNormal, TBN);
    worldNormal = normalize(worldNormal);
    
    output.normal = float4(worldNormal * 0.5 + 0.5, 1.0);
    
    float4 materialProps = g_textures[SpecularId].Sample(MaterialSampler, input.texcoord);
    output.material = materialProps;
    
    float roughness = materialProps.r;
    float metallic = materialProps.g;
    //float ao = materialProps.b;
    
    float glossiness = 1.0 - roughness;
    float specularity = lerp(0.04, 1.0, metallic);  // 非金属 0.04，金属 1.0
    float specularExponent = pow(8192.0, glossiness);
    
    float3 diffuseColor = output.albedo.rgb;
    float3 pixelNormalWorldSpace = worldNormal;
    float3 pixelToCameraDir = normalize(CameraWorldPosition - input.worldPos);
    
    float3 totalDiffuseLight = 0;
    float3 totalSpecularLight = 0;
    
    {
        float3 sunDir = -normalize(SunNormal);  
        float sunDiffuseDot = saturate(dot(sunDir, pixelNormalWorldSpace));
        float3 sunDiffuseLight = sunDiffuseDot * SunColor.rgb * SunColor.a;
        totalDiffuseLight += sunDiffuseLight;
        
        // Specular calculation following BlinnPhong style
        float3 sunIdealReflectionDir = normalize(pixelToCameraDir + sunDir);
        float sunSpecularDot = saturate(dot(sunIdealReflectionDir, pixelNormalWorldSpace));
        float sunSpecularStrength = glossiness * SunColor.a * pow(sunSpecularDot, specularExponent);
        float3 sunSpecularLight = sunSpecularStrength * SunColor.rgb;
        totalSpecularLight += sunSpecularLight;
    }
    
    for (int lightIndex = 0; lightIndex < NumLights; lightIndex++)
    {
        if (!IsLightEnabled(lightIndex))
            continue;
        
        Light light = LightsArray[lightIndex];
        
        float3 lightPos = light.WorldPosition;
        float3 lightColor = light.Color.rgb;
        float lightBrightness = light.Color.a;
        float innerRadius = light.InnerRadius;
        float outerRadius = light.OuterRadius;
        float innerPenumbraDot = light.InnerDotThreshold;
        float outerPenumbraDot = light.OuterDotThreshold;
        float ambience = light.Ambience;
    
        float3 pixelToLightDisp = lightPos - input.worldPos;
        float3 pixelToLightDir = normalize(pixelToLightDisp);
        float3 lightToPixelDir = -pixelToLightDir;
        float distToLight = length(pixelToLightDisp);
        
        float falloff = saturate(RangeMap(distToLight, innerRadius, outerRadius, 1.0, 0.0));
        falloff = SmoothStep3(falloff);
        
        float penumbra = saturate(RangeMap(
            dot(light.SpotForward, lightToPixelDir),
            outerPenumbraDot,
            innerPenumbraDot,
            0.0,
            1.0
        ));
        penumbra = SmoothStep3(penumbra);
        
        float lightStrength = penumbra * falloff * lightBrightness * 
            saturate(RangeMap(dot(pixelToLightDir, pixelNormalWorldSpace), -ambience, 1.0, 0.0, 1.0));
        float3 diffuseLight = lightStrength * lightColor;
        totalDiffuseLight += diffuseLight;
        
        float3 idealReflectionDir = normalize(pixelToCameraDir + pixelToLightDir);
        float specularDot = saturate(dot(idealReflectionDir, pixelNormalWorldSpace));
        float specularStrength = glossiness * lightBrightness * pow(specularDot, specularExponent);
        specularStrength *= falloff * penumbra;
        float3 specularLight = specularStrength * lightColor;
        totalSpecularLight += specularLight;
    }
    
    float3 finalRGB = (saturate(totalDiffuseLight) * diffuseColor.rgb) + (totalSpecularLight * specularity);
    
    output.directLight = float4(finalRGB, 1.0);
    
    return output;
}