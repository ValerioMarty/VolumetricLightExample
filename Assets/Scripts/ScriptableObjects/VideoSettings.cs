using System.Collections;
using System.Collections.Generic;
using UnityEngine;

[CreateAssetMenu(fileName = "VideoSettingsManager", menuName = "VideoSettings/Manager", order = 1)]
public class VideoSettings : ScriptableObject
{
    [SerializeField]
    private int quality;
    public VideoSetting[] qualitySettings;

    public VideoSetting currentSettings;

    public int Quality
    {
        get => quality; set
        {
            if (value != quality)
            {
                currentSettings = qualitySettings[value];
                quality = value;
            }
        }
    }
    private void OnValidate()
    {
        currentSettings = qualitySettings[Quality];
    }
}
