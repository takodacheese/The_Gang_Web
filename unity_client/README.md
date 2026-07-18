# Unity client (guest-only, for now)

Talks to the same LAN protocol as `lib/lan/lan_host.dart` / `lan_remote.dart`
in the Flutter project. The Flutter app stays the authoritative host/server;
this is purely a visual client that joins as a guest.

## Setup

1. Create the Unity project itself (Unity Hub — the Editor download shown as
   in-progress on this machine, 2020.3.0f1 with Android modules, needs to
   finish first).
2. Copy `Assets/Scripts/Net/GangConnection.cs` into the new project's `Assets/`.
3. Window > Package Manager > **Add package by name** > `com.unity.nuget.newtonsoft-json`
   (needed for `JObject`/`JArray` — the wire format is free-form JSON, and
   Unity's built-in `JsonUtility` can't parse that without fixed C# classes).
4. Attach `GangConnection` to any always-alive GameObject (e.g. a
   `NetworkManager` empty), then:

   ```csharp
   var conn = GetComponent<GangConnection>();
   conn.OnGameSnapshot += game => { /* game["status"], game["community_cards"], ... */ };
   conn.OnPlayersSnapshot += players => { /* each has user_id, display_name, hand_cards, claim_preflop, ... */ };
   await conn.DiscoverAndJoin(roomCode: "1234", userId: myUserId, displayName: "Alice");
   ```

## What this does NOT do yet

- **No host mode.** Unity can only join a room someone else (Flutter) already
  created — confirmed as the intended design, not a gap. If that ever changes,
  it means porting `LanHost`'s HttpServer/WebSocket server + UDP discovery
  responder to C#.
- **No specialist/challenge card UI.** Core play works (join, see your hand,
  community cards deal with animation, click chips to take/steal with the
  host validating) — but advanced-mode specialist/challenge cards, locked
  ("dark side") chip states, and the vault/alarm verdict display are only in
  the Flutter client.
- **No reconnect/retry logic** — matches the Flutter `LanRemoteClient`, which
  also doesn't have any (a dropped connection just goes to `OnError` and stays
  dropped).

## Scene builder

`Assets/Editor/GangSceneBuilder.cs` assembles the whole table scene in one
click — no manual dragging needed:

- **Tools > The Gang > Build Table Scene** — creates and saves
  `Assets/Scenes/Table.unity`: angled camera, key/fill lights, the poker table
  (felt/rail/wood materials), 4 Kenney chairs, 5 community-card quads with
  `CardView`, per-seat pocket card backs, 4 star-rank chips with `ChipView`,
  and a `GangConnection` + `CommunityBoardController` + `JoinBootstrap` (an
  IMGUI room-code/name overlay that calls `DiscoverAndJoin` and hides itself
  once connected) wired to the slots. The scene is also registered in Build
  Settings, so standalone builds open it. It
  also creates `Assets/CardAtlas.asset` and auto-fills its textures. Safe to
  re-run; it reuses the material/atlas assets it made before.
- **Tools > The Gang > Save Scene Preview** — renders that scene through the
  Main Camera to `table_preview.png` (project root) without entering play
  mode. Both also work headlessly:
  `Unity.exe -batchmode -quit -projectPath . -executeMethod TheGang.EditorTools.GangSceneBuilder.Build`

`Assets/Models/FurnitureKit/` — chair from **Kenney's Furniture Kit,
kenney.nl, CC0** (License.txt included).

## Art assets included

`Assets/Models/PokerPack/` — table + one chip mesh, from **"Poker Pack" by
mehrasaur, opengameart.org/content/poker-pack, CC0** (public domain, no
attribution required). Low-poly: table is 424 tris, the chip ~20.

Two things I fixed before copying them in:
- The plain OBJ/MTL export loses Blender's actual material colors (they come
  through as flat default grey) — `table.mtl`'s felt/wood/rail colors and
  `chip_1.mtl`'s two materials were repainted to sensible values by hand,
  matching the pack's own preview render.
- The pack's `card.obj` has **no UV coordinates at all** (checked — zero `vt`
  lines) and there's no Blender install here to re-unwrap it. Rather than
  fight that, use Unity's built-in **Quad** primitive for cards instead: it
  already ships with correct UVs, and our card art (`Assets/Textures/Cards/`,
  the same Kenney CC0 art the Flutter app uses) already has rounded corners
  baked into the PNG's alpha channel — an Unlit/Transparent-Cutout material on
  a plain quad reads as a rounded card with zero custom geometry needed.

`Assets/Textures/Cards/` — the 54 card PNGs (52 ranks + back + joker), copied
from `the_gang/assets/cards/`. `Assets/Textures/chip_base.png` — copied from
`the_gang/assets/chips/` for the same reason.

## Chip color

Only `chip_1` was fixed/copied — the pack has 11 (one per poker denomination,
$1/$5/$10/.../$10000), but this game doesn't use denominations, it uses our
own 4 phase colors (white/amber/orange/red — same `_chipBaseColorForPhase`
values as the Flutter app). Rather than track down 11 exact colors we don't
need, tint that one mesh at runtime the same way the Flutter side tints
`chip_base.png`: set the material's color (Standard shader Albedo tint, or
`MeshRenderer.material.color` on an Unlit/Color shader) to the phase color —
multiplying a light-grey base by a tint color reproduces it, same trick as
Flutter's `ColorFiltered`/`BlendMode.modulate`.

## View scripts (`Assets/Scripts/View/`)

Project now has `ProjectSettings`/`Library` (opened once via `Unity.exe
-projectPath`), and these are written but not yet wired into a scene:

- `CardAtlas` (ScriptableObject) — created and auto-filled with all 54 PNGs by
  the scene builder (manual fallback: Create > The Gang > Card Atlas, then drag
  the textures in).
- `CardView` — put on a Quad (Unlit/Transparent Cutout material, per the note
  above) with its `atlas` field pointing at that asset. `SetCard("As")` swaps
  the quad's texture; `SetCard(null)` shows the back. Mapping matches
  `playing_card_view.dart`'s `_assetFor` exactly.
- `ChipView` — put on the `chip_1` mesh instance, wire `chipRenderer` to its
  own `MeshRenderer` and (optionally) a child `TextMesh` to `rankLabel`.
  `SetPhase("FLOP", rank: 2)` tints + labels it; colors match
  `_chipBaseColorForPhase` in `game_screen.dart`.
- `CommunityBoardController` — drives the 5 board slots from snapshots (same
  phase map as `_buildCommunityCards`). Newly revealed cards fly in from the
  deck anchor and flip over (`ViewTween` + `CardView.FlipTo`).
- `PlayerSeatsController` + `SeatView` — fills the 4 seats from player
  snapshots: name labels, your own pocket cards face up (with a flip when
  dealt), everyone else's as backs. You always sit at the open near side.
- `ChipsController` — moves the 4 star chips between the center row and the
  holders' seats (animated slide with a hop) based on `claim_*` fields, and
  handles clicks: unclaimed chip = take, someone else's = steal. The host
  validates turn order and challenge rules, so bad clicks are just ignored.
- `JoinBootstrap` — the IMGUI room-code overlay described above.
