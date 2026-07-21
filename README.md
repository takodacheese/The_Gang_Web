# The Gang — Web Edition
run it online- https://the-gang-web.onrender.com/
A browser-based, co-operative heist card game for 2–7 players. One player hosts
a room, friends join with a 4-digit code from any device with a browser
(desktop, Android, iOS — nothing to install), and the whole crew wins or loses
together.

It plays like Texas Hold'em with a twist: **you never bet and never talk about
your cards**. Instead, each betting round you claim a numbered star chip that
says *"this is how strong I think my final hand will be compared to yours."*
If, at the showdown, the crew ranked itself correctly, the vault opens and the
heist succeeds. Three successful heists win the campaign; three failed heists
end it.

## Features

- **Zero-install multiplayer** — one tiny server process relays JSON between
  browsers; the host player's browser tab runs all game logic.
- **Poker table UI** — players seated around a virtual table, animated card
  dealing, chips that fly between the table and player seats, speech bubbles.
- **Advanced mode** — the original game's 10 challenge cards and 10 specialist
  cards, with a shared "circle of choice" voting wheel so the whole group
  (not just the host) makes the decisions the rulebook asks for.
- **Game modes** — Classic, Advanced (cards in order 1→10), Advanced Random,
  and a Custom testing mode where you pick exactly which cards trigger.
- **In-game rules reference**, adjustable text size, and adjustable card size.

## Built with

| Tool | Used for |
|------|----------|
| [Flutter](https://flutter.dev) (Dart) | The entire game client, compiled to a static web app |
| Dart (`dart:io`, no packages) | `relay/relay_server.dart` — WebSocket relay + static file server, the whole backend in one file |
| `web_socket_channel` | Browser-compatible WebSocket transport in the client |
| Custom pure-Dart hand evaluator | `lib/hand_eval.dart` — poker hand ranking that compiles to JavaScript (the `poker` package uses 64-bit ints and can't) |
| `flutter_test` | Unit + end-to-end tests, including a real relay process spawned in the integration test |
| Card art | Classic public-domain playing card faces (assets/cards) |



## Run it

```
flutter build web --no-web-resources-cdn
dart run relay/relay_server.dart        # serves http://localhost:8080  (PORT env to change)
```

One process is the whole deployment: the relay serves the built site as static
files and forwards game traffic between browsers. Rooms live in memory — no
database. To play over the internet, run those two artifacts (`relay_server`
+ `build/web/`) on any machine with a public address; a free-tier
Render/Fly/Railway instance is plenty.

The host player's browser is authoritative (`lib/lan/game_engine.dart`) and
must stay open; if the host closes their tab the room ends.

## How to play

1. Everyone opens the site. One player enters a name, picks a game mode, and
   **Create Room** — they get a 4-digit code. Others **Join Room** with it.
   A game that has dealt its first hand is closed to new players.
2. Each heist is one hand of Hold'em over four rounds — pocket cards
   (**White** chips), flop (**Yellow**), turn (**Orange**), river (**Red**).
3. Every round, in seat order, each player takes a star chip from the center
   **or steals one from another player** (tap the chip under their seat).
   Higher stars = claiming a stronger final hand. Chips are the only
   communication allowed — never talk about, hint at, or reveal your cards.
4. **Showdown**: hands are revealed after the host resolves. The heist
   succeeds if the highest red chip is held by the strongest hand
   (house rule — the original game checks the entire red-chip ordering).
5. **Campaign**: win 3 heists before losing 3. After the campaign ends, the
   host can start a new one with the same table.

### Advanced mode

After a **won** heist, a **challenge card** makes the next heist harder.
After a **lost** heist, a **specialist card** helps you. Each card lasts one
heist, and its rule is announced to everyone when the hand is dealt.

- Challenges include: skipped chip rounds (Quick Access, Hasty Getaway),
  locked "dark side" chips (Noise Sensors, Ventilation Shaft), forced
  redraws (Motion Detector, Laser Tripwires), discarding old chips
  (Blackout), 3-card pockets (Security Cameras), and two group-guess
  challenges — **Retina Scan** (guess a card value in the top player's hand)
  and **Fingerprint Scan** (guess their hand ranking). A wrong or missing
  guess fails the heist even when the chips were right.
- Specialists include revealing partial information (Informant, Getaway
  Driver, Investor, Mastermind, Math Whiz), card manipulation (Hacker,
  Coordinator, Jack, Con Artist), and tie-breaking (Muscle).
- Group decisions — who uses a specialist, what value to guess — are made on
  the shared **circle of choice**: everyone ticks an option, picks are shown
  live with name tags, and the confirm button unlocks only when the whole
  group agrees.


## Disclaimer

This project is a **non-commercial study of the rules of the card game
"The Gang"** — a fan-made digital adaptation built for learning purposes
(game-rule modeling, real-time multiplayer architecture, and Flutter web
development).

"The Gang" was designed by **John Cooper and Kory Heath** and published by
**KOSMOS**. All rights to the original game. This project is not affiliated with,
endorsed by, or sponsored by the designers or publisher, reimplements the
rules from a personal reading of the public rulebook (with noted house-rule
deviations), and uses no assets from the original product. If you enjoy this
adaptation, please support the designers and publisher by buying the physical
game.
