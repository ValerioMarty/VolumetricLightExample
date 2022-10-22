using System;
using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class VolumetricLightFeature : ScriptableRendererFeature
{
    [System.Serializable]
    public class Settings
    {
        public VideoSettings videoSettings;

        public enum Stage { raymarch, gaussianBlur, full };

        [Space(10)]
        public Stage stage;
        public float intensity = 1;
        // public float contrast = 1;
        // [Range(0,0.5f)]
        // public float middleValue=0.5f;
        // public float brightness = 1;
        [Range(-1,1)]
        public float scattering = 0;

        public float maxDistance;
        public float jitter = 1;

        public Material material;
        public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingPostProcessing;
    }

    public Settings settings = new Settings();
    Pass pass;
    RenderTargetHandle renderTextureHandle;
    private static readonly int Scattering = Shader.PropertyToID("_Scattering");
    private static readonly int Steps = Shader.PropertyToID("_Steps");
    private static readonly int JitterVolumetric = Shader.PropertyToID("_JitterVolumetric");
    private static readonly int MaxDistance = Shader.PropertyToID("_MaxDistance");
    private static readonly int Intensity = Shader.PropertyToID("_Intensity");
    private static readonly int GaussSamples = Shader.PropertyToID("_GaussSamples");
    private static readonly int GaussAmount = Shader.PropertyToID("_GaussAmount");
    private static readonly int Boost = Shader.PropertyToID("_Boost");
    private static readonly int DepthSteps = Shader.PropertyToID("_DepthSteps");
    private static readonly int DepthMaxDistance = Shader.PropertyToID("_DepthMaxDistance");
    private static readonly int ColorJitterMultiplier = Shader.PropertyToID("_ColorJitterMultiplier");
    private static readonly int contrastProperty = Shader.PropertyToID("_Contrast");
    private static readonly int brightnessProperty = Shader.PropertyToID("_Brightness");
    private static readonly int middleValueProperty = Shader.PropertyToID("_MiddleValue");
    private static readonly int axis = Shader.PropertyToID("_Axis");

    public override void Create()
    {
        pass = new Pass("Volumetric Light");
        name = "Volumetric Light";

        pass.settings = settings;
        pass.renderPassEvent = settings.renderPassEvent;
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        try
        {
            if (!settings.videoSettings.currentSettings.enableVolumetricLighting)
                return;
            if (renderingData.cameraData.cameraType == CameraType.Game ||renderingData.cameraData.cameraType == CameraType.SceneView)
            {
                var cameraColorTargetIdent = renderer.cameraColorTarget;
                pass.Setup(cameraColorTargetIdent);
                renderer.EnqueuePass(pass);
            }
        }
        catch (Exception e)
        {
            Debug.LogError(e);
        }
       
    }
    class Pass : ScriptableRenderPass
    {
        public Settings settings;
        private RenderTargetIdentifier source;
        RenderTargetHandle tempTexture;
        RenderTargetHandle lowResDepthRT;
        RenderTargetHandle temptexture3;
        readonly ProfilingSampler m_ProfilingSampler = new ProfilingSampler("Volumetric Lighting");

        // private string profilerTag;

        public void Setup(RenderTargetIdentifier source)
        {
            this.source = source;
        }

        public Pass(string profilerTag)
        {
            // this.profilerTag = profilerTag;
        }

        public override void Configure(CommandBuffer cmd, RenderTextureDescriptor cameraTextureDescriptor)
        {
            var original = cameraTextureDescriptor;
            int divider = (int)settings.videoSettings.currentSettings.volumetricSettings.downsampling;
            if (Camera.current != null) //This is necessary so it uses the proper resolution in the scene window
            {
                var pixelRect = Camera.current.pixelRect;
                cameraTextureDescriptor.width = (int)pixelRect.width / divider;
                cameraTextureDescriptor.height = (int)pixelRect.height / divider;
                original.width = (int)pixelRect.width;
                original.height = (int)pixelRect.height;
            }
            else //regular game window
            {
                cameraTextureDescriptor.width /= divider;
                cameraTextureDescriptor.height /= divider;
            }
            cameraTextureDescriptor.colorFormat = RenderTextureFormat.R16;
            
            cameraTextureDescriptor.depthBufferBits = 0;
            //we dont need to resolve AA in every single Blit
            cameraTextureDescriptor.msaaSamples = 1;
            //we need to assing a different id for every render texture
            lowResDepthRT.id = 1;
            temptexture3.id = 2;
            
            cmd.GetTemporaryRT(tempTexture.id, cameraTextureDescriptor);
            ConfigureTarget(tempTexture.Identifier());
            cmd.GetTemporaryRT(lowResDepthRT.id, cameraTextureDescriptor);
            cmd.GetTemporaryRT(temptexture3.id, original);
            ConfigureClear(ClearFlag.All, Color.black);
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            var camera = renderingData.cameraData.camera;
            
            if (camera.cameraType is not (CameraType.Game or CameraType.SceneView))
                return;
            CommandBuffer cmd = CommandBufferPool.Get();
    
            using (new ProfilingScope(cmd, m_ProfilingSampler))
            {
                //it is very important that if something fails our code still calls
                //CommandBufferPool.Release(cmd) or we will have a HUGE memory leak
                try
                {
                    settings.material.SetFloat(Scattering, settings.scattering);
                    settings.material.SetFloat(Steps, settings.videoSettings.currentSettings.volumetricSettings.Samples);
                    settings.material.SetFloat(JitterVolumetric, settings.jitter);
                    settings.material.SetFloat(MaxDistance, settings.maxDistance);
                    settings.material.SetFloat(Intensity, settings.intensity);
                    settings.material.SetFloat(GaussSamples, settings.videoSettings.currentSettings.volumetricSettings.blurSamples);
                    settings.material.SetFloat(GaussAmount, settings.videoSettings.currentSettings.volumetricSettings.blurAmount);


                    //this is a debug feature which will let us see the process until any given point
                    switch (settings.stage)
                    {
                        case Settings.Stage.raymarch:

                            cmd.Blit(source, tempTexture.Identifier());
                            cmd.Blit(tempTexture.Identifier(), source, settings.material, 0);

                            break;
                        case Settings.Stage.gaussianBlur:

                            cmd.Blit(source, tempTexture.Identifier(), settings.material, 0);
                            // settings.material.EnableKeyword("_Vertical");
                            cmd.Blit(tempTexture.Identifier(), lowResDepthRT.Identifier(), settings.material, 1);
                            // settings.material.DisableKeyword("_Vertical");
                            cmd.Blit(lowResDepthRT.Identifier(), source, settings.material, 2);

                            break;
                        case Settings.Stage.full:
                        default:
                            //raymarch
                            
                            cmd.Blit(source, tempTexture.Identifier(), settings.material, 0);
                            //bilateral blu X
                      
                            cmd.Blit(tempTexture.Identifier(), lowResDepthRT.Identifier(), settings.material, 1);
                            //bilateral blur Y
                 
                            cmd.Blit(lowResDepthRT.Identifier(), tempTexture.Identifier(), settings.material, 2);
                            //downsample depth
                            cmd.Blit(source, lowResDepthRT.Identifier(), settings.material, 4);
                            cmd.SetGlobalTexture("_LowResDepth", lowResDepthRT.Identifier());
                            cmd.SetGlobalTexture("_volumetricTexture", tempTexture.Identifier());
                      
                            // upsample and composite
                            cmd.Blit(source, temptexture3.Identifier(), settings.material, 3);
                            cmd.Blit("_CameraDepth2Texture", source);
                
                            break;
                    }
                    context.ExecuteCommandBuffer(cmd);
                }
                catch
                {
                    Debug.LogError("nope");
                }
                cmd.Clear();
                CommandBufferPool.Release(cmd);
            }
        }
    }


}
