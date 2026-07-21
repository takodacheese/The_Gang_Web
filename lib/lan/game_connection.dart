/// The host device is the sole authority over game state (see [LanHost] in
/// lan_host.dart). Joining devices ([LanRemoteClient] in lan_remote.dart) are
/// thin terminals: they render whatever the host broadcasts and send intents
/// back. game_screen.dart / main.dart only ever talk to this interface.
abstract class GameConnection {
  Stream<Map<String, dynamic>> get gameStream;
  Stream<List<Map<String, dynamic>>> get playersStream;

  Map<String, dynamic> get currentGame;
  List<Map<String, dynamic>> get currentPlayers;

  /// Guest-triggerable: any seated player may call these on their turn.
  void takeChip(String actingUserId, int rank, String phase);
  void stealChip(String actingUserId, int rank, String phase, String victimUserId);

  /// Any player, any time: flash a speech-bubble phrase at their seat.
  void sendEmote(String userId, String text);

  /// Group vote ("circle of choice"): pick an option / confirm the agreement.
  void castVote(String userId, String option);
  void confirmVote(String userId);

  /// Host-only: remove a (disconnected) player; mid-heist this redeals.
  void kickPlayer(String actingUserId, String targetUserId);

  /// Host-only: the UI only ever renders the controls that call these on the
  /// host's own [GameConnection] instance, so remote implementations are no-ops.
  void dealInitialCards();
  void resolveRetinaGuess(String rank);
  void resolveFingerprintGuess(int categoryIndex);
  void triggerVerdict();
  void setInvestorClaims(Map<String, int> claims);
  void setMathWhizClaims(Map<String, int> claims);
  void setMastermindClaim(String playerId, String rank, int count);

  void dispose();
}
