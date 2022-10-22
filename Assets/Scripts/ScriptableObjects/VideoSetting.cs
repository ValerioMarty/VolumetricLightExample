using System.Collections;
using System.Collections.Generic;
using UnityEngine;

[CreateAssetMenu(fileName = "VideoSettings", menuName = "VideoSettings/settings", order = 1)]
public class VideoSetting : ScriptableObject
{
    public enum DownSample { off = 1, half = 2, third = 3, quarter = 4 };

    [System.Serializable]
    public class VolumetricSettings
    {

        public DownSample downsampling;

        public float Samples;

        [Space(10)]
        public float blurAmount;

        public float blurSamples;

    }
    [System.Serializable]
    public class ShaftSettings
    {

        public DownSample downsampling;
        public float intensity;
        // public float Samples;
        // public float blurAmount;
        // public float blurSamples;
    }
    public bool enableVolumetricLighting;

    public VolumetricSettings volumetricSettings;
}
