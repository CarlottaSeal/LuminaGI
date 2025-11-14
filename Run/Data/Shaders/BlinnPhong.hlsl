//------------------------------------------------------------------------------------------------
// Blinn-Phong (lit) shader for Squirrel Eiserloh's C34 SD student Engine (Spring 2025)
//
// Requires Vertex_PCUTBN vertex data (including valid tangent, bitangent, normal).
//------------------------------------------------------------------------------------------------
// D3D11 basic rendering pipeline stages (and D3D11 function prefixes):
//	IA = Input Assembly (grouping verts 3 at a time to form triangles, or N to form lines, fans, chains, etc.)
//	VS = Vertex Shader (transforming vertexes; moving them around, and computing them in different spaces)
//	RS = Rasterization Stage (converting math triangles into discrete pixels covered, interpolating values within)
//	PS = Pixel Shader (a.k.a. Fragment Shader, computing the actual output color(s) at each pixel being drawn)
//	OM = Output Merger (combining PS output with existing colors, using the current blend mode: additive, alpha, etc.)
//
// D3D11 C++ functions are prefixed with the stage they apply to, so for example:
//	m_d3dContext->IASetInputLayout( layout );							// Input Assembly knows to expect verts as PCU or PCUTBN or...
//	m_d3dContext->IASetVertexBuffers( 0, 1, &vbo.m_gpuBuffer, &vbo.m_vertexSize, &offset ); // Bind VBOs for Input Assembly
//	m_d3dContext->IASetPrimitiveTopology( D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST );	// Triangles vs. TriStrips, TriFans, LineList, etc.
//	m_d3dContext->VSSetShader( shader->m_vertexShader, nullptr, 0 );	// Set current Vertex Shader program
//	m_d3dContext->VSSetConstantBuffers( 3, 1, &cbo->m_gpuBuffer );		// CBO is accessible in Vertex Shader as register(b3)
//	m_d3dContext->RSSetViewports( 1, &viewport );						// Set viewport(s) to use in Rasterization Stage
//	m_d3dContext->RSSetState( m_rasterState );							// Set Rasterization Stage states, e.g. cull, fill, winding
//	m_d3dContext->PSSetShader( shader->m_pixelShader, nullptr, 0 );		// Set current Pixel Shader program
//	m_d3dContext->PSSetConstantBuffers( 3, 1, &cbo->m_gpuBuffer );		// CBO is accessible in Pixel Shader as register(b3)
//	m_d3dContext->PSSetShaderResources( 3, 1, &texture->m_shaderResourceView );	// Texture available in Pixel Shader as register(t3)
//	m_d3dContext->PSSetSamplers( 3, 1, &samplerState );					// Sampler is used in Pixel Shader as register(s3)
//	m_d3dContext->OMSetBlendState( m_blendStateAlpha, nullptr, 0xFFFFFFFF ); // Set alpha blend state in Output Merger
//	m_d3dContext->OMSetRenderTargets( 1, &m_backBufferRTV, dsv );		// Set render target texture(s) for Output Merger
//	m_d3dContext->OMSetDepthStencilState( m_depthStencilState, 0 );		// Set depth & stencil mode for Output Merger
//------------------------------------------------------------------------------------------------


//------------------------------------------------------------------------------------------------
// Input to the Vertex shader stage.
// Information contained per vertex, pulled from the VBO being drawn.
//------------------------------------------------------------------------------------------------
struct VertexInput
{
	// "v_" stands for for "Vertex" attribute which comes directly from VBO data (Squirrel's convention)
	// The all-caps "semantic names" are arbitrary symbol to associate CPU-GPU and other linkages.
	float3	a_position		: POSITION;		
	float4	a_color			: COLOR; // Expanded to float[0.f,1.f] from byte[0,255] because "UNORM" in DXGI_FORMAT_R8G8B8A8_UNORM
	float2	a_uvTexCoords	: TEXCOORD; //aka UV_TEXCOORDS
	float3	a_tangent		: TANGENT; 
	float3	a_bitangent		: BITANGENT; 
	float3	a_normal		: NORMAL; 
	
	// Built-in / automatic attributes (not part of incoming VBO data)
	// "SV_" means "System Variable" and is a built-in special reserved semantic
	uint	a_vertexID	: SV_VertexID; // Which vertex number in the VBO collection this is (automatic variable)
};


