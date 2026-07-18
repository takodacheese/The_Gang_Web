using System.Collections.Generic;
using System.IO;
using TheGang.Net;
using TheGang.View;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;

namespace TheGang.EditorTools
{
    /// One-click scene assembly: Tools > The Gang > Build Table Scene.
    /// Builds the whole table scene (camera, lights, table, chairs, card slots,
    /// chips), wires CardAtlas / CardView / ChipView / CommunityBoardController,
    /// and saves it as Assets/Scenes/Table.unity. Safe to re-run: it recreates
    /// the scene and reuses the material/atlas assets it made before.
    public static class GangSceneBuilder
    {
        // Clean & modern palette.
        static readonly Color Background = new Color32(0x1B, 0x1F, 0x27, 0xFF);
        static readonly Color FloorColor = new Color32(0x26, 0x2B, 0x35, 0xFF);
        static readonly Color Felt = new Color32(0x2F, 0x7D, 0x6D, 0xFF);
        static readonly Color Rail = new Color32(0x1E, 0x1F, 0x24, 0xFF);
        static readonly Color Wood = new Color32(0xD4, 0xB8, 0x8F, 0xFF);
        static readonly Color ChairCushion = new Color32(0x2A, 0x2E, 0x38, 0xFF);
        static readonly Color ChipBody = new Color32(0xF5, 0xF5, 0xF5, 0xFF);

        const float TableTopY = 0.75f;
        const float CardW = 0.28f, CardH = 0.38f;

        [MenuItem("Tools/The Gang/Build Table Scene")]
        public static void Build()
        {
            var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);

            BuildLighting();
            BuildCamera();
            BuildFloor();
            var feltTop = BuildTable();
            BuildChairs();

            var atlas = EnsureCardAtlas();
            // Starts as the card back; CardView swaps in the face texture at
            // runtime (renderer.material) without touching the shared asset.
            var cardMat = EnsureCardMaterial("Card", FindCardTexture("card_back"));

            var slots = BuildCommunitySlots(feltTop, atlas, cardMat);
            var seats = BuildSeats(feltTop, atlas, cardMat);
            var chips = BuildChips(feltTop);
            var deck = new GameObject("Deck Anchor");
            deck.transform.position = new Vector3(-1.9f, feltTop + 0.15f, 0.02f);
            WireControllers(slots, seats, chips, deck.transform);

            EnsureFolder("Assets/Scenes");
            EditorSceneManager.SaveScene(scene, "Assets/Scenes/Table.unity");
            EditorBuildSettings.scenes = new[] { new EditorBuildSettingsScene("Assets/Scenes/Table.unity", true) };
            Debug.Log("The Gang: table scene built and saved to Assets/Scenes/Table.unity");
        }

        /// Renders the saved scene through Main Camera to table_preview.png in
        /// the project root — a quick look without entering play mode.
        [MenuItem("Tools/The Gang/Save Scene Preview")]
        public static void SavePreview()
        {
            EditorSceneManager.OpenScene("Assets/Scenes/Table.unity");
            var cam = Camera.main;
            const int w = 1280, h = 720;
            var rt = new RenderTexture(w, h, 24);
            cam.targetTexture = rt;
            cam.Render();
            RenderTexture.active = rt;
            var tex = new Texture2D(w, h, TextureFormat.RGB24, false);
            tex.ReadPixels(new Rect(0, 0, w, h), 0, 0);
            tex.Apply();
            cam.targetTexture = null;
            RenderTexture.active = null;
            File.WriteAllBytes("table_preview.png", tex.EncodeToPNG());
            Debug.Log("The Gang: preview saved to table_preview.png");
        }

        static void BuildLighting()
        {
            RenderSettings.ambientMode = AmbientMode.Flat;
            RenderSettings.ambientLight = new Color(0.32f, 0.34f, 0.40f);

            var key = new GameObject("Key Light").AddComponent<Light>();
            key.type = LightType.Directional;
            key.color = new Color(1.0f, 0.96f, 0.90f);
            key.intensity = 1.15f;
            key.shadows = LightShadows.Soft;
            key.transform.rotation = Quaternion.Euler(55f, -32f, 0f);

            var fill = new GameObject("Fill Light").AddComponent<Light>();
            fill.type = LightType.Directional;
            fill.color = new Color(0.55f, 0.62f, 0.75f);
            fill.intensity = 0.35f;
            fill.shadows = LightShadows.None;
            fill.transform.rotation = Quaternion.Euler(40f, 140f, 0f);
        }

