using System;
using TheGang.Net;
using UnityEngine;

namespace TheGang.View
{
    /// Minimal join overlay: room code + name + Join button, drawn with IMGUI
    /// so no canvas/prefab setup is needed. Hides itself once connected; the
    /// snapshot events drive the board from there.
    public class JoinBootstrap : MonoBehaviour
    {
        public GangConnection connection;
        public string roomCode = "1234";
        public string displayName = "Unity";

        string _status = "";
        bool _joining;
        string _userId;

        void Awake() => _userId = Guid.NewGuid().ToString("N").Substring(0, 8);
        void OnEnable() => connection.OnError += HandleError;
        void OnDisable() => connection.OnError -= HandleError;

        void HandleError(string error)
        {
            _joining = false;
            _status = error;
        }

        async void Join()
        {
            _joining = true;
            _status = "Searching for host...";
            var ok = await connection.DiscoverAndJoin(roomCode, _userId, displayName);
            _joining = false;
            if (!ok) _status = "No host found. Is the Flutter host running with this room code?";
        }

        void OnGUI()
        {
            if (connection == null || connection.IsConnected) return;

            // Scale IMGUI up so it is readable on high-DPI screens.
            var scale = Mathf.Max(1f, Screen.height / 500f);
            GUI.matrix = Matrix4x4.Scale(Vector3.one * scale);
            var w = 260f;
            var area = new Rect((Screen.width / scale - w) / 2f, 60f, w, 190f);

            GUI.Box(area, "The Gang");
            GUILayout.BeginArea(new Rect(area.x + 15f, area.y + 30f, area.width - 30f, area.height - 45f));
            GUILayout.Label("Room code");
            roomCode = GUILayout.TextField(roomCode, 4);
            GUILayout.Label("Your name");
            displayName = GUILayout.TextField(displayName, 16);
            GUILayout.Space(8f);
            GUI.enabled = !_joining && roomCode.Length == 4 && displayName.Length > 0;
            if (GUILayout.Button("Join")) Join();
            GUI.enabled = true;
            GUILayout.Label(_status);
            GUILayout.EndArea();
        }
    }
}