//------------------------------------------------------------------------------------------------
// Output passed from the Vertex shader into the Pixel/fragment shader.
// 
// Each of these values is automatically 3-way (barycentric) interpolated across the surface of
//	the triangle on a per-pixel basis during the Rasterization Stage (RS).
// "v_" stands for "Varying" meaning "barycentric-lepred" (Squirrel's personal convention)
//
// Note that the SV_Position variable is required, and expects the Vertex Shader (VS) to output
//	this variable in clip space; after the VS stage, before the Rasterization Stage (RS), this position
//	gets divided by its w value to convert from clip space to NDC (Normalized Device Coordinates).
//
// It is then 3-way (barycentric) interpolated across the surface of the triangle along with the
//	other variables here; the Pixel Shader (PS) stage then receives these interpolated values
//	which will be unique per pixel, and the SV_Position variable will be in NDC space.
//
// Semantic names other than "SV_" (System Variables) are arbitrary, and just need to match up
//	between the variable in the Vertex Shader output structure and the corresponding variable in the
//	Pixel Shader input structure.  Since we use the same structure for both, they all automatically
//	match up.
//------------------------------------------------------------------------------------------------
struct VertexOutPixelIn 
{
	float4 v_position		: SV_Position; // Required; VS output as clip-space vertex position; PS input as NDC pixel position.
	float4 v_color			: SURFACE_COLOR;
	float2 v_uvTexCoords	: SURFACE_UVTEXCOORDS;
	float3 v_worldPos		: WORLD_POSITION;
	float3 v_worldTangent	: WORLD_TANGENT;
	float3 v_worldBitangent	: WORLD_BITANGENT;
	float3 v_worldNormal	: WORLD_NORMAL;
	//float3 v_modelTangent	: MODEL_TANGENT;
	//float3 v_modelBitangent	: MODEL_BITANGENT;
	//float3 v_modelNormal	: MODEL_NORMAL;
};

struct Light
{
	float4 c_color; 			// Alpha (w) is intensity/brightness in [0,1]
	float3 c_worldPosition;		// World position of point/spot light source
	float EMPTY_PADDING;		// Used in constant buffers, must follow strict alignment rules
	float3 c_spotForward;		// Forward normal for spotlights (can be zero for omnidirectional point-lights)
	float c_ambience;			// Portion of indirect light this source gives to objects in its affected volume
	float c_innerRadius;		// Inside the inner radius, the light is at full strength
	float c_outerRadius;		// Outside the outer radius, the light has no effect
	float c_innerDotThreshold;	// If dot with forward is greater than inner threshold, full strength; -1 for point lights
	float c_outerDotThreshold;	// if dot with forward is less than outer threshold, zero strength; -2 for point lights
};

//------------------------------------------------------------------------------------------------
// CONSTANT BUFFERS (a.k.a. CBOs or Constant Buffer Objects, UBOs / Uniform Buffers in OpenGL)
//	"c_" stands for "Constant", Squirrel's personal naming convention.
//
// There are 14 available CBO "slots" or "registers" (b0 through b13).
//	If the C++ code binds to slot 5, we are binding to constant buffer register(b5)
// In C++ code we bind structures into CBO slots when we call:
//	m_d3dContext->VSSetConstantBuffers( slot, 1, &cbo->m_gpuBuffer ); VS... makes this CBO available in Vertex Shader
//	m_d3dContext->PSSetConstantBuffers( slot, 1, &cbo->m_gpuBuffer ); PS... makes this CBO available in Pixel Shader
//
// We might update some CBOs once per frame; others perhaps between each draw call; others only occasionally.
// CBOs have very picky alignment rules, but can otherwise be anything we want (max of 64k == 65536 bytes each).
//
// Guildhall-specific conventions we use for different CBO register slot numbers (b0 through b13):
//	register(b0) = Engine/System-Level constants (e.g. debug)	-- updated rarely
//	register(b1) = Per-Frame constants (e.g. time)				-- updated once per frame, maybe in Renderer::BeginFrame
//	register(b2) = Camera constants (e.g. view/proj matrices)	-- updated once in each Renderer::CameraBegin
//	register(b3) = Model constants (e.g. model matrix & tint)	-- updated once before each Renderer::DrawVertexBuffer call
//	b4-b7 = Other Engine-reserved slots
//	b8-b13 = Other Game-specific slots
//
// NOTE: Constant Buffers MUST be 16B-aligned (sizeof is a multiple of 16B), AND
//	also primitives may not cross 16B boundaries (unless they are 16B-aligned, like Mat44).
// So you must "pad out" any variables with dummy variables to make sure they adhere to these
//	rules, and make sure that your corresponding C++ struct has identical byte-layout to the shader struct.
// I find it easiest to think of this as the CBO having multiple rows, each row float4 (Vec4 == 16B) in size.
//------------------------------------------------------------------------------------------------
cbuffer PerFrameConstants : register(b1)
{
	float		c_time;
	int			c_debugInt;
	float		c_debugFloat;
	float		EMPTY_PADDING;
};