        static void BuildCamera()
        {
            var cam = new GameObject("Main Camera").AddComponent<Camera>();
            cam.gameObject.tag = "MainCamera";
            cam.clearFlags = CameraClearFlags.SolidColor;
            cam.backgroundColor = Background;
            cam.fieldOfView = 45f;
            cam.transform.position = new Vector3(0f, 2.7f, -3.6f);
            cam.transform.LookAt(new Vector3(0f, TableTopY, 0.25f));
            cam.gameObject.AddComponent<AudioListener>();
        }

        static void BuildFloor()
        {
            var floor = GameObject.CreatePrimitive(PrimitiveType.Plane);
            floor.name = "Floor";
            floor.transform.localScale = new Vector3(4f, 1f, 4f);
            floor.GetComponent<MeshRenderer>().sharedMaterial = EnsureMaterial("Floor", FloorColor, 0.05f);
        }

        /// Returns the y of the felt (cloth) surface.
        static float BuildTable()
        {
            var table = Instantiate("Assets/Models/PokerPack/table.obj", "Table");
            // Long axis along x so the 5-card row reads left-to-right on camera.
            table.transform.rotation = Quaternion.Euler(0f, 90f, 0f);
            FitOnFloor(table, TableTopY);
            var felt = EnsureMaterial("Felt", Felt, 0.12f);
            RemapMaterials(table, new Dictionary<string, Material>
            {
                ["cloth"] = felt,
                ["cushion"] = EnsureMaterial("Rail", Rail, 0.45f),
                ["wood"] = EnsureMaterial("Wood", Wood, 0.30f),
            });
            return SubmeshTopY(table, felt, Bounds(table).max.y);
        }

        static void BuildChairs()
        {
            // Near side (camera) left open; two ends + two far side.
            var seats = new[] { new Vector3(-2.15f, 0f, 0f), new Vector3(2.15f, 0f, 0f), new Vector3(-0.75f, 0f, 1.45f), new Vector3(0.75f, 0f, 1.45f) };
            var cushion = EnsureMaterial("ChairCushion", ChairCushion, 0.35f);
            for (var i = 0; i < seats.Length; i++)
            {
                var chair = Instantiate("Assets/Models/FurnitureKit/chairModernCushion.obj", $"Chair {i + 1}");
                FitOnFloor(chair, 0.95f);
                chair.transform.position = new Vector3(seats[i].x, chair.transform.position.y, seats[i].z);
                // Model's backrest is on +Z (front faces -Z), so aim +Z away from the table.
                chair.transform.rotation = Quaternion.LookRotation(new Vector3(seats[i].x, 0f, seats[i].z));
                RemapMaterials(chair, new Dictionary<string, Material> { ["carpetBlue"] = cushion });
            }
        }

        static CardView[] BuildCommunitySlots(float feltTop, CardAtlas atlas, Material cardMat)
        {
            var parent = new GameObject("Community Cards").transform;
            var slots = new CardView[5];
            for (var i = 0; i < 5; i++)
            {
                var quad = CardQuad($"Slot {i + 1}", cardMat);
                quad.transform.SetParent(parent);
                quad.transform.position = new Vector3((i - 2) * (CardW + 0.05f), feltTop + 0.005f, 0.02f);
                var view = quad.AddComponent<CardView>();
                view.atlas = atlas;
                slots[i] = view;
            }
            return slots;
        }

        /// Seat 0 is the local player (open near side, camera side); the rest
        /// are for the other players. Layout keeps rows clear of each other:
        /// you z-0.45, community z0.02, chips z0.40, far seat at (-0.62, 0.52).
        static SeatView[] BuildSeats(float feltTop, CardAtlas atlas, Material cardMat)
        {
            var parent = new GameObject("Seats").transform;
            var positions = new[] { new Vector3(0f, 0f, -0.45f), new Vector3(-1.05f, 0f, 0f), new Vector3(1.05f, 0f, 0f), new Vector3(-0.62f, 0f, 0.52f) };
            var seats = new SeatView[positions.Length];
            for (var i = 0; i < positions.Length; i++)
            {
                var pos = positions[i];
                var seat = new GameObject($"Seat {i + 1}");
                seat.transform.SetParent(parent);
                seat.transform.position = new Vector3(pos.x, feltTop + 0.005f, pos.z);
                var view = seat.AddComponent<SeatView>();

                var cards = new CardView[2];
                for (var c = 0; c < 2; c++)
                {
                    var quad = CardQuad($"Card {c + 1}", cardMat);
                    quad.transform.SetParent(seat.transform);
                    var side = c == 0 ? -1f : 1f;
                    quad.transform.position = seat.transform.position + new Vector3(side * 0.10f, 0f, 0f);
                    // Fan around the table normal so the pair reads as a loose pocket hand.
                    quad.transform.rotation = Quaternion.AngleAxis(side * 8f, Vector3.up) * quad.transform.rotation;
                    cards[c] = quad.AddComponent<CardView>();
                    cards[c].atlas = atlas;
                }
                view.card1 = cards[0];
                view.card2 = cards[1];

                // Upright name label at the outer table edge, facing the camera.
                var outward = pos.sqrMagnitude > 0.001f ? pos.normalized : Vector3.back;
                var label = MakeLabel(seat.transform, "", 0.02f, Color.white);
                label.transform.rotation = Quaternion.identity;
                label.transform.position = seat.transform.position + outward * 0.35f + Vector3.up * 0.12f;
                view.nameLabel = label;
                seats[i] = view;
            }
            return seats;
        }

