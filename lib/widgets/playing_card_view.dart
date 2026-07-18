import 'package:flutter/material.dart';

/// Renders a 2-char card code ("As", "Th", ...) from assets/cards/, or the
/// card back when [card] is null/empty. Face files are named
/// `<SuitLetter><Rank>.png` (SA, C10, H2, ...); the back is card_back.png.
///
/// `Jn` (the specialist-card wildcard Jack, see model.dart's
/// `_normalizeCardString`) has no real suit, so it renders as a joker.
class PlayingCardView extends StatelessWidget {
  final String? card;
  final double width;
  final double height;

  const PlayingCardView({super.key, required this.card, this.width = 60, this.height = 85});

  static const _suitLetters = {'s': 'S', 'h': 'H', 'd': 'D', 'c': 'C'};

  String _assetFor(String value) {
    final rankChar = value[0].toUpperCase();
    final suitChar = value.length > 1 ? value[1].toLowerCase() : '';
    final suitLetter = _suitLetters[suitChar];
    if (suitLetter == null) return 'assets/cards/card_joker_black.png';

    final rankStr = rankChar == 'T' ? '10' : rankChar;
    return 'assets/cards/$suitLetter$rankStr.png';
  }

  @override
  Widget build(BuildContext context) {
    final value = card?.trim();
    final asset = (value == null || value.isEmpty) ? 'assets/cards/card_back.png' : _assetFor(value);
    final radius = BorderRadius.circular(width * 0.1);
    return Container(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 5, offset: const Offset(1, 3)),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Image.asset(asset, width: width, height: height, fit: BoxFit.fill),
      ),
    );
  }
}