//------------------------------------------------------------------------------------------------
cbuffer CameraConstants : register(b2)
{
	float4x4	c_worldToCamera;	// a.k.a. "View" matrix; world space (+X east) to camera-relative space (+X camera-forward)
	float4x4	c_cameraToRender;	// a.k.a. "Game" matrix; axis-swaps from Game conventions (+X forward) to Render (+X right)
	float4x4	c_renderToClip;		// a.k.a. "Projection" matrix (perpective or orthographic); render space to clip space

	float3		c_cameraWorldPos;	// Camera's position in world space, convenient/fast for specular calculations
	float		EMPTY_PADDING1;
};


//------------------------------------------------------------------------------------------------
cbuffer ModelConstants : register(b3)
{
	float4x4	c_modelToWorld;		// a.k.a. "Model" matrix; model local space (+X model forward) to world space (+X east)
	float4		c_modelTint;		// Uniform Vec4 model tint (including alpha) to multiply against diffuse texel & vertex color
};

//------------------------------------------------------------------------------------------------
#define MAX_LIGHTS 8 // Must agree with corresponding constant in CPP code!
cbuffer LightConstants : register(b4)
{
	float4 	c_sunColor; 				// Alpha (w) channel is intensity; parallel sunlight
	float3 	c_sunNormal; 				// Forward direction of parallel sunlight
	int 	c_numLights;				// Actual number of point (including spot) lights, not including sunlight; others are zeroed
	Light 	c_lightsArray[MAX_LIGHTS];  // Array of Light data structs
}

//------------------------------------------------------------------------------------------------
cbuffer GameConstants : register(b8)
{
	int		c_specialEffect = 0;
	int		EMPTY_PADDING2[3];
};

//------------------------------------------------------------------------------------------------
// TEXTURE and SAMPLER constants
//
// There are 16 (on mobile) or 128 (on desktop) texture binding "slots" or "registers" (t0 through t15, or t127).
// There are 16 sampler slots (s0 through s15).
//
// In C++ code we bind textures into texture slots (t0 through t15 or t127) for use in the Pixel Shader when we call:
//	m_d3dContext->PSSetShaderResources( textureSlot, 1, &texture->m_shaderResourceView ); // e.g. (t3) if textureSlot==3
//
// In C++ code we bind texture samplers into sampler slots (s0 through s15) for use in the Pixel Shader when we call:
//	m_d3dContext->PSSetSamplers( samplerSlot, 1, &samplerState );  // e.g. (s3) if samplerSlot==3
//
// If we want to sample textures from within the Vertex Shader (VS), e.g. for displacement maps, we can also
//	use the VS versions of these C++ functions:
//	m_d3dContext->VSSetShaderResources( textureSlot, 1, &texture->m_shaderResourceView );
//	m_d3dContext->VSSetSamplers( samplerSlot, 1, &samplerState );
//------------------------------------------------------------------------------------------------
Texture2D<float4>	t_diffuseTexture		: register(t0);	// Texture bound in texture constant slot #0 (t0)
Texture2D<float4>	t_normalTexture			: register(t1);	// Texture bound in texture constant slot #1 (t1)
Texture2D<float4>	t_specGlossEmitTexture	: register(t2); // Texture bound in texture constant register(t2)
SamplerState		s_diffuseSampler		: register(s0);	// Sampler is bound in sampler constant slot #0 (s0)
SamplerState		s_normalSampler			: register(s1);	// Sampler is bound in sampler constant slot #1 (s1)
SamplerState		s_specGlossEmitSampler	: register(s2);	// Sampler is bound in sampler constant register(s2)
// #ToDo: add additional textures/samples, for specular/glossy/emissive maps, etc.


