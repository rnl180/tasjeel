import { interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";

// 0 to 1 as something arrives, starting `delay` frames into the scene.
export const useEnter = (delay = 0, frames = 18): number => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  return spring({
    frame: frame - delay,
    fps,
    config: { damping: 200 },
    durationInFrames: frames,
  });
};

// Style for text or a card that fades in while rising `distance` pixels.
export const rise = (progress: number, distance: number) => ({
  opacity: progress,
  transform: `translateY(${(1 - progress) * distance}px)`,
});

// 1 for the whole scene, dropping to 0 over its last few frames.
export const useExit = (frames = 8): number => {
  const frame = useCurrentFrame();
  const { durationInFrames } = useVideoConfig();
  return interpolate(frame, [durationInFrames - frames, durationInFrames - 1], [1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
};
