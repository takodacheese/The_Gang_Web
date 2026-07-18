using System.Collections;
using System.Collections.Generic;
using UnityEngine;

namespace TheGang.View
{
    /// Attach to a Quad (with an Unlit/Transparent Cutout material) to display one
    /// playing card. Mirrors lib/widgets/playing_card_view.dart's `_assetFor` so
    /// both clients pick the same texture for the same 2-char card code.
    [RequireComponent(typeof(MeshRenderer))]
    public class CardView : MonoBehaviour
    {
        public CardAtlas atlas;

        static readonly Dictionary<char, string> SuitNames = new Dictionary<char, string>
        {
            ['s'] = "spades", ['h'] = "hearts", ['d'] = "diamonds", ['c'] = "clubs",
        };

        MeshRenderer _renderer;
        MeshRenderer Renderer => _renderer != null ? _renderer : (_renderer = GetComponent<MeshRenderer>());

        /// card: a 2-char code like "As", "Th" — null/empty shows the card back.
        public void SetCard(string card)
        {
            var tex = atlas.Find(TextureNameFor(card));
            if (tex != null) Renderer.material.mainTexture = tex;
        }

        /// SetCard with a quick edge-on flip (scale-x squash, swap at midpoint).
        public void SetCardAnimated(string card, float duration = 0.25f)
        {
            if (isActiveAndEnabled) StartCoroutine(FlipTo(card, duration));
            else SetCard(card);
        }

        public IEnumerator FlipTo(string card, float duration = 0.25f)
        {
            var full = transform.localScale;
            var half = duration * 0.5f;
            for (float e = 0f; e < half; e += Time.deltaTime)
            {
                SetScaleX(full, 1f - e / half);
                yield return null;
            }
            SetCard(card);
            for (float e = 0f; e < half; e += Time.deltaTime)
            {
                SetScaleX(full, e / half);
                yield return null;
            }
            transform.localScale = full;
        }

        void SetScaleX(Vector3 full, float k)
        {
            transform.localScale = new Vector3(full.x * Mathf.Max(0.01f, k), full.y, full.z);
        }

        static string TextureNameFor(string card)
        {
            if (string.IsNullOrEmpty(card)) return "card_back";

            var rankChar = char.ToUpperInvariant(card[0]);
            var suitChar = card.Length > 1 ? char.ToLowerInvariant(card[1]) : '\0';
            if (!SuitNames.TryGetValue(suitChar, out var suitName)) return "card_joker_black";

            var rankStr = rankChar == 'T' ? "10"
                : (rankChar == 'A' || rankChar == 'K' || rankChar == 'Q' || rankChar == 'J') ? rankChar.ToString()
                : rankChar.ToString().PadLeft(2, '0');
            return $"card_{suitName}_{rankStr}";
        }
    }
}
