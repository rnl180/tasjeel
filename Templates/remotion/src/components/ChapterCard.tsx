import React from "react";
import { AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { settings } from "../settings";

// A small card in the top corner when a new topic starts. It lives inside a
// <Sequence>, so frame 0 here is the moment the chapter begins.
export const ChapterCard: React.FC<{
  number: number;
  title: string;
  rightToLeft: boolean;
}> = ({ number, title, rightToLeft }) => {
  const frame = useCurrentFrame();
  const { fps, durationInFrames, width, height } = useVideoConfig();

  const slideIn = spring({ frame, fps, config: { damping: 200 }, durationInFrames: 14 });
  const fadeOut = interpolate(frame, [durationInFrames - 10, durationInFrames - 1], [1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  const short = Math.min(width, height);
  const fontSize = Math.max(16, short * 0.034);
  const away = rightToLeft ? 1 : -1;

  return (
    <AbsoluteFill
      style={{
        alignItems: rightToLeft ? "flex-end" : "flex-start",
        padding: short * 0.045,
      }}
    >
      <div
        dir={rightToLeft ? "rtl" : "ltr"}
        style={{
          display: "flex",
          alignItems: "center",
          gap: fontSize * 0.55,
          padding: `${fontSize * 0.45}px ${fontSize * 0.8}px`,
          borderRadius: fontSize * 0.6,
          backgroundColor: "rgba(12, 13, 17, 0.86)",
          color: "white",
          fontSize,
          fontWeight: 600,
          boxShadow: "0 8px 30px rgba(0, 0, 0, 0.35)",
          opacity: slideIn * fadeOut,
          transform: `translateX(${(1 - slideIn) * away * fontSize * 2}px)`,
        }}
      >
        <span
          style={{
            minWidth: fontSize * 1.5,
            height: fontSize * 1.5,
            borderRadius: fontSize,
            backgroundColor: settings.accent,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontSize: fontSize * 0.78,
            fontWeight: 700,
          }}
        >
          {number}
        </span>
        <span>{title}</span>
      </div>
    </AbsoluteFill>
  );
};
