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