using UnityEngine;

namespace TheGang.View
{
    /// Attach to the chip_1 mesh (Assets/Models/PokerPack/chip_1.obj) to tint it per
    /// round phase and show the star rank — same colors and "dark side" lock look
    /// as game_screen.dart's `_roundChipFace`/`_chipBaseColorForPhase`.
    public class ChipView : MonoBehaviour
    {
        public MeshRenderer chipRenderer;
        public TextMesh rankLabel;

        static readonly Color PreFlop = new Color32(0xF5, 0xF5, 0xF5, 0xFF); // Colors.grey.shade100
        static readonly Color Flop = new Color32(0xFF, 0xB3, 0x00, 0xFF);    // Colors.amber.shade600
        static readonly Color Turn = new Color32(0xFF, 0x70, 0x43, 0xFF);    // Colors.deepOrange.shade400
        static readonly Color River = new Color32(0xE5, 0x39, 0x35, 0xFF);   // Colors.red.shade600
        static readonly Color Locked = new Color32(0x2B, 0x2B, 0x2B, 0xFF);

        public void SetPhase(string phase, int rank, bool locked = false)
        {
            chipRenderer.material.color = locked ? Locked : ColorForPhase(phase);
            if (rankLabel != null) rankLabel.text = $"{rank}★";
        }

        static Color ColorForPhase(string phase)
        {
            switch (phase)
            {
                case "PRE_FLOP": return PreFlop;
                case "FLOP": return Flop;
                case "TURN": return Turn;
                case "RIVER": return River;
                default: return Color.grey;
            }
        }
    }
}
