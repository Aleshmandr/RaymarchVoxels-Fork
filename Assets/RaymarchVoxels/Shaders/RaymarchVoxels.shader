Shader "Universal Render Pipeline/Custom/RaymarchVoxels"
{
    Properties
    {
        [MainColor] _BaseColor("Color", Color) = (1,1,1,1)
        _Smoothness("Smoothness", Range(0.0, 1.0)) = 0.5
        [Gamma] _Metallic("Metallic", Range(0.0, 1.0)) = 0.0
        _SpecColor("Specular", Color) = (0.2, 0.2, 0.2)
        [ToggleOff] _SpecularHighlights("Specular Highlights", Float) = 1.0
        [HDR] _EmissionColor("Emission", Color) = (0,0,0)
        _ReceiveShadows("Receive Shadows", Float) = 1.0
        _CastShadows("Cast Shadows", Float) = 1.0
    }

    SubShader
    {
        Tags
        {
            "RenderType" = "Opaque" "RenderPipeline" = "UniversalRenderPipeline" "IgnoreProjector" = "True"
        }
        LOD 300

        Pass
        {
            Name "StandardLit"
            Tags
            {
                "LightMode" = "UniversalForward"
            }

            ZWrite On
            Cull Back

            HLSLPROGRAM
            // Required to compile gles 2.0 with standard SRP library
            // All shaders must be compiled with HLSLcc and currently only gles is not using HLSLcc by default
            #pragma prefer_hlslcc gles
            #pragma exclude_renderers d3d11_9x
            #pragma target 2.0

            #pragma multi_compile _SPECULAR_SETUP
            // -------------------------------------
            // Material Keywords
            // unused shader_feature variants are stripped from build automatically
            #pragma shader_feature _EMISSION
            #pragma shader_feature _OCCLUSIONMAP
            #pragma shader_feature _RECEIVE_SHADOWS

            // -------------------------------------
            // Universal Render Pipeline keywords
            // When doing custom shaders you most often want to copy and past these #pragmas
            // These multi_compile variants are stripped from the build depending on:
            // 1) Settings in the LWRP Asset assigned in the GraphicsSettings at build time
            // e.g If you disable AdditionalLights in the asset then all _ADDITIONA_LIGHTS variants
            // will be stripped from build
            // 2) Invalid combinations are stripped. e.g variants with _MAIN_LIGHT_SHADOWS_CASCADE
            // but not _MAIN_LIGHT_SHADOWS are invalid and therefore stripped.
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS
            #pragma multi_compile _ _ADDITIONAL_LIGHT_SHADOWS
            #pragma multi_compile _ _SHADOWS_SOFT
            #pragma multi_compile _ _MIXED_LIGHTING_SUBTRACTIVE

            // -------------------------------------
            // Unity defined keywords
            #pragma multi_compile _ DIRLIGHTMAP_COMBINED
            #pragma multi_compile _ LIGHTMAP_ON
            #pragma multi_compile_fog

            //--------------------------------------
            // GPU Instancing
            #pragma multi_compile_instancing

            #pragma vertex Vert
            #pragma fragment Frag

            // Including the following two function is enought for shading with Universal Pipeline. Everything is included in them.
            // Core.hlsl will include SRP shader library, all constant buffers not related to materials (perobject, percamera, perframe).
            // It also includes matrix/space conversion functions and fog.
            // Lighting.hlsl will include the light functions/data to abstract light constants. You should use GetMainLight and GetLight functions
            // that initialize Light struct. Lighting.hlsl also include GI, Light BDRF functions. It also includes Shadows.

            // Required by all Universal Render Pipeline shaders.
            // It will include Unity built-in shader variables (except the lighting variables)
            // (https://docs.unity3d.com/Manual/SL-UnityShaderVariables.html
            // It will also include many utilitary functions. 
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            // Include this if you are doing a lit shader. This includes lighting shader variables,
            // lighting and shadow functions
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            // Material shader variables are not defined in SRP or LWRP shader library.
            // This means _BaseColor, _BaseMap, _BaseMap_ST, and all variables in the Properties section of a shader
            // must be defined by the shader itself. If you define all those properties in CBUFFER named
            // UnityPerMaterial, SRP can cache the material properties between frames and reduce significantly the cost
            // of each drawcall.
            // In this case, for sinmplicity LitInput.hlsl is included. This contains the CBUFFER for the material
            // properties defined above. As one can see this is not part of the ShaderLibrary, it specific to the
            // LWRP Lit shader.
            #include "Packages/com.unity.render-pipelines.universal/Shaders/LitInput.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
                float4 tangentOS : TANGENT;
                float2 uv : TEXCOORD0;
                float2 uvLM : TEXCOORD1;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float2 uv : TEXCOORD0;
                float2 uvLM : TEXCOORD1;
                float4 positionWSAndFogFactor : TEXCOORD2; // xyz: positionWS, w: vertex fog factor
                half3 normalWS : TEXCOORD3;

                #ifdef _RECEIVE_SHADOWS
                float4 shadowCoord : TEXCOORD6; // compute shadow coord per-vertex for the main light
                #endif
                float4 positionCS : SV_POSITION;
            };

            Varyings Vert(Attributes input)
            {
                Varyings output;

                // VertexPositionInputs contains position in multiple spaces (world, view, homogeneous clip space)
                // Our compiler will strip all unused references (say you don't use view space).
                // Therefore there is more flexibility at no additional cost with this struct.
                VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);

                // Similar to VertexPositionInputs, VertexNormalInputs will contain normal, tangent and bitangent
                // in world space. If not used it will be stripped.
                VertexNormalInputs vertexNormalInput = GetVertexNormalInputs(input.normalOS, input.tangentOS);

                // Computes fog factor per-vertex.
                float fogFactor = ComputeFogFactor(vertexInput.positionCS.z);

                // TRANSFORM_TEX is the same as the old shader library.
                output.uv = TRANSFORM_TEX(input.uv, _BaseMap);
                output.uvLM = input.uvLM.xy * unity_LightmapST.xy + unity_LightmapST.zw;

                output.positionWSAndFogFactor = float4(vertexInput.positionWS, fogFactor);
                output.normalWS = vertexNormalInput.normalWS;

                #ifdef _RECEIVE_SHADOWS
                // shadow coord for the main light is computed in vertex.
                // If cascades are enabled, LWRP will resolve shadows in screen space
                // and this coord will be the uv coord of the screen space shadow texture.
                // Otherwise LWRP will resolve shadows in light space (no depth pre-pass and shadow collect pass)
                // In this case shadowCoord will be the position in light space.
                output.shadowCoord = GetShadowCoord(vertexInput);
                #endif
                // We just use the homogeneous clip position from the vertex input
                output.positionCS = vertexInput.positionCS;
                return output;
            }

            inline void InitializeSurfaceData(float2 uv, out SurfaceData outSurfaceData)
            {
                outSurfaceData.alpha = _BaseColor.a;
                half4 specGloss = half4(_SpecColor.rgb, _Smoothness);
                
                outSurfaceData.albedo = _BaseColor.rgb;
                outSurfaceData.albedo = AlphaModulate(outSurfaceData.albedo, outSurfaceData.alpha);

                outSurfaceData.metallic = half(1.0);
                outSurfaceData.specular = _SpecColor.rgb;

                outSurfaceData.smoothness = _Smoothness;
                outSurfaceData.normalTS = half3(0.0, 0.0, 0.0);
                outSurfaceData.occlusion = 1.0;

                #ifndef _EMISSION
                    outSurfaceData.emission = 0.0;
                #else
                    outSurfaceData.emission = _EmissionColor;;
                #endif
                
                outSurfaceData.clearCoatMask = half(0.0);
                outSurfaceData.clearCoatSmoothness = half(0.0);
            }

            half4 Frag(Varyings input) : SV_Target
            {
                // Surface data contains albedo, metallic, specular, smoothness, occlusion, emission and alpha
                // InitializeStandarLitSurfaceData initializes based on the rules for standard shader.
                // You can write your own function to initialize the surface data of your shader.
                SurfaceData surfaceData;
                InitializeSurfaceData(input.uv, surfaceData);

                half3 normalWS = input.normalWS;
                normalWS = normalize(normalWS);

                // Samples SH fully per-pixel. SampleSHVertex and SampleSHPixel functions
                // are also defined in case you want to sample some terms per-vertex.
                half3 bakedGI = SampleSH(normalWS);

                float3 positionWS = input.positionWSAndFogFactor.xyz;
                half3 viewDirectionWS = SafeNormalize(GetCameraPositionWS() - positionWS);

                // BRDFData holds energy conserving diffuse and specular material reflections and its roughness.
                // It's easy to plugin your own shading fuction. You just need replace LightingPhysicallyBased function
                // below with your own.
                BRDFData brdfData;
                InitializeBRDFData(surfaceData.albedo, surfaceData.metallic, surfaceData.specular,
                                   surfaceData.smoothness, surfaceData.alpha, brdfData);

                // Light struct is provide by LWRP to abstract light shader variables.
                // It contains light direction, color, distanceAttenuation and shadowAttenuation.
                // LWRP take different shading approaches depending on light and platform.
                // You should never reference light shader variables in your shader, instead use the GetLight
                // funcitons to fill this Light struct.
                // Main light is the brightest directional light.
                // It is shaded outside the light loop and it has a specific set of variables and shading path
                // so we can be as fast as possible in the case when there's only a single directional light
                // You can pass optionally a shadowCoord (computed per-vertex). If so, shadowAttenuation will be
                // computed.
                #ifdef _RECEIVE_SHADOWS
                Light mainLight = GetMainLight(input.shadowCoord);
                #else
                Light mainLight = GetMainLight();
                #endif

                // Mix diffuse GI with environment reflections.
                half3 color = GlobalIllumination(brdfData, bakedGI, surfaceData.occlusion, normalWS, viewDirectionWS);

                // LightingPhysicallyBased computes direct light contribution.
                color += LightingPhysicallyBased(brdfData, mainLight, normalWS, viewDirectionWS);

                #ifdef _ADDITIONAL_LIGHTS

                int additionalLightsCount = GetAdditionalLightsCount();
                for (int i = 0; i < additionalLightsCount; ++i)
                {
                    Light light = GetAdditionalLight(i, positionWS);
                    color += LightingPhysicallyBased(brdfData, light, normalWS, viewDirectionWS);
                }
                #endif

                color += surfaceData.emission;
                color = MixFog(color, input.positionWSAndFogFactor.w);
                return half4(color, surfaceData.alpha);
            }
            ENDHLSL
        }

        // Used for rendering shadowmaps
        UsePass "Universal Render Pipeline/Lit/ShadowCaster"

        // Used for depth prepass
        // If shadows cascade are enabled we need to perform a depth prepass. 
        // We also need to use a depth prepass in some cases camera require depth texture
        // (e.g, MSAA is enabled and we can't resolve with Texture2DMS
        UsePass "Universal Render Pipeline/Lit/DepthOnly"
    }

    CustomEditor "RaymarchVoxels.RaymarchVoxelsShaderEditor"
}