//------------------------------------------------------------------------------------------------
// VERTEX SHADER (VS)
//
// "Main" entry point for the Vertex Shader (VS) stage; this function (and functions it calls) are
//	the vertex shader program, called once per vertex.
//
// (The name of this entry function is chosen in C++ as a D3DCompile argument.)
//
// Inputs are typically vertex attributes (PCU, PCUTBN) coming from the VBO.
// Outputs include anything we want to pass through the Rasterization Stage (RS) to the Pixel Shader (PS).
//------------------------------------------------------------------------------------------------
VertexOutPixelIn VertexMain( VertexInput input )
{
	VertexOutPixelIn output;

	// Transform the position through the pipeline	
	float4 modelPos = float4( input.a_position, 1.0 );	// VBOs provide vertexes in model space
	float4 worldPos		= mul( c_modelToWorld, modelPos );		// Model space (+X local forward) to World space (+X east)
	float4 cameraPos	= mul( c_worldToCamera, worldPos );		// World space (+X east) to Camera space (+X camera-forward)
	float4 renderPos	= mul( c_cameraToRender, cameraPos );	// Camera space (+X cam-fwd) to Render space (+X right/+Z fwd)
	float4 clipPos		= mul( c_renderToClip, renderPos );		// Render space to Clip space (range-map/FOV/aspect, and put Z in W, preparing for W-divide)
	
	// Transform the tangents, normals, and bitangents (using W=0 for directions)
	float4 modelTangent		= float4( input.a_tangent, 0.0 );
	float4 modelBitangent	= float4( input.a_bitangent, 0.0 );
	float4 modelNormal		= float4( input.a_normal, 0.0 );
	float4 worldTangent		= mul( c_modelToWorld, modelTangent );		// Note: here we multiply on the right (M*V) since our C++ matrices come in from our constant
	float4 worldBitangent	= mul( c_modelToWorld, modelBitangent );	//	buffers from C++ as basis-major (as opposed to component-major).  Be careful below when
	float4 worldNormal		= mul( c_modelToWorld, modelNormal );		//	we must reverse the multiplication order (V*M) when using HLSL's float3x3 constructor!

	// Set the outputs we want to pass through Rasterization Stage (RS) down to the Pixel Shader (PS)
    output.v_position		= clipPos;
    output.v_color			= input.a_color;
    output.v_uvTexCoords	= input.a_uvTexCoords;
	output.v_worldPos		= worldPos.xyz;
	output.v_worldTangent	= worldTangent.xyz;
	output.v_worldBitangent	= worldBitangent.xyz;
	output.v_worldNormal	= worldNormal.xyz;
	//output.v_modelTangent	= modelTangent.xyz;
	//output.v_modelBitangent	= modelBitangent.xyz;
	//output.v_modelNormal	= modelNormal.xyz;

    return output; // Pass to Rasterization Stage (RS) for barycentric interpolation, then into Pixel Shader (PS)
}

//------------------------------------------------------------------------------------------------
float RangeMap( float inValue, float inStart, float inEnd, float outStart, float outEnd )
{
	float fraction = (inValue - inStart) / (inEnd - inStart);
	float outValue = outStart + fraction * (outEnd - outStart);
	return outValue;
}


//------------------------------------------------------------------------------------------------
float RangeMapClamped( float inValue, float inStart, float inEnd, float outStart, float outEnd )
{
	float fraction = saturate( (inValue - inStart) / (inEnd - inStart) );
	float outValue = outStart + fraction * (outEnd - outStart);
	return outValue;
}


//------------------------------------------------------------------------------------------------
// Used standard normal color encoding, mapping xyz in [-1,1] to rgb in [0,1]
//------------------------------------------------------------------------------------------------
float3 EncodeXYZToRGB( float3 vec )
{
	return (vec + 1.0) * 0.5;
}


//------------------------------------------------------------------------------------------------
// Used standard normal color encoding, mapping rgb in [0,1] to xyz in [-1,1]
//------------------------------------------------------------------------------------------------
float3 DecodeRGBToXYZ( float3 color )
{
	return (color * 2.0) - 1.0;
}

//------------------------------------------------------------------------------------------------
float SmoothStep3( float x )
{
	return (3.0*(x*x)) - (2.0*x)*(x*x);
}

//------------------------------------------------------------------------------------------------
float3 SmoothStop2( float3 v )
{
	float3 inverse = 1.0 - v;
	return 1.0 - (inverse * inverse);
}