        static ChipView[] BuildChips(float feltTop)
        {
            var parent = new GameObject("Chips").transform;
            var body = EnsureMaterial("ChipBody", ChipBody, 0.35f);
            var stripe = EnsureMaterial("ChipStripe", Color.white, 0.35f);
            var chips = new ChipView[4];
            for (var rank = 1; rank <= 4; rank++)
            {
                var chip = Instantiate("Assets/Models/PokerPack/chip_1.obj", $"Chip {rank}");
                chip.transform.SetParent(parent);
                chip.transform.localScale = Vector3.one * 0.036f;
                // Row shifted right of center so it clears the far seat's cards.
                chip.transform.position = new Vector3(0.2f + (rank - 2.5f) * 0.28f, feltTop + 0.01f, 0.4f);
                var renderer = chip.GetComponentInChildren<MeshRenderer>();
                var mats = renderer.sharedMaterials;
                for (var m = 0; m < mats.Length; m++) mats[m] = m == 0 ? body : stripe;
                renderer.sharedMaterials = mats;
                renderer.gameObject.AddComponent<BoxCollider>(); // click target for take/steal

                var label = MakeLabel(chip.transform, $"{rank}★", 0.1f, new Color(0.15f, 0.15f, 0.18f), 8f);
                label.transform.localPosition = new Vector3(0f, 0.6f, 0f); // just above the chip top (mesh-local units)
                label.transform.localRotation = Quaternion.Euler(90f, 0f, 0f);

                var view = chip.AddComponent<ChipView>();
                view.chipRenderer = renderer;
                view.rankLabel = label;
                chips[rank - 1] = view;
            }
            return chips;
        }

        static void WireControllers(CardView[] slots, SeatView[] seats, ChipView[] chips, Transform deckAnchor)
        {
            var net = new GameObject("Game");
            var connection = net.AddComponent<GangConnection>();

            var board = net.AddComponent<CommunityBoardController>();
            board.connection = connection;
            board.slots = slots;
            board.deckAnchor = deckAnchor;

            var seatsController = net.AddComponent<PlayerSeatsController>();
            seatsController.connection = connection;
            seatsController.seats = seats;

            var chipsController = net.AddComponent<ChipsController>();
            chipsController.connection = connection;
            chipsController.chips = chips;
            chipsController.seats = seats;

            net.AddComponent<JoinBootstrap>().connection = connection;
        }

        static TextMesh MakeLabel(Transform parent, string text, float characterSize, Color color, float scale = 1f)
        {
            var label = new GameObject("Label").AddComponent<TextMesh>();
            label.transform.SetParent(parent, false);
            label.transform.localScale = Vector3.one * scale;
            var font = Resources.GetBuiltinResource<Font>("Arial.ttf");
            label.font = font;
            label.GetComponent<MeshRenderer>().sharedMaterial = font.material;
            label.anchor = TextAnchor.MiddleCenter;
            label.alignment = TextAlignment.Center;
            label.fontSize = 48;
            label.characterSize = characterSize;
            label.text = text;
            label.color = color;
            return label;
        }

        // ---- helpers ----

        static GameObject CardQuad(string name, Material mat)
        {
            var quad = GameObject.CreatePrimitive(PrimitiveType.Quad);
            quad.name = name;
            Object.DestroyImmediate(quad.GetComponent<Collider>());
            quad.transform.rotation = Quaternion.Euler(90f, 0f, 0f); // lie flat, face up
            quad.transform.localScale = new Vector3(CardW, CardH, 1f);
            quad.GetComponent<MeshRenderer>().sharedMaterial = mat;
            return quad;
        }

        static GameObject Instantiate(string assetPath, string name)
        {
            var prefab = AssetDatabase.LoadAssetAtPath<GameObject>(assetPath);
            if (prefab == null)
            {
                Debug.LogError($"GangSceneBuilder: missing asset {assetPath}");
                return new GameObject(name);
            }
            var go = (GameObject)PrefabUtility.InstantiatePrefab(prefab);
            go.name = name;
            return go;
        }

