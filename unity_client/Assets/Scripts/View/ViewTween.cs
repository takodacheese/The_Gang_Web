using System.Collections;
using UnityEngine;

namespace TheGang.View
{
    /// Tiny coroutine tweens — enough for dealing cards and sliding chips,
    /// no animation package needed.
    public static class ViewTween
    {
        /// Smoothstep world-space move; hop > 0 adds a small arc (chip steal).
        public static IEnumerator MoveTo(Transform t, Vector3 target, float duration, float hop = 0f)
        {
            var start = t.position;
            for (float e = 0f; e < duration; e += Time.deltaTime)
            {
                var k = Mathf.Clamp01(e / duration);
                k = k * k * (3f - 2f * k);
                var p = Vector3.LerpUnclamped(start, target, k);
                p.y += Mathf.Sin(k * Mathf.PI) * hop;
                t.position = p;
                yield return null;
            }
            t.position = target;
        }
    }
}
