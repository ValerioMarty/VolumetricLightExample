
using UnityEngine;
[ExecuteAlways]
public class MoonDirection : MonoBehaviour
{
    private static readonly int SunDirection = Shader.PropertyToID("_SunDirection");
    [SerializeField] private Light light;
    private static readonly int s_SunMoonColor = Shader.PropertyToID("_SunMoonColor");

    void Start()
    {
        Shader.SetGlobalVector(SunDirection, transform.forward);
        Shader.SetGlobalVector(s_SunMoonColor, light.color);

    }

    // // Update is called once per frame
    void Update()
    {
        var forward = transform.forward;
        Shader.SetGlobalVector(SunDirection, forward);
        Shader.SetGlobalVector(s_SunMoonColor, light.color);
    }
}
