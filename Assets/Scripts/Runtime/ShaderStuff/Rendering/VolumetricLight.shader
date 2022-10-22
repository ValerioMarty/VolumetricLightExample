Shader "Hidden/VolumetricLight"
{
    Properties
    {
        //we need to have _MainTex written exactly like this because unity will pass the source render texture into _MainTex automatically 
        _MainTex ("Texture", 2D) = "white" {}

    }
    SubShader
    {
        // No culling or depth
        Cull Off ZWrite Off ZTest Always

        Pass
        {
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_local __ _COLORED_ON
            #pragma multi_compile __ _USE_WRONG_DEPTH_ON
            #pragma multi_compile _  _MAIN_LIGHT_SHADOWS_CASCADE
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            //Boilerplate code, we aren't doind anything with our vertices or any other input info,
            // because technically we are working on a quad taking up the whole screen

            real4x4 _ClipToWorld;

            struct appdata {
                real4 vertex : POSITION;
                real2 uv : TEXCOORD0;
            };

            struct v2f {
                real2 uv : TEXCOORD0;
                real4 vertex : SV_POSITION;
            };

            v2f vert(appdata v)
            {
                v2f o;
                o.vertex = TransformWorldToHClip(v.vertex);
                o.uv = v.uv;
                return o;
            }


            sampler2D _MainTex;
            //regular raymarching variables           
            real _Scattering;
            real3 _SunDirection;
            const real _Steps;
            real _JitterVolumetric;
            real _MaxDistance;
            //Color raymarching variables     
            TEXTURE2D(_CameraDepth2Texture);
            SAMPLER(sampler_CameraDepth2Texture);
            real _DepthSteps = 8;
            real _DepthMaxDistance = 18;
            real _Boost = 4;
            real _ColorJitterMultiplier = 2;

            //This function will tell us if a certain point in world space coordinates is in light or shadow of the main light
            real ShadowAtten(real3 worldPosition)
            {
                return MainLightRealtimeShadow(TransformWorldToShadowCoord(worldPosition));
            }

            //Unity already has a function that can reconstruct world space position from depth
            real3 GetWorldPos(real2 uv)
            {
                #if UNITY_REVERSED_Z
                real depth = SampleSceneDepth(uv);
                #else
                    // Adjust z to match NDC for OpenGL
                    real depth = lerp(UNITY_NEAR_CLIP_VALUE, 1, SampleSceneDepth(uv));
                #endif
                return ComputeWorldSpacePosition(uv, depth, UNITY_MATRIX_I_VP);
            }


            // Mie scaterring approximated with Henyey-Greenstein phase function.
            real ComputeScattering(real lightDotView)
            {
                real result = 1.0f - _Scattering * _Scattering;
                result /= (4.0f * PI * pow(1.0f + _Scattering * _Scattering - (2.0f * _Scattering) * lightDotView, 1.5f));
                return result;
            }

            //standard hash
            real random(real2 p)
            {
                return frac(sin(dot(p, real2(41, 289))) * 45758.5453) - 0.5;
            }
            real random01(real2 p)
            {
                return frac(sin(dot(p, real2(41, 289))) * 45758.5453);
            }

            //from Ronja https://www.ronja-tutorials.com/post/047-invlerp_remap/
            real invLerp(real from, real to, real value)
            {
                return (value - from) / (to - from);
            }

            real remap(real origFrom, real origTo, real targetFrom, real targetTo, real value)
            {
                real rel = invLerp(origFrom, origTo, value);
                return lerp(targetFrom, targetTo, rel);
            }

            //There is probably a simpler way to do this
            //get Screen Position from a world space coordinate
            real2 WorldToScreenPos(real3 pos)
            {
                pos = (pos - _WorldSpaceCameraPos) * (_ProjectionParams.y + (_ProjectionParams.z - _ProjectionParams.y)) + _WorldSpaceCameraPos;
                real2 uv = 0;
                real3 toCam = mul(unity_WorldToCamera, pos);
                real camPosZ = toCam.z;
                real height = 2 * camPosZ / unity_CameraProjection._m11;
                real width = _ScreenParams.x / _ScreenParams.y * height;
                uv.x = (toCam.x + width / 2) / width;
                uv.y = (toCam.y + height / 2) / height;
                return uv;
            }

            //we need to not use mipmaps so it works even if loops arent unrolled
            real GetDepthLevel0(real2 uv)
            {
                return _CameraDepthTexture.SampleLevel(sampler_CameraDepthTexture, uv, 0);
            }
            //we need to not use mipmaps so it works even if loops arent unrolled
            real3 GetWorldPosLoop(real2 uv)
            {
                #if UNITY_REVERSED_Z
                real depth = GetDepthLevel0(uv);
                #else
                    real depth = GetDepthLevel0( uv);
                    // Adjust z to match NDC for OpenGL
                    depth = lerp(UNITY_NEAR_CLIP_VALUE, 1, depth);
                #endif
                return ComputeWorldSpacePosition(uv, depth, UNITY_MATRIX_I_VP);
            }

            //we need to not use mipmaps so it works even if loops arent unrolled
            real GetEyeDepth(real2 uv)
            {
                #if UNITY_REVERSED_Z
                real depth = GetDepthLevel0(uv);

                #else
                    real depth = GetDepthLevel0( uv);
                    // Adjust z to match NDC for OpenGL
                    depth = lerp(UNITY_NEAR_CLIP_VALUE, 1, depth);
                #endif
                return LinearEyeDepth(depth, _ZBufferParams);
            }


            //this implementation is loosely based on http://www.alexandre-pestana.com/volumetric-lights/ and https://fr.slideshare.net/BenjaminGlatzel/volumetric-lighting-for-many-lights-in-lords-of-the-fallen

            #define MIN_STEPS 25

            #ifdef _COLORED_ON
                #define REAL real3
            #else
                #define REAL real
            #endif


            REAL frag(v2f i) : SV_Target
            {
                real3 worldPos = GetWorldPos(i.uv);


                real3 startPosition = _WorldSpaceCameraPos;
                real3 rayVector = worldPos - startPosition;
                real3 rayDirection = normalize(rayVector);
                real rayLength = length(rayVector);

                if (rayLength > _MaxDistance)
                {
                    rayLength = _MaxDistance;
                    worldPos = startPosition + rayDirection * rayLength;
                }

                //We can limit the amount of steps for close objects
                // steps= remap(0,_MaxDistance,MIN_STEPS,_Steps,rayLength);  

                // steps= remap(0,_MaxDistance,0,_Steps,rayLength);   
                // steps = max(steps,MIN_STEPS);

                real stepLength = rayLength / _Steps;


                //to eliminate banding we sample at diffent depths for every ray, this way we obfuscate the shadowmap patterns
                real rayStartOffset = random01(i.uv) * stepLength * _JitterVolumetric / 100;
                real3 step = rayDirection * stepLength ;
                real3 currentPosition = startPosition + rayStartOffset * rayDirection;

                startPosition = currentPosition;

                REAL accumFog = 0;

                //everything that can be calculated outside the loop
                #ifdef _COLORED_ON
                    real3 depthRayDirection = -_SunDirection;
                    real depthStepLength = _DepthMaxDistance/_DepthSteps;
                    real3 depthStep= depthRayDirection*depthStepLength;
                #endif
                //we ask for the shadow map value at different depths, if the sample is in light we compute the contribution at that point and add it
                for (real j = 0; j < _Steps - 1; j++)
                {
                    real shadowMapValue = ShadowAtten(currentPosition);

                    //if it is in light
                    [branch]
                    if (shadowMapValue > 0)
                    {
                        #ifdef _COLORED_ON
                            REAL kernelColor = ComputeScattering(dot(rayDirection, _SunDirection)).xxxx ;

                            real3 depthRayPosition= currentPosition;
                            depthRayPosition+=rayStartOffset*_ColorJitterMultiplier*depthRayDirection;

                            for(real z=0;z<_DepthSteps;z++){

                                real distanceToDepthRay = length( depthRayPosition-_WorldSpaceCameraPos);
                                real2 uvDepthPos = WorldToScreenPos(depthRayPosition);
                                
                                [branch]
                                if(abs (uvDepthPos.x)>1 || abs(uvDepthPos.y)>1){
                                    break;
                                }
                                
                                real depthInUV = _CameraDepth2Texture.SampleLevel(sampler_CameraDepth2Texture,uvDepthPos,0)*_ProjectionParams.z;

                                #ifdef _USE_WRONG_DEPTH_ON
                                    depthInUV = lerp( GetEyeDepth((uvDepthPos)),depthInUV, saturate(depthInUV*100) );  
                                    
                                #endif
                                
                                if(distanceToDepthRay>depthInUV){
                                    REAL color =   (tex2Dlod(_MainTex,float4(uvDepthPos,0,0)))*2*_Boost;
                                    kernelColor= kernelColor.x*color;
                                    break;
                                }

                                depthRayPosition+=depthStep;
                            }
                        #else
                        REAL kernelColor = ComputeScattering(dot(rayDirection, _SunDirection));
                        #endif
                        kernelColor = saturate(kernelColor);
                        accumFog += kernelColor;
                        // break;
                    }
                    currentPosition += step;
                }
                //we need the average value, so we divide between the amount of samples 
                accumFog /= _Steps;

                return accumFog;
            }
            ENDHLSL
        }

        Pass
        {
            Name "Gaussian Blur"

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_local __ _COLORED_ON
            #pragma multi_Compile_local _ _Vertical
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"


            struct appdata {
                real4 vertex : POSITION;
                real2 uv : TEXCOORD0;
            };

            struct v2f {
                real2 uv : TEXCOORD0;
                real4 vertex : SV_POSITION;
            };

            v2f vert(appdata v)
            {
                v2f o;
                o.vertex = TransformWorldToHClip(v.vertex);
                o.uv = v.uv;
                return o;
            }
            TEXTURE2D(_MainTex);
            SAMPLER(sampler_MainTex);
            // sampler2D _MainTex;
            int _GaussSamples;
            real _GaussAmount;
            static const real gauss_filter_weights[] = {0.14446445, 0.13543542, 0.11153505, 0.08055309, 0.05087564, 0.02798160, 0.01332457, 0.00545096, 0, 0, 0, 0, 0, 0, 0, 0, 0};


            #define BLUR_DEPTH_FALLOFF 100.0


            #define BILATERAL_BLUR


            #ifdef _COLORED_ON
                #define REAL real3
            #else
                #define REAL real
            #endif


            REAL frag(v2f i) : SV_Target
            {
                REAL col = 0;
                REAL accumResult = 0;
                real accumWeights = 0;

              
                const int2 _Axis = int2(1, 0);
            
                #if UNITY_REVERSED_Z
                real depthCenter = SampleSceneDepth(i.uv);
                #else
                   real depthCenter = lerp(UNITY_NEAR_CLIP_VALUE, 1, SampleSceneDepth(i.uv));
                #endif
                
                const int number = 5;
                UNITY_FLATTEN
                for (real index = -number; index <= number; index++)
                {
                    //we offset our uvs by a tiny amount 
                    // real2 uv = i.uv + _Axis * (index * _GaussAmount / 1000.);

                    //sample the color at that location
                    // REAL kernelSample = tex2Dlod(_MainTex, uv,);

                    REAL kernelSample = _MainTex.SampleLevel(sampler_MainTex, i.uv, 0, _Axis * index);
                    //depth at the sampled pixel
                    #ifdef BILATERAL_BLUR
                        real depthKernel;
                        #if UNITY_REVERSED_Z
                          depthKernel =_CameraDepthTexture.SampleLevel(sampler_MainTex, i.uv, 0, _Axis * index);
                        #else
                            depthKernel = lerp(UNITY_NEAR_CLIP_VALUE, 1, _CameraDepthTexture.SampleLevel(sampler_MainTex, i.uv, 0, _Axis * index));
                        #endif
                        //weight calculation depending on distance and depth difference
                        real depthDiff = abs(depthKernel - depthCenter);
                        real r2 = depthDiff * BLUR_DEPTH_FALLOFF;
                        real g = exp(-r2 * r2);
                        real weight = g * gauss_filter_weights[abs(index)];
                        //sum for every iteration of the color and weight of this sample 
                        accumResult += weight * kernelSample;
                       
                    #else

                    // real weight = gauss_filter_weights[abs(index)];
                    real weight = 1;
                    accumResult += kernelSample * weight;

                    #endif

                    accumWeights += weight;
                }
                //final color
                col = accumResult / accumWeights;

                return col;
            }
            ENDHLSL
        }

  Pass
        {
            Name "Gaussian Blur 2"

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_local __ _COLORED_ON
            #pragma multi_Compile_local _ _Vertical
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"


            struct appdata {
                real4 vertex : POSITION;
                real2 uv : TEXCOORD0;
            };

            struct v2f {
                real2 uv : TEXCOORD0;
                real4 vertex : SV_POSITION;
            };

            v2f vert(appdata v)
            {
                v2f o;
                o.vertex = TransformWorldToHClip(v.vertex);
                o.uv = v.uv;
                return o;
            }
            TEXTURE2D(_MainTex);
            SAMPLER(sampler_MainTex);
            // sampler2D _MainTex;
            int _GaussSamples;
            real _GaussAmount;
            static const real gauss_filter_weights[] = {0.14446445, 0.13543542, 0.11153505, 0.08055309, 0.05087564, 0.02798160, 0.01332457, 0.00545096, 0, 0, 0, 0, 0, 0, 0, 0, 0};


            #define BLUR_DEPTH_FALLOFF 100.0


            #define BILATERAL_BLUR


            #ifdef _COLORED_ON
                #define REAL real3
            #else
                #define REAL real
            #endif


            REAL frag(v2f i) : SV_Target
            {
                REAL col = 0;
                REAL accumResult = 0;
                real accumWeights = 0;

             
                  const int2 _Axis = int2(0,1);
             

                #if UNITY_REVERSED_Z
                real depthCenter = SampleSceneDepth(i.uv);
                #else
                   real depthCenter = lerp(UNITY_NEAR_CLIP_VALUE, 1, SampleSceneDepth(i.uv));
                #endif
                
                const int number = 5;
                UNITY_FLATTEN
                for (real index = -number; index <= number; index++)
                {
                    //we offset our uvs by a tiny amount 
                    // real2 uv = i.uv + _Axis * (index * _GaussAmount / 1000.);

                    //sample the color at that location
                    // REAL kernelSample = tex2Dlod(_MainTex, uv,);

                    REAL kernelSample = _MainTex.SampleLevel(sampler_MainTex, i.uv, 0, _Axis * index);
                    //depth at the sampled pixel
                    #ifdef BILATERAL_BLUR
                        real depthKernel;
                        #if UNITY_REVERSED_Z
                          depthKernel =_CameraDepthTexture.SampleLevel(sampler_MainTex, i.uv, 0, _Axis * index);
                        #else
                            depthKernel = lerp(UNITY_NEAR_CLIP_VALUE, 1, _CameraDepthTexture.SampleLevel(sampler_MainTex, i.uv, 0, _Axis * index));
                        #endif
                        //weight calculation depending on distance and depth difference
                        real depthDiff = abs(depthKernel - depthCenter);
                        real r2 = depthDiff * BLUR_DEPTH_FALLOFF;
                        real g = exp(-r2 * r2);
                        real weight = g * gauss_filter_weights[abs(index)];
                        //sum for every iteration of the color and weight of this sample 
                        accumResult += weight * kernelSample;
                       
                    #else

                    real weight = gauss_filter_weights[abs(index)];
                    // real weight = 1;
                    accumResult += kernelSample * weight;

                    #endif

                    accumWeights += weight;
                }
                //final color
                col = accumResult / accumWeights;

                return col;
            }
            ENDHLSL
        }


        Pass
        {
            Name "Compositing"

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_local __ _COLORED_ON
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

            struct appdata {
                real4 vertex : POSITION;
                real2 uv : TEXCOORD0;
            };

            struct v2f {
                real2 uv : TEXCOORD0;
                real4 vertex : SV_POSITION;
            };

            v2f vert(appdata v)
            {
                v2f o;
                o.vertex = TransformWorldToHClip(v.vertex);
                o.uv = v.uv;
                return o;
            }
            sampler2D _MainTex;
            TEXTURE2D(_volumetricTexture);
            SAMPLER(sampler_volumetricTexture);
            TEXTURE2D(_LowResDepth);
            SAMPLER(sampler_LowResDepth);
            real4 _SunMoonColor;
            real _Intensity;
            real _Downsample;



            #ifdef _COLORED_ON
                #define REAL real3
            #else
                #define REAL real
            #endif

            real3 frag(v2f i) : SV_Target
            {
             
                REAL col = 1;
                //based on https://eleni.mutantstargoat.com/hikiko/on-depth-aware-upsampling/ 
  
                int offset = 0;
                real d0 = SampleSceneDepth(i.uv);

                /* calculating the distances between the depths of the pixels
                * in the lowres neighborhood and the full res depth value
                * (texture offset must be compile time constant and so we
                * can't use a loop)
                */
                real d1 = _LowResDepth.Sample(sampler_LowResDepth, i.uv, int2(0, 1)).x;
                real d2 = _LowResDepth.Sample(sampler_LowResDepth, i.uv, int2(0, -1)).x;
                real d3 = _LowResDepth.Sample(sampler_LowResDepth, i.uv, int2(1, 0)).x;
                real d4 = _LowResDepth.Sample(sampler_LowResDepth, i.uv, int2(-1, 0)).x;

                d1 = abs(d0 - d1);
                d2 = abs(d0 - d2);
                d3 = abs(d0 - d3);
                d4 = abs(d0 - d4);

                real dmin =min(min(d1, d2), min(d3, d4));

                if (dmin == d1)
                    offset = 0;

                else if (dmin == d2)
                    offset = 1;

                else if (dmin == d3)
                    offset = 2;

                else if (dmin == d4)
                    offset = 3;

                switch (offset)
                {
                    case 0:
                        col = _volumetricTexture.Sample(sampler_volumetricTexture, i.uv, int2(0, 1));
                        break;
                    case 1:
                        col = _volumetricTexture.Sample(sampler_volumetricTexture, i.uv, int2(0, -1));
                        break;
                    case 2:
                        col = _volumetricTexture.Sample(sampler_volumetricTexture, i.uv, int2(1, 0));
                        break;
                    case 3:
                        col = _volumetricTexture.Sample(sampler_volumetricTexture, i.uv, int2(-1, 0));
                        break;
                    default: 
                        col =_volumetricTexture.Sample(sampler_volumetricTexture, i.uv);
                        break;
                }

                 // col = _volumetricTexture.Sample(sampler_volumetricTexture, i.uv);
          
                real3 finalShaft = col  * _Intensity*_SunMoonColor;
  
                real3 screen = tex2D(_MainTex, i.uv);
                return screen+ finalShaft;
            }
            ENDHLSL
        }
        Pass
        {
            Name "SampleDepth"

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

            struct appdata {
                real4 vertex : POSITION;
                real2 uv : TEXCOORD0;
            };

            struct v2f {
                real2 uv : TEXCOORD0;
                real4 vertex : SV_POSITION;
            };

            v2f vert(appdata v)
            {
                v2f o;
                o.vertex = TransformWorldToHClip(v.vertex);
                o.uv = v.uv;
                return o;
            }


            real frag(v2f i) : SV_Target
            {
                #if UNITY_REVERSED_Z
                real depth = SampleSceneDepth(i.uv);
                #else
                    // Adjust z to match NDC for OpenGL
                    real depth = lerp(UNITY_NEAR_CLIP_VALUE, 1, SampleSceneDepth(i.uv));
                #endif
                return depth;
            }
            ENDHLSL
        }
    }
}