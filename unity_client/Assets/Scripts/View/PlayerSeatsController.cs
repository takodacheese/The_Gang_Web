using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using TheGang.Net;
using UnityEngine;

namespace TheGang.View
{
    /// Fills the SeatViews from player snapshots. The local player always gets
    /// seats[0] (the open near side of the table); everyone else takes the
    /// remaining seats in host join order. Only your own pocket cards are shown
    /// face up — everyone else's stay as backs, same as the Flutter client.
    public class PlayerSeatsController : MonoBehaviour
    {
        public GangConnection connection;
        public SeatView[] seats; // [0] = local player's near-side seat

        void OnEnable() => connection.OnPlayersSnapshot += Handle;
        void OnDisable() => connection.OnPlayersSnapshot -= Handle;

        void Handle(JArray players)
        {
            var map = SeatMap(players, connection.LocalUserId, seats.Length);
            var used = new bool[seats.Length];
            foreach (var p in players)
            {
                var id = (string)p["user_id"];
                if (id == null || !map.TryGetValue(id, out var idx)) continue;
                used[idx] = true;
                var mine = id == connection.LocalUserId;
                var hand = p["hand_cards"] as JArray;
                // ponytail: shows two pocket cards; the "Security Cameras"
                // 3-card challenge needs a third CardView per seat.
                seats[idx].SetPlayer((string)p["display_name"] ?? "Player",
                    mine ? CardAt(hand, 0) : null,
                    mine ? CardAt(hand, 1) : null);
            }
            for (var i = 0; i < seats.Length; i++)
            {
                if (!used[i]) seats[i].SetEmpty();
            }
        }

        static string CardAt(JArray hand, int i) => hand != null && i < hand.Count ? (string)hand[i] : null;

        /// user_id -> seat index. Shared with ChipsController so chips land at
        /// the same seat the player's cards are on.
        public static Dictionary<string, int> SeatMap(JArray players, string localId, int seatCount)
        {
            var map = new Dictionary<string, int>();
            var next = 1;
            foreach (var p in players)
            {
                var id = (string)p["user_id"];
                if (id == null) continue;
                if (id == localId) map[id] = 0;
                else if (next < seatCount) map[id] = next++;
            }
            return map;
        }
    }
}
