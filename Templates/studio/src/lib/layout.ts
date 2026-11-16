import { useVideoConfig } from "remotion";

// The same scenes are rendered wide (16:9), square and tall (9:16), so
// nothing is sized in fixed pixels. `u` is one hundredth of the short side:
// a 1080-pixel-high video has u = 10.8.
export const useLayout = () => {
  const { width, height } = useVideoConfig();
  const short = Math.min(width, height);
  return {
    width,
    height,
    u: short / 100,
    // Wide lays things out side by side; square and tall stack them.
    sideBySide: width / height > 1.2,
    tall: height / width > 1.2,
  };
};

// Shrinks type as the text gets longer, so a long line still fits.
export const fitText = (text: string, base: number, comfortable: number): number => {
  if (text.length <= comfortable) {
    return base;
  }
  return base * Math.max(0.55, Math.sqrt(comfortable / text.length));
};
