using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;

namespace RaymarchVoxels
{
    public class RaymarchVoxelsShaderEditor : ShaderGUI
    {
        private MaterialEditor materialEditor;
        private MaterialProperty castShadowsProp;
        private MaterialProperty receiveShadowsProp;
        private MaterialProperty textureProp;
        private MaterialProperty baseColorProp;
        private MaterialProperty smoothnessProp;
        private MaterialProperty specularColorProp;
        private MaterialProperty emissionColorProp;

        public override void OnGUI(MaterialEditor materialEditor, MaterialProperty[] properties)
        {
            this.materialEditor = materialEditor;
            Material material = materialEditor.target as Material;
            FindProperties(properties);
            
            DrawSurfaceOptions(material);
            DrawSpecularProperties(material);
            DrawEmissionProperties(material);
            DrawShadowsProperties(material);
        }

        private void DrawSpecularProperties(Material material)
        {
            materialEditor.ColorProperty(specularColorProp, specularColorProp.displayName);
            materialEditor.RangeProperty(smoothnessProp, smoothnessProp.displayName);
        }
        
        public void DrawSurfaceOptions(Material material)
        {
            materialEditor.TextureProperty(textureProp, textureProp.displayName);
            materialEditor.ColorProperty(baseColorProp, baseColorProp.displayName);
        }

        protected virtual void DrawEmissionProperties(Material material)
        {
            bool emissive = materialEditor.EmissionEnabledProperty();

            if (emissive)
            {
                materialEditor.ColorProperty(emissionColorProp, emissionColorProp.displayName);
            }

            CoreUtils.SetKeyword(material, "_EMISSION", emissive);
        }

        protected virtual void DrawShadowsProperties(Material material)
        {
            DrawFloatToggleProperty("Cast Shadows", castShadowsProp);
            bool castShadows = castShadowsProp.floatValue != 0f;
            material.SetShaderPassEnabled("ShadowCaster", castShadows);

            DrawFloatToggleProperty("Receive Shadows", receiveShadowsProp);
            CoreUtils.SetKeyword(material, "_RECEIVE_SHADOWS", receiveShadowsProp.floatValue != 0f);
        }
        

        private void FindProperties(MaterialProperty[] properties)
        {
            var material = materialEditor.target as Material;
            if (material == null)
            {
                return;
            }

            textureProp = FindProperty("_Voxels", properties, false);
            baseColorProp = FindProperty("_BaseColor", properties, false);
            castShadowsProp = FindProperty("_CastShadows", properties, false);
            receiveShadowsProp = FindProperty("_ReceiveShadows", properties, false);
            smoothnessProp = FindProperty("_Smoothness", properties, false);
            specularColorProp = FindProperty("_SpecColor", properties, false);
            emissionColorProp = FindProperty("_EmissionColor", properties, false);
        }

        private void DrawFloatToggleProperty(string styles, MaterialProperty prop, int indentLevel = 0, bool isDisabled = false)
        {
            if (prop == null)
            {
                return;
            }

            EditorGUI.BeginDisabledGroup(isDisabled);
            EditorGUI.indentLevel += indentLevel;
            EditorGUI.BeginChangeCheck();
            MaterialEditor.BeginProperty(prop);
            bool newValue = EditorGUILayout.Toggle(styles, prop.floatValue != 0f);
            if (EditorGUI.EndChangeCheck())
            {
                prop.floatValue = newValue ? 1f : 0f;
            }

            MaterialEditor.EndProperty();
            EditorGUI.indentLevel -= indentLevel;
            EditorGUI.EndDisabledGroup();
        }
    }
}