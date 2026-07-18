using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using TheGang.Net;
using UnityEngine;

namespace TheGang.View
{
    /// Drives the 4 star chips from snapshots and handles take/steal clicks.
    /// Unclaimed chips sit at their center spots; claimed chips slide (with a
    /// small hop) to the holder's seat. Click an unclaimed chip to take it,
    /// another player's chip to steal it — the host validates turn order and
    /// challenge rules, so invalid clicks are simply ignored server-side.
    public class ChipsController : MonoBehaviour
    {
        public GangConnection connection;
        public ChipView[] chips; // index i = rank i+1
        public SeatView[] seats; // same array/order as PlayerSeatsController

        static readonly Dictionary<string, string> ClaimColumn = new Dictionary<string, string>
        {
            ["PRE_FLOP"] = "claim_preflop", ["FLOP"] = "claim_flop", ["TURN"] = "claim_turn",
            ["RIVER"] = "claim_river", ["SHOWDOWN"] = "claim_river", ["VERDICT"] = "claim_river",
            ["GAME_OVER"] = "claim_river",
        };
        static readonly HashSet<string> InteractivePhases = new HashSet<string> { "PRE_FLOP", "FLOP", "TURN", "RIVER" };

        string _phase = "LOBBY";
        JArray _players = new JArray();
        Vector3[] _centerHomes;
        Vector3[] _targets;
        Coroutine[] _moves;

        void Awake()
        {
            _centerHomes = new Vector3[chips.Length];
            _targets = new Vector3[chips.Length];
            _moves = new Coroutine[chips.Length];
            for (var i = 0; i < chips.Length; i++)
            {
                _centerHomes[i] = chips[i].transform.position;
                _targets[i] = _centerHomes[i];
            }
        }

        void OnEnable()
        {
            connection.OnGameSnapshot += HandleGame;
            connection.OnPlayersSnapshot += HandlePlayers;
        }

        void OnDisable()
        {
            connection.OnGameSnapshot -= HandleGame;
            connection.OnPlayersSnapshot -= HandlePlayers;
        }

        void HandleGame(JObject game)
        {
            _phase = (string)game["status"] ?? "LOBBY";
            Refresh();
        }

        void HandlePlayers(JArray players)
        {
            _players = players ?? new JArray();
            Refresh();
        }

        void Update()
        {
            if (!Input.GetMouseButtonDown(0)) return;
            var cam = Camera.main;
            if (cam == null || !connection.IsConnected) return;
            if (!Physics.Raycast(cam.ScreenPointToRay(Input.mousePosition), out var hit, 30f)) return;
            for (var i = 0; i < chips.Length; i++)
            {
                if (hit.transform.IsChildOf(chips[i].transform)) OnChipClicked(i + 1);
            }
        }

        void OnChipClicked(int rank)
        {
            if (!InteractivePhases.Contains(_phase)) return;
            var holder = HolderOf(ClaimColumn[_phase], rank);
            var me = connection.LocalUserId;
            if (holder == null) _ = connection.TakeChip(me, rank, _phase);
            else if (holder != me) _ = connection.StealChip(me, rank, _phase, holder);
        }

        void Refresh()
        {
            ClaimColumn.TryGetValue(_phase, out var col);
            var colorPhase = _phase == "SHOWDOWN" || _phase == "VERDICT" || _phase == "GAME_OVER" ? "RIVER" : _phase;
            var map = PlayerSeatsController.SeatMap(_players, connection.LocalUserId, seats.Length);

            for (var i = 0; i < chips.Length; i++)
            {
                var rank = i + 1;
                var active = _players.Count == 0 || rank <= _players.Count;
                chips[i].gameObject.SetActive(active);
                if (!active) continue;
                chips[i].SetPhase(colorPhase, rank);

                var target = _centerHomes[i];
                var holder = col != null ? HolderOf(col, rank) : null;
                if (holder != null && map.TryGetValue(holder, out var seatIdx))
                {
                    target = ChipSpot(seats[seatIdx].transform.position, rank);
                }
                if (target == _targets[i]) continue;
                _targets[i] = target;
                if (_moves[i] != null) StopCoroutine(_moves[i]);
                _moves[i] = StartCoroutine(ViewTween.MoveTo(chips[i].transform, target, 0.35f, 0.12f));
            }
        }

        string HolderOf(string claimColumn, int rank)
        {
            foreach (var p in _players)
            {
                if ((int?)p[claimColumn] == rank) return (string)p["user_id"];
            }
            return null;
        }

        /// A spot on the felt just inside the seat's cards, fanned per rank so
        /// multiple chips at one seat don't stack on the same point.
        Vector3 ChipSpot(Vector3 seatPos, int rank)
        {
            var flat = new Vector3(seatPos.x, 0f, seatPos.z);
            var toCenter = flat.sqrMagnitude > 0.001f ? -flat.normalized : Vector3.forward;
            var side = Vector3.Cross(Vector3.up, toCenter);
            return seatPos + toCenter * 0.30f + side * ((rank - 2.5f) * 0.10f);
        }
    }
}
