/// JSON helpers for games.advanced_aux (sticky steals, guesses, specialist prompts).
class AdvancedAuxState {
  AdvancedAuxState._();

  static Map<String, dynamic> decode(dynamic raw) {
    if (raw == null) return {};
    if (raw is Map<String, dynamic>) return Map<String, dynamic>.from(raw);
    if (raw is Map) return raw.map((k, v) => MapEntry(k.toString(), v));
    return {};
  }

  /// [{'phase':'FLOP','rank':1}, ...]
  static List<Map<String, dynamic>> stickyList(Map<String, dynamic> aux) {
    final raw = aux['sticky_steals'];
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((m) => {
              'phase': m['phase']?.toString() ?? '',
              'rank': (m['rank'] as num?)?.toInt() ?? 0,
            })
        .where((e) => e['phase']!.toString().isNotEmpty && (e['rank'] as int) > 0)
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  static Map<String, dynamic> withSticky(Map<String, dynamic> aux, List<Map<String, dynamic>> sticky) {
    final copy = Map<String, dynamic>.from(aux);
    copy['sticky_steals'] = sticky;
    return copy;
  }

  static bool stealForbidden(Map<String, dynamic> aux, String phase, int rank) {
    for (final e in stickyList(aux)) {
      if (e['phase'] == phase && e['rank'] == rank) return true;
    }
    return false;
  }

  static Map<String, dynamic>? retinaGuess(Map<String, dynamic> aux) {
    final r = aux['retina_rank'];
    if (r == null || r.toString().isEmpty) return null;
    return {'rank': r.toString()};
  }

  static Map<String, dynamic>? fingerprintGuess(Map<String, dynamic> aux) {
    final i = aux['fingerprint_category'];
    if (i is! num) return null;
    return {'category': i.toInt()};
  }

  static void clearForNewHand(Map<String, dynamic> target) {
    target
      ..clear()
      ..['sticky_steals'] = <dynamic>[];
  }
}