//------------------------------------------------------------------------------------------------
float3 SmoothStop3( float3 v )
{
	float3 inverse = 1.0 - v;
	return 1.0 - (inverse * inverse * inverse);
}

//------------------------------------------------------------------------------------------------
float3 SmoothStart3( float3 v )
{
	return v * v * v;
}

//------------------------------------------------------------------------------------------------
float SnapToNearestFractional( float x, int numIntervals )
{
	float intervalSize = 1.0f / (float) numIntervals;
	x *= (float) numIntervals;
	x -= frac( x );
	x /= (float) numIntervals;
	return x;
}

//------------------------------------------------------------------------------------------------
// PIXEL SHADER (PS)
//
// "Main" entry point for the Pixel Shader (PS) stage; this function (and functions it calls) are
//	the pixel shader program.
//
// (The name of this entry function is chosen in C++ as a D3DCompile argument.)
//
// Inputs are typically the barycentric-interpolated outputs from the Vertex Shader (VS) via Rasterization.
// Output is the color sent to the render target, to be blended via the Output Merger (OM) blend mode settings.
// If we have multiple outputs (colors to write to each of several different Render Targets), we can change
//	this function to return a structure containing multiple float4 output colors, one per target.
//------------------------------------------------------------------------------------------------
float4 PixelMain( VertexOutPixelIn input ) : SV_Target0
{
	// I just assume sunlight has zero ambience (I hate global minimum ambient lighting!)
	float sunAmbience = 0.f;
	
	// Get the UV coordinates that were mapped onto this pixel
	float2 uvCoords = input.v_uvTexCoords;
	
	// Sample the diffuse map texture to see what this looks like at this pixel
	float4 diffuseTexel 		= t_diffuseTexture.Sample( s_diffuseSampler, uvCoords );
	float4 normalTexel			= t_normalTexture.Sample( s_normalSampler, uvCoords );
	float4 specGlossEmitTexel	= t_specGlossEmitTexture.Sample( s_specGlossEmitSampler, uvCoords );
	float specularity 	= specGlossEmitTexel.r;
	float glossiness	= specGlossEmitTexel.g;
	float emissiveness  = specGlossEmitTexel.b;
	float4 surfaceColor = input.v_color;
	//float4 modelColor = c_modelTint;

	if( c_debugInt == 7 )
	{
		specularity = 1.0;
	}
	
	//Tint (and alpha) diffuse color based on diffuse texture map, vertex triangle surface color, and overall model tinting
	float4 diffuseColor = diffuseTexel * surfaceColor * c_modelTint;
	if( diffuseColor.a <= 0.001f ) // a.k.a. "clip" in HLSL
	{
		discard;
	}	
	
	// Decode normalTexel RGB into XYZ then renormalize; this is the per-pixel normal, in TBN space a.k.a. tangent space
	float3 pixelNormalTBNSpace = normalize( DecodeRGBToXYZ( normalTexel.rgb ) );
	
	// Tint diffuse color based on overall model tinting (including alpha translucency)
	//float4 diffuseColor = diffuseTexel * surfaceColor * modelColor;
	
	// Fake directional light for now; #ToDo: add a (b4) or (b8) Light CBO
//	float3 lightDir = normalize( float3( cos(0.5 * c_time), sin(0.5 * c_time), -1.0 ) );
	//float3 lightDir = normalize( float3( 10.0, 2.0, -3.0 ) );

	// Get TBN basis vectors
	float3 surfaceTangentWorldSpace		= normalize( input.v_worldTangent );
	float3 surfaceBitangentWorldSpace	= normalize( input.v_worldBitangent );
	float3 surfaceNormalWorldSpace		= normalize( input.v_worldNormal );

	//float3 surfaceTangentModelSpace		= normalize( input.v_modelTangent );
	//float3 surfaceBitangentModelSpace	= normalize( input.v_modelBitangent );
	//float3 surfaceNormalModelSpace		= normalize( input.v_modelNormal );
	
	// Create TBN (surface-to-world) transformation matrix; WARNING: HLSL constructor stores these component-major, which is the opposite (transpose) of our basis-major matrices above!
	float3x3 tbnToWorld = float3x3( surfaceTangentWorldSpace, surfaceBitangentWorldSpace, surfaceNormalWorldSpace );
	// #ToDo: orthonormalize this (not just normalize); Do Gram-Schmidt and renormalize as we go, and remove above normalizations
	float3 pixelNormalWorldSpace = mul( pixelNormalTBNSpace, tbnToWorld ); // V*M order because this matrix is component-major (not basis-major!)
	if( c_debugInt == 10 || c_debugInt == 12 )
	{
		pixelNormalWorldSpace = surfaceNormalWorldSpace; // Bypass normal map normals
	}

	//------------------------------------------------------------------------------------------------	
	// Lighting
	//------------------------------------------------------------------------------------------------	
	float3 totalDiffuseLight = float3( 0.f, 0.f, 0.f ); // Accumulate light into here from all sources
	float3 totalSpecularLight = float3( 0.f, 0.f, 0.f );
	float specularExponent = RangeMap( glossiness, 0.f, 1.f, 1.f, 32.f );
	float3 pixelToCameraDir = normalize( c_cameraWorldPos - input.v_worldPos ); // e.g. "V" in most Blinn-Phong diagrams
	
	//------------------------------------------------------------------------------------------------	
	// Sunlight
	//------------------------------------------------------------------------------------------------		
	// Sun diffuse lighting
	float sunlightStrength = c_sunColor.a * saturate( RangeMap( dot( -c_sunNormal, pixelNormalWorldSpace ), -sunAmbience, 1.0, 0.0, 1.0 ) );
	float3 diffuseLightFromSun = sunlightStrength * c_sunColor.rgb;
	totalDiffuseLight += diffuseLightFromSun;

	// Sun specular highlight
	float3 pixelToSunDir = -c_sunNormal; // e.g. "L" in most Blinn-Phong diagrams
	float3 sunIdealReflectionDir = normalize( pixelToSunDir + pixelToCameraDir ); // e.g. "H" in most Blinn-Phong diagrams
	float sunSpecularDot = saturate( dot( sunIdealReflectionDir, pixelNormalWorldSpace ) );
	float sunSpecularStrength = glossiness * c_sunColor.a * pow( sunSpecularDot, specularExponent );
	float3 sunSpecularLight = sunSpecularStrength * c_sunColor.rgb;
	totalSpecularLight += sunSpecularLight;

//------------------------------------------------------------------------------------------------	
	// Point & Spot Lights
	//------------------------------------------------------------------------------------------------		
	for( int lightIndex = 0; lightIndex < c_numLights; ++ lightIndex )
	{
		// Point/spot diffuse lighting
		float ambience = c_lightsArray[lightIndex].c_ambience;
		float3 lightPos = c_lightsArray[lightIndex].c_worldPosition;
		float3 lightColor = c_lightsArray[lightIndex].c_color.rgb;
		float lightBrightness = c_lightsArray[lightIndex].c_color.a;
		float innerRadius = c_lightsArray[lightIndex].c_innerRadius;
		float outerRadius = c_lightsArray[lightIndex].c_outerRadius;
		float innerPenumbraDot = c_lightsArray[lightIndex].c_innerDotThreshold;
		float outerPenumbraDot = c_lightsArray[lightIndex].c_outerDotThreshold;
		float3 pixelToLightDisp = lightPos - input.v_worldPos;
		float3 pixelToLightDir = normalize( pixelToLightDisp );
		float3 lightToPixelDir = -pixelToLightDir;
		float distToLight = length( pixelToLightDisp );
		float falloff = saturate( RangeMap( distToLight, innerRadius, outerRadius, 1.f, 0.f ) );
		falloff = SmoothStep3( falloff );
		float penumbra = saturate( RangeMap( dot( c_lightsArray[lightIndex].c_spotForward, lightToPixelDir ), outerPenumbraDot, innerPenumbraDot, 0.f, 1.f ) );
		penumbra = SmoothStep3( penumbra );
		float lightStrength = penumbra * falloff * lightBrightness * saturate( RangeMap( dot( pixelToLightDir, pixelNormalWorldSpace ), -ambience, 1.0, 0.0, 1.0 ) );
		float3 diffuseLight = lightStrength * lightColor;
		totalDiffuseLight += diffuseLight;

		// Specular Highlighting (glare)
		float3 idealReflectionDir = normalize( pixelToCameraDir + pixelToLightDir );
		float specularDot = saturate( dot( idealReflectionDir, pixelNormalWorldSpace ) ); // how perfect is the reflection angle?
		float specularStrength = glossiness * lightBrightness * pow( specularDot, specularExponent );
		specularStrength *= falloff * penumbra;
		float3 specularLight = specularStrength * lightColor;
		totalSpecularLight += specularLight;
	}

	//------------------------------------------------------------------------------------------------	
	// Emissive lighting (glow)
	//------------------------------------------------------------------------------------------------	
	float3 emissiveLight = diffuseTexel.rgb * emissiveness;
	
	//------------------------------------------------------------------------------------------------	
	// Final lighting composite
	//------------------------------------------------------------------------------------------------	
	float3 finalRGB = (saturate(totalDiffuseLight) * diffuseColor.rgb) + (totalSpecularLight * specularity) + emissiveLight;
	float4 finalColor = float4( finalRGB, diffuseColor.a );
	
	if( c_specialEffect == 3 )
	{
		finalColor.a *= 0.5f;	
	}
	if( c_specialEffect == 2 )
	{
		float t = 0.6 + 0.4f * sin( 10.f * c_time );
		finalColor.rgb = lerp( SmoothStart3( finalColor.rgb), SmoothStop3( finalColor.rgb ), t );
	}
	else if( c_specialEffect == 1 )
	{
		finalColor.rgb = SmoothStop2( finalColor.rgb );
	}
	
	//------------------------------------------------------------------------------------------------	
	// Debugging overrides; bypass the above results of our normal lighting calculations and instead color-code information
	//------------------------------------------------------------------------------------------------	
	if (c_debugInt == 1)
	{
	    finalColor.rgba = diffuseTexel.rgba;
	}
	else if(c_debugInt == 2 )
	{
		finalColor.rgba = surfaceColor.rgba;
	}
	else if(c_debugInt == 3 )
	{
	    finalColor.rgb = float3(uvCoords.x, uvCoords.y, 0.f);
	}
	else if(c_debugInt == 4 )
	{
		//finalColor.rgb = EncodeXYZToRGB( surfaceTangentModelSpace );
	}
	else if(c_debugInt == 5 )
	{
		//finalColor.rgb = EncodeXYZToRGB( surfaceBitangentModelSpace );
	}
	else if(c_debugInt == 6 )
	{
		//finalColor.rgb = EncodeXYZToRGB( surfaceNormalModelSpace );
	}
	else if(c_debugInt == 7 )
	{
		//finalColor.rgba = normalTexel.rgba;
	}
	else if(c_debugInt == 8 )
	{
		//finalColor.rgb = EncodeXYZToRGB( pixelNormalTBNSpace );
		finalColor.rgb = totalSpecularLight;
	}
	else if(c_debugInt == 9 )
	{
		//finalColor.rgb = EncodeXYZToRGB( pixelNormalWorldSpace );
		finalColor.rgb = saturate(totalDiffuseLight) + emissiveLight;
	}
	else if(c_debugInt == 10 )
	{
		// Lit, but ignore normal maps (use surface normals only) -- see above
	}
	else if(c_debugInt == 11 || c_debugInt == 12 )
	{
		finalColor.rgb = totalDiffuseLight.xxx;
	}
	else if(c_debugInt == 13 )
	{
		finalColor.rgb = c_sunColor.rgb * c_sunColor.a;
	}
	else if(c_debugInt == 14 )
	{
		finalColor.rgb = EncodeXYZToRGB( surfaceTangentWorldSpace );
	}
	else if(c_debugInt == 15 )
	{
		finalColor.rgb = EncodeXYZToRGB( surfaceBitangentWorldSpace );
	}
	else if(c_debugInt == 16 )
	{
		finalColor.rgb = EncodeXYZToRGB( surfaceNormalWorldSpace );
	}
	else if(c_debugInt == 17 )
	{
		//float3 modelIBasisWorld = mul( c_modelToWorld, float4(1,0,0,0) ).xyz;
		//finalColor.rgb = EncodeXYZToRGB( normalize( modelIBasisWorld.xyz ) );
		finalColor.r = SnapToNearestFractional( finalColor.r, 2 );
		finalColor.g = SnapToNearestFractional( finalColor.g, 2 );
		finalColor.b = SnapToNearestFractional( finalColor.b, 2 );		
	}
	else if(c_debugInt == 18 )
	{
		finalColor.rgb = (totalSpecularLight * specularity);
	}
	else if(c_debugInt == 19 )
	{
		finalColor.rgb = (saturate(totalDiffuseLight) * diffuseColor.rgb) + emissiveLight;
	}
		
	return finalColor;
}

