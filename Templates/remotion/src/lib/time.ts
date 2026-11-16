// recording.json uses seconds; Remotion counts frames.

export const toFrames = (seconds: number, fps: number): number =>
  Math.round(seconds * fps);

// 75 -> "1:15", 3723 -> "1:02:03"
export const clock = (seconds: number): string => {
  const total = Math.max(0, Math.floor(seconds));
  const s = String(total % 60).padStart(2, "0");
  const m = Math.floor(total / 60) % 60;
  const h = Math.floor(total / 3600);
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${s}` : `${m}:${s}`;
};
