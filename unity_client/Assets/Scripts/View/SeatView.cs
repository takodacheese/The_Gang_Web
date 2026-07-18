using UnityEngine;

namespace TheGang.View
{
    /// One player position on the table: name label + two pocket-card views.
    /// PlayerSeatsController fills these from snapshots.
    public class SeatView : MonoBehaviour
    {
        public CardView card1;
        public CardView card2;
        public TextMesh nameLabel;

        string _c1, _c2;

        public void SetEmpty()
        {
            gameObject.SetActive(false);
            _c1 = _c2 = null;
        }

        /// null card = face-down back (other players' hands stay hidden).
        public void SetPlayer(string displayName, string c1, string c2)
        {
            gameObject.SetActive(true);
            nameLabel.text = displayName;
            Show(card1, c1, ref _c1);
            Show(card2, c2, ref _c2);
        }

        static void Show(CardView view, string card, ref string last)
        {
            if (card == last) return;
            last = card;
            if (card == null) view.SetCard(null);
            else view.SetCardAnimated(card);
        }
    }
}
