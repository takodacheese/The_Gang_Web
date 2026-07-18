using UnityEngine;

namespace TheGang.View
{
    /// One-time setup asset: select all 54 PNGs in Assets/Textures/Cards/ and drag
    /// them into `textures` here, so CardView can look one up by name without
    /// needing a Resources/ folder.
    [CreateAssetMenu(menuName = "The Gang/Card Atlas")]
    public class CardAtlas : ScriptableObject
    {
        public Texture2D[] textures;

        public Texture2D Find(string textureName)
        {
            foreach (var t in textures)
            {
                if (t != null && t.name == textureName) return t;
            }
            Debug.LogWarning($"CardAtlas: no texture named '{textureName}'");
            return null;
        }
    }
}
