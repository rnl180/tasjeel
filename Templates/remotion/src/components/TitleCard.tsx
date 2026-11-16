import React from "react";
import { AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { clock } from "../lib/time";
import { settings } from "../settings";
import type { Recording } from "../types";

// The opening: the recording dims and its title rises in, then both clear.
export const TitleCard: React.FC<{ recording: Recording }> = ({ recording }) => {
  const frame = useCurrentFrame();
  const { fps, durationInFrames, width, height } = useVideoConfig();

  const rise = spring({ frame, fps, config: { damping: 200 }, durationInFrames: 18 });
  const fadeOut = interpolate(frame, [durationInFrames - 14, durationInFrames - 1], [1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  const short = Math.min(width, height);
  const fontSize = Math.max(28, short * 0.075);
  const chapters = recording.chapters.length;
  const details = [
    clock(recording.durationInSeconds),
    chapters > 1 ? `${chapters} chapters` : null,
  ].filter(Boolean);

  return (
    <AbsoluteFill
      style={{
        backgroundColor: `rgba(8, 9, 13, ${0.72 * fadeOut})`,
        justifyContent: "center",
        alignItems: "center",
        padding: short * 0.1,
      }}
    >
      <div
        dir={recording.rightToLeft ? "rtl" : "ltr"}
        style={{
          textAlign: "center",
          color: "white",
          opacity: rise * fadeOut,
          transform: `translateY(${(1 - rise) * fontSize * 0.6}px)`,
        }}
      >
        <div
          style={{
            width: fontSize * 1.2,
            height: fontSize * 0.12,
            borderRadius: fontSize,
            backgroundColor: settings.accent,
            margin: `0 auto ${fontSize * 0.45}px`,
          }}
        />
        <div style={{ fontSize, fontWeight: 700, lineHeight: 1.15, letterSpacing: -0.5 }}>
          {recording.title}
        </div>
        {/* Length and chapter count are written in English, so left to right. */}
        <div
          dir="ltr"
          style={{
            marginTop: fontSize * 0.35,
            fontSize: fontSize * 0.34,
            fontWeight: 500,
            color: "rgba(255, 255, 255, 0.66)",
          }}
        >
          {details.join("  ·  ")}
        </div>
      </div>
    </AbsoluteFill>
  );
};
