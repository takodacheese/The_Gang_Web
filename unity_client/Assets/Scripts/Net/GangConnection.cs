using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace TheGang.Net
{
    /// <summary>
    /// Unity-side client for the same LAN protocol the Flutter project speaks
    /// (see the_gang/lib/lan/lan_host.dart + lan_remote.dart). Unity only ever
    /// joins as a guest here — the Flutter app remains the authoritative host
    /// (GameEngine), so this class never starts a server or a UDP responder.
    ///
    /// Wire format (all JSON over one WebSocket connection):
    ///   Unity -> host : {"op":"join","userId":..,"displayName":..}
    ///                   {"op":"takeChip","userId":..,"rank":..,"phase":..}
    ///                   {"op":"stealChip","userId":..,"rank":..,"phase":..,"victimUserId":..}
    ///   host -> Unity : {"type":"snapshot","game":{...},"players":[...]}
    ///                   sent once right after connecting, then again after
    ///                   every state change.
    ///
    /// Discovery: broadcast "GANG_DISCOVER:&lt;4-digit code&gt;" on UDP port
    /// DiscoveryPort; the host replies "GANG_HERE:&lt;gamePort&gt;" by unicast.
    ///
    /// Requires the "com.unity.nuget.newtonsoft-json" package (Window > Package
    /// Manager > Add package by name) for JObject/JArray.
    /// </summary>
    public class GangConnection : MonoBehaviour
    {
        public const int DiscoveryPort = 45677;
        public const int GamePort = 45678;

        /// Raw "game" map from the latest snapshot (mirrors the Flutter GameConnection.currentGame).
        public event Action<JObject> OnGameSnapshot;

        /// Raw "players" list from the latest snapshot (mirrors GameConnection.currentPlayers).
        public event Action<JArray> OnPlayersSnapshot;

        public event Action<string> OnError;

        ClientWebSocket _socket;
        CancellationTokenSource _cts;
        readonly ConcurrentQueue<string> _incoming = new ConcurrentQueue<string>();

        public bool IsConnected => _socket != null && _socket.State == WebSocketState.Open;

        /// The userId passed to DiscoverAndJoin — lets views tell "you" apart
        /// from the other players in snapshots.
        public string LocalUserId { get; private set; }

        /// Broadcasts the room code on the LAN, connects to whichever host answers,
        /// and sends the initial join message. Returns false if no host answered
        /// within timeoutMs (room not found, or a hotspot that blocks broadcast —
        /// see the AP-isolation note in the Flutter project's chat history).
        public async Task<bool> DiscoverAndJoin(string roomCode, string userId, string displayName, int timeoutMs = 3000)
        {
            var ip = await DiscoverHostIp(roomCode, timeoutMs);
            if (ip == null) return false;
            LocalUserId = userId;

            _cts = new CancellationTokenSource();
            _socket = new ClientWebSocket();
            await _socket.ConnectAsync(new Uri($"ws://{ip}:{GamePort}"), _cts.Token);

            _ = ReceiveLoop(_cts.Token);
            await Send(new JObject { ["op"] = "join", ["userId"] = userId, ["displayName"] = displayName });
            return true;
        }

        static async Task<string> DiscoverHostIp(string roomCode, int timeoutMs)
        {
            using var udp = new UdpClient(0) { EnableBroadcast = true };
            var payload = Encoding.UTF8.GetBytes($"GANG_DISCOVER:{roomCode}");
            await udp.SendAsync(payload, payload.Length, new IPEndPoint(IPAddress.Broadcast, DiscoveryPort));

            var receiveTask = udp.ReceiveAsync();
            var finished = await Task.WhenAny(receiveTask, Task.Delay(timeoutMs));
            if (finished != receiveTask) return null;

            var result = receiveTask.Result;
            var msg = Encoding.UTF8.GetString(result.Buffer);
            return msg.StartsWith("GANG_HERE:") ? result.RemoteEndPoint.Address.ToString() : null;
        }

        async Task ReceiveLoop(CancellationToken token)
        {
            var buffer = new byte[16 * 1024];
            try
            {
                while (!token.IsCancellationRequested && _socket.State == WebSocketState.Open)
                {
                    using var ms = new MemoryStream();
                    WebSocketReceiveResult result;
                    do
                    {
                        result = await _socket.ReceiveAsync(new ArraySegment<byte>(buffer), token);
                        ms.Write(buffer, 0, result.Count);
                    } while (!result.EndOfMessage);

                    if (result.MessageType == WebSocketMessageType.Close) break;
                    _incoming.Enqueue(Encoding.UTF8.GetString(ms.ToArray()));
                }
            }
            catch (Exception e)
            {
                // Sentinel null tells Update() (main thread) to raise OnError —
                // Unity events must not fire directly from this background task.
                _incoming.Enqueue(null);
                Debug.LogWarning($"GangConnection receive loop ended: {e.Message}");
            }
        }

        void Update()
        {
            while (_incoming.TryDequeue(out var raw))
            {
                if (raw == null)
                {
                    OnError?.Invoke("connection lost");
                    continue;
                }
                var msg = JObject.Parse(raw);
                if ((string)msg["type"] != "snapshot") continue;
                OnGameSnapshot?.Invoke((JObject)msg["game"]);
                OnPlayersSnapshot?.Invoke((JArray)msg["players"]);
            }
        }

        // --- Guest-triggerable actions (match GameConnection.takeChip/stealChip) ---

        public Task TakeChip(string userId, int rank, string phase) =>
            Send(new JObject { ["op"] = "takeChip", ["userId"] = userId, ["rank"] = rank, ["phase"] = phase });

        public Task StealChip(string userId, int rank, string phase, string victimUserId) =>
            Send(new JObject
            {
                ["op"] = "stealChip",
                ["userId"] = userId,
                ["rank"] = rank,
                ["phase"] = phase,
                ["victimUserId"] = victimUserId,
            });

        Task Send(JObject op)
        {
            if (_socket == null || _socket.State != WebSocketState.Open) return Task.CompletedTask;
            var bytes = Encoding.UTF8.GetBytes(op.ToString(Newtonsoft.Json.Formatting.None));
            return _socket.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, CancellationToken.None);
        }

        void OnDestroy()
        {
            _cts?.Cancel();
            _socket?.Dispose();
        }
    }
}
