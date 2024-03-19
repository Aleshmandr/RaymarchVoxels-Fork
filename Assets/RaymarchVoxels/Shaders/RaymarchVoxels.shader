Shader "Universal Render Pipeline/Custom/RaymarchVoxels"
{
    Properties
    {
        [NoScaleOffset] _Voxels("Voxels", 3D) = "white" {}
        [MainColor] _BaseColor("Color", Color) = (1,1,1,1)
        _Smoothness("Smoothness", Range(0.0, 1.0)) = 0.0
        _SpecColor("Specular", Color) = (0.0, 0.0, 0.0)
        [ToggleOff] _SpecularHighlights("Specular Highlights", Float) = 1.0
        [HDR] _EmissionColor("Emission", Color) = (0,0,0)
        _ReceiveShadows("Receive Shadows", Float) = 1.0
        _CastShadows("Cast Shadows", Float) = 1.0
    }

    SubShader
    {
        Tags
        {
            "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline" "IgnoreProjector" = "True"
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
            Cull Front

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

            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Texture.hlsl"
            #include "Assets/RaymarchVoxels/Shaders/RaymarchVoxels.hlsl"

            TEXTURE3D(_Voxels);
            SAMPLER(sampler_Voxels);

            struct Attributes
            {
                float4 positionOS : POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionWSAndFogFactor : TEXCOORD0; // xyz: positionWS, w: vertex fog factor
                float4 positionCS : SV_POSITION;
            };

            Varyings Vert(Attributes input)
            {
                Varyings output;

                // VertexPositionInputs contains position in multiple spaces (world, view, homogeneous clip space)
                // Our compiler will strip all unused references (say you don't use view space).
                // Therefore there is more flexibility at no additional cost with this struct.
                VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);

                // Computes fog factor per-vertex.
                float fogFactor = ComputeFogFactor(vertexInput.positionCS.z);
                output.positionWSAndFogFactor = float4(vertexInput.positionWS, fogFactor);
                // We just use the homogeneous clip position from the vertex input
                output.positionCS = vertexInput.positionCS;
                return output;
            }

            inline void InitializeSurfaceData(out SurfaceData outSurfaceData)
            {
                outSurfaceData.albedo = _BaseColor.rgb;
                outSurfaceData.alpha = _BaseColor.a;
                outSurfaceData.metallic = 1.0;
                outSurfaceData.specular = _SpecColor.rgb;
                outSurfaceData.smoothness = _Smoothness;
                outSurfaceData.normalTS = half3(0.0, 0.0, 0.0);
                outSurfaceData.occlusion = 1.0;

                #ifndef _EMISSION
                outSurfaceData.emission = 0.0;
                #else
                outSurfaceData.emission = _EmissionColor;;
                #endif

                outSurfaceData.clearCoatMask = 0.0;
                outSurfaceData.clearCoatSmoothness = 0.0;
            }

            void CalculateViewRay(float3 worldPos, out float3 rayOriginWorldSpace, out float3 rayDirWorldSpace)
            {
                // Viewer position, equivalent to _WorldSpaceCAmeraPos.xyz, but for the current view
                float3 worldSpaceViewerPos = UNITY_MATRIX_I_V._m03_m13_m23;
                // View forward
                float3 worldSpaceViewForward = -UNITY_MATRIX_I_V._m02_m12_m22;
                // Calculate world space view ray direction and origin for perspective or orthographic
                rayOriginWorldSpace = worldSpaceViewerPos;
                rayDirWorldSpace = worldPos - rayOriginWorldSpace;
                // Check if the current projection is orthographic
                if (UNITY_MATRIX_P._m33 == 1.0)
                {
                    rayDirWorldSpace = worldSpaceViewForward * dot(rayDirWorldSpace, worldSpaceViewForward);
                    rayOriginWorldSpace = worldPos - rayDirWorldSpace;
                }
            }

            float4 GetVoxelShadowCoord(VertexPositionInputs vertexInput)
            {
                #if defined(_MAIN_LIGHT_SHADOWS_SCREEN) && !defined(_SURFACE_TYPE_TRANSPARENT)
                return ComputeScreenPos(vertexInput.positionCS);
                #else
                return TransformWorldToShadowCoord(vertexInput.positionWS);
                #endif
            }

            half4 Frag(Varyings input, out float outDepth : SV_Depth) : SV_Target
            {
                // Surface data contains albedo, metallic, specular, smoothness, occlusion, emission and alpha
                // InitializeStandarLitSurfaceData initializes based on the rules for standard shader.
                // You can write your own function to initialize the surface data of your shader.
                SurfaceData surfaceData;
                InitializeSurfaceData(surfaceData);

                float3 positionWS = input.positionWSAndFogFactor.xyz;
                float3 worldSpaceViewerPos = UNITY_MATRIX_I_V._m03_m13_m23;

                float3 rayDirWorldSpace;
                float3 rayOriginWorldSpace;
                CalculateViewRay(positionWS, rayOriginWorldSpace, rayDirWorldSpace);

                float3 rayDirObjectSpace = TransformWorldToObjectDir(rayDirWorldSpace);
                float3 rayOriginObjectSpace = TransformWorldToObject(rayOriginWorldSpace);

                UnityTexture3D voxels = UnityBuildTexture3DStruct(_Voxels);
                float4 voxelColor;
                float3 voxelNormal;
                float3 voxelPosition;

                RaymarchVoxels(
                    rayOriginObjectSpace,
                    rayDirObjectSpace,
                    voxels,
                    voxelColor,
                    voxelNormal,
                    voxelPosition,
                    outDepth);

                surfaceData.albedo *= voxelColor.rgb;
                surfaceData.emission *= voxelColor.rgb;

                half3 voxelNormalWS = TransformObjectToWorldNormal(voxelNormal);
                voxelNormalWS = normalize(voxelNormalWS);

                // Samples SH fully per-pixel. SampleSHVertex and SampleSHPixel functions
                // are also defined in case you want to sample some terms per-vertex.
                half3 bakedGI = SampleSH(voxelNormalWS);

                //half3 viewDirectionWS = SafeNormalize(GetCameraPositionWS() - positionWS);

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
                float3 voxelPositionWs = TransformObjectToWorld(voxelPosition);

                #ifdef _RECEIVE_SHADOWS

                #if defined(_MAIN_LIGHT_SHADOWS_SCREEN)
                float4 shadowCoord = ComputeScreenPos(TransformObjectToHClip(voxelPosition));
                #else
                float3 biasedSC = ApplyShadowBias(voxelPositionWs, -voxelNormalWS, -_MainLightPosition.xyz);
                float4 shadowCoord = TransformWorldToShadowCoord(biasedSC);
                #endif

                Light mainLight = GetMainLight(shadowCoord);
                #else
                Light mainLight = GetMainLight();
                #endif

                half3 viewDirectionWS = SafeNormalize(worldSpaceViewerPos - voxelPositionWs);

                // Mix diffuse GI with environment reflections.
                half3 color = GlobalIllumination(brdfData, bakedGI, surfaceData.occlusion, voxelNormalWS,
                                                 viewDirectionWS);

                // LightingPhysicallyBased computes direct light contribution.
                color += LightingPhysicallyBased(brdfData, mainLight, voxelNormalWS, viewDirectionWS);

                #ifdef _ADDITIONAL_LIGHTS
                int additionalLightsCount = GetAdditionalLightsCount();
                for (int i = 0; i < additionalLightsCount; ++i)
                {
                    Light light = GetAdditionalLight(i, voxelPositionWs);
                    color += LightingPhysicallyBased(brdfData, light, voxelNormalWS, viewDirectionWS);
                }
                #endif

                color += surfaceData.emission;
                color = MixFog(color, input.positionWSAndFogFactor.w);
                return half4(color, surfaceData.alpha);
            }
            ENDHLSL
        }

        Pass
        {
            Name "ShadowCaster"
            Tags
            {
                "LightMode" = "ShadowCaster"
            }

            ZWrite On
            ZTest LEqual
            Cull Off

            ColorMask 0

            HLSLPROGRAM
            #pragma shader_feature _SMOOTHNESS_TEXTURE_ALBEDO_CHANNEL_A
            #pragma multi_compile_instancing

            #pragma prefer_hlslcc gles
            #pragma exclude_renderers d3d11_9x
            #pragma target 2.0

            #pragma vertex Vert
            #pragma fragment Frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/Shaders/LitInput.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Texture.hlsl"
            #include "Assets/RaymarchVoxels/Shaders/RaymarchVoxels.hlsl"

            TEXTURE3D(_Voxels);
            SAMPLER(sampler_Voxels);

            struct Attributes
            {
                float4 positionOS : POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float3 positionWS : TEXCOORD0;
                float4 positionCS : SV_POSITION;
            };

            Varyings Vert(Attributes input)
            {
                Varyings output;
                output.positionWS = TransformObjectToWorld(input.positionOS);
                output.positionCS = TransformWorldToHClip(output.positionWS);

                // https://catlikecoding.com/unity/tutorials/custom-srp/directional-shadows/
                #if UNITY_REVERSED_Z
                output.positionCS.z = min(output.positionCS.z, output.positionCS.w * UNITY_NEAR_CLIP_VALUE);
                #else
		        output.positionCS.z = max(output.positionCS.z, output.positionCS.w * UNITY_NEAR_CLIP_VALUE);
                #endif

                return output;
            }

            float Frag(Varyings input) : SV_Depth
            {
                float3 rayDirWorldSpace = -UNITY_MATRIX_I_V._m02_m12_m22;
                float3 rayOriginWorldSpace = input.positionWS - rayDirWorldSpace;

                float3 rayOriginObjectSpace = TransformWorldToObject(rayOriginWorldSpace);
                float3 rayDirObjectSpace = TransformWorldToObjectDir(rayDirWorldSpace);

                UnityTexture3D voxels = UnityBuildTexture3DStruct(_Voxels);
                float4 voxelColor;
                float3 voxelNormal;
                float3 voxelPosition;
                float voxelDepth;

                RaymarchVoxels(
                    rayOriginObjectSpace,
                    rayDirObjectSpace,
                    voxels,
                    voxelColor,
                    voxelNormal,
                    voxelPosition,
                    voxelDepth);


                return voxelDepth;
            }
            ENDHLSL
        }

        Pass
        {
            Name "DepthNormals"
            Tags
            {
                "LightMode" = "DepthNormals"
            }

            ZWrite On
            ZTest LEqual
            Cull Off

            ColorMask 0

            HLSLPROGRAM
            #pragma shader_feature _SMOOTHNESS_TEXTURE_ALBEDO_CHANNEL_A
            #pragma multi_compile_instancing

            #pragma prefer_hlslcc gles
            #pragma exclude_renderers d3d11_9x
            #pragma target 2.0

            #pragma vertex Vert
            #pragma fragment Frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/Shaders/LitInput.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Texture.hlsl"
            #include "Assets/RaymarchVoxels/Shaders/RaymarchVoxels.hlsl"

            TEXTURE3D(_Voxels);
            SAMPLER(sampler_Voxels);

            struct Attributes
            {
                float4 positionOS : POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float3 positionWS : TEXCOORD0;
                float4 positionCS : SV_POSITION;
            };

            struct FragOutput
            {
                float4 normal : SV_Target;
                float depth : SV_Depth;
            };

            Varyings Vert(Attributes input)
            {
                Varyings output;
                output.positionWS = TransformObjectToWorld(input.positionOS);
                output.positionCS = TransformWorldToHClip(output.positionWS);

                // https://catlikecoding.com/unity/tutorials/custom-srp/directional-shadows/
                #if UNITY_REVERSED_Z
                output.positionCS.z = min(output.positionCS.z, output.positionCS.w * UNITY_NEAR_CLIP_VALUE);
                #else
		        output.positionCS.z = max(output.positionCS.z, output.positionCS.w * UNITY_NEAR_CLIP_VALUE);
                #endif

                return output;
            }

            void CalculateViewRay(float3 worldPos, out float3 rayOriginWorldSpace, out float3 rayDirWorldSpace)
            {
                // Viewer position, equivalent to _WorldSpaceCAmeraPos.xyz, but for the current view
                float3 worldSpaceViewerPos = UNITY_MATRIX_I_V._m03_m13_m23;
                // View forward
                float3 worldSpaceViewForward = -UNITY_MATRIX_I_V._m02_m12_m22;
                // Calculate world space view ray direction and origin for perspective or orthographic
                rayOriginWorldSpace = worldSpaceViewerPos;
                rayDirWorldSpace = worldPos - rayOriginWorldSpace;
                // Check if the current projection is orthographic
                if (UNITY_MATRIX_P._m33 == 1.0)
                {
                    rayDirWorldSpace = worldSpaceViewForward * dot(rayDirWorldSpace, worldSpaceViewForward);
                    rayOriginWorldSpace = worldPos - rayDirWorldSpace;
                }
            }

            FragOutput Frag(Varyings input)
            {
                 float3 positionWS = input.positionWS;

                float3 rayDirWorldSpace;
                float3 rayOriginWorldSpace;
                CalculateViewRay(positionWS, rayOriginWorldSpace, rayDirWorldSpace);
                
                float3 rayOriginObjectSpace = TransformWorldToObject(rayOriginWorldSpace);
                float3 rayDirObjectSpace = TransformWorldToObjectDir(rayDirWorldSpace);

                UnityTexture3D voxels = UnityBuildTexture3DStruct(_Voxels);
                float4 voxelColor;
                float3 voxelNormal;
                float3 voxelPosition;
                float voxelDepth;

                RaymarchVoxels(
                    rayOriginObjectSpace,
                    rayDirObjectSpace,
                    voxels,
                    voxelColor,
                    voxelNormal,
                    voxelPosition,
                    voxelDepth);

                half3 voxelNormalWS = TransformObjectToWorldNormal(voxelNormal);
                voxelNormalWS = normalize(voxelNormalWS);
                
                FragOutput o;
                o.normal = float4(voxelNormalWS, 0.0);
                o.depth = voxelDepth;

                return o;
            }
            ENDHLSL
        }
    }

    CustomEditor "RaymarchVoxels.RaymarchVoxelsShaderEditor"
}