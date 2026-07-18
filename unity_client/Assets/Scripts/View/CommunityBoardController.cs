using System;
using System.Collections;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using TheGang.Net;
using UnityEngine;

namespace TheGang.View
{
    /// Drives the 5 community-card slots from GangConnection snapshots — same
    /// phase -> visible-count map as game_screen.dart's `_buildCommunityCards`.
    /// Newly revealed cards are dealt: they fly in from deckAnchor, then flip.
    public class CommunityBoardController : MonoBehaviour
    {
        public GangConnection connection;
        public CardView[] slots = new CardView[5];
        public Transform deckAnchor;

        static readonly Dictionary<string, int> VisibleCountByPhase = new Dictionary<string, int>
        {
            ["PRE_FLOP"] = 0, ["FLOP"] = 3, ["TURN"] = 4, ["RIVER"] = 5,
            ["SHOWDOWN"] = 5, ["VERDICT"] = 5, ["GAME_OVER"] = 5,
        };

        Vector3[] _homes;
        Vector3[] _scales;
        readonly string[] _shown = new string[5];

        void Awake()
        {
            _homes = new Vector3[slots.Length];
            _scales = new Vector3[slots.Length];
            for (var i = 0; i < slots.Length; i++)
            {
                _homes[i] = slots[i].transform.position;
                _scales[i] = slots[i].transform.localScale;
            }
        }

        void OnEnable() => connection.OnGameSnapshot += HandleSnapshot;
        void OnDisable() => connection.OnGameSnapshot -= HandleSnapshot;

        void HandleSnapshot(JObject game)
        {
            var phase = (string)game["status"] ?? "LOBBY";
            var visible = VisibleCountByPhase.TryGetValue(phase, out var n) ? n : 0;
            var cards = game["community_cards"] as JArray ?? new JArray();

            if (visible == 0)
            {
                // New heist (or lobby): kill in-flight deals, reset to backs.
                StopAllCoroutines();
                for (var i = 0; i < slots.Length; i++)
                {
                    slots[i].transform.position = _homes[i];
                    slots[i].transform.localScale = _scales[i]; // undo any half-finished flip
                    slots[i].SetCard(null);
                }
                Array.Clear(_shown, 0, _shown.Length);
                return;
            }

            var dealt = 0;
            for (var i = 0; i < slots.Length; i++)
            {
                var card = i < visible && i < cards.Count ? (string)cards[i] : null;
                if (card == _shown[i]) continue;
                _shown[i] = card;
                if (card == null)
                {
                    slots[i].transform.position = _homes[i];
                    slots[i].SetCard(null);
                }
                else
                {
                    StartCoroutine(Deal(i, card, 0.12f * dealt++));
                }
            }
        }

        IEnumerator Deal(int slot, string card, float delay)
        {
            var t = slots[slot].transform;
            slots[slot].SetCard(null);
            if (deckAnchor != null)
            {
                t.position = deckAnchor.position;
                if (delay > 0f) yield return new WaitForSeconds(delay);
                yield return ViewTween.MoveTo(t, _homes[slot], 0.3f);
            }
            yield return slots[slot].FlipTo(card);
        }
    }
}