        /// Uniformly scales so total height == targetHeight and rests min.y on y=0.
        static void FitOnFloor(GameObject go, float targetHeight)
        {
            var b = Bounds(go);
            if (b.size.y > 0.0001f) go.transform.localScale *= targetHeight / b.size.y;
            b = Bounds(go);
            go.transform.position += new Vector3(0f, -b.min.y, 0f);
        }

        static Bounds Bounds(GameObject go)
        {
            var renderers = go.GetComponentsInChildren<Renderer>();
            if (renderers.Length == 0) return new Bounds(go.transform.position, Vector3.zero);
            var b = renderers[0].bounds;
            foreach (var r in renderers) b.Encapsulate(r.bounds);
            return b;
        }

        /// Highest world-space vertex of the submesh rendered with `target` —
        /// used to find the felt surface, which sits below the padded rail.
        static float SubmeshTopY(GameObject go, Material target, float fallback)
        {
            var top = float.MinValue;
            foreach (var r in go.GetComponentsInChildren<MeshRenderer>())
            {
                var filter = r.GetComponent<MeshFilter>();
                if (filter == null || filter.sharedMesh == null) continue;
                var mesh = filter.sharedMesh;
                var mats = r.sharedMaterials;
                var vertices = mesh.vertices;
                for (var s = 0; s < mesh.subMeshCount && s < mats.Length; s++)
                {
                    if (mats[s] != target) continue;
                    foreach (var index in mesh.GetTriangles(s))
                    {
                        var y = r.transform.TransformPoint(vertices[index]).y;
                        if (y > top) top = y;
                    }
                }
            }
            return top > float.MinValue ? top : fallback;
        }

        static void RemapMaterials(GameObject go, Dictionary<string, Material> byName)
        {
            foreach (var r in go.GetComponentsInChildren<MeshRenderer>())
            {
                var mats = r.sharedMaterials;
                for (var i = 0; i < mats.Length; i++)
                {
                    if (mats[i] != null && byName.TryGetValue(mats[i].name, out var replacement)) mats[i] = replacement;
                }
                r.sharedMaterials = mats;
            }
        }

        static Material EnsureMaterial(string name, Color color, float smoothness)
        {
            EnsureFolder("Assets/Materials");
            var path = $"Assets/Materials/{name}.mat";
            var mat = AssetDatabase.LoadAssetAtPath<Material>(path);
            if (mat == null)
            {
                mat = new Material(Shader.Find("Standard"));
                AssetDatabase.CreateAsset(mat, path);
            }
            mat.color = color;
            mat.SetFloat("_Glossiness", smoothness);
            return mat;
        }

        static Material EnsureCardMaterial(string name, Texture2D texture)
        {
            EnsureFolder("Assets/Materials");
            var path = $"Assets/Materials/{name}.mat";
            var mat = AssetDatabase.LoadAssetAtPath<Material>(path);
            if (mat == null)
            {
                mat = new Material(Shader.Find("Unlit/Transparent Cutout"));
                AssetDatabase.CreateAsset(mat, path);
            }
            if (texture != null) mat.mainTexture = texture;
            return mat;
        }

        static CardAtlas EnsureCardAtlas()
        {
            const string path = "Assets/CardAtlas.asset";
            var atlas = AssetDatabase.LoadAssetAtPath<CardAtlas>(path);
            if (atlas == null)
            {
                atlas = ScriptableObject.CreateInstance<CardAtlas>();
                AssetDatabase.CreateAsset(atlas, path);
            }
            var guids = AssetDatabase.FindAssets("t:Texture2D", new[] { "Assets/Textures/Cards" });
            var textures = new List<Texture2D>();
            foreach (var guid in guids)
            {
                textures.Add(AssetDatabase.LoadAssetAtPath<Texture2D>(AssetDatabase.GUIDToAssetPath(guid)));
            }
            atlas.textures = textures.ToArray();
            EditorUtility.SetDirty(atlas);
            AssetDatabase.SaveAssets();
            return atlas;
        }

        static Texture2D FindCardTexture(string name)
        {
            return AssetDatabase.LoadAssetAtPath<Texture2D>($"Assets/Textures/Cards/{name}.png");
        }

        static void EnsureFolder(string path)
        {
            if (!AssetDatabase.IsValidFolder(path))
            {
                var slash = path.LastIndexOf('/');
                AssetDatabase.CreateFolder(path.Substring(0, slash), path.Substring(slash + 1));
            }
        }
    }
}
