// Hold full, drain, rest empty, then sweep back to full. Seconds, not frame counts.
export const CYCLE_SECONDS = 12;
export const PHASE_STARTS = [0, 8, 9.2];
export function allowanceAt(seconds) {
  const t = ((seconds % CYCLE_SECONDS) + CYCLE_SECONDS) % CYCLE_SECONDS;
  if (t < 1.2) return 1;
  if (t < 8) return 1 - (t - 1.2) / 6.8;
  if (t < 9.2) return 0;
  if (t < 11) {
    const p = (t - 9.2) / 1.8;
    return p * p * (3 - 2 * p);
  }
  return 1;
}
