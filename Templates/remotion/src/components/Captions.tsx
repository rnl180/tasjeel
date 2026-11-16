import React from "react";
import { AbsoluteFill, interpolate, useCurrentFrame, useVideoConfig } from "remotion";
import { settings } from "../settings";
import type { Caption } from "../types";

// Shows the line being spoken. Each line rises into place, and (optionally)
// its words brighten one by one as they are said.
export const Captions: React.FC<{
  captions: Caption[];
  rightToLeft: boolean;
}> = ({ captions, rightToLeft }) => {
  const frame = useCurrentFrame();
  const { fps, height, width } = useVideoConfig();
  const time = frame / fps;

  const caption = captions.find((c) => time >= c.start && time < c.end);
  if (!caption) {
    return null;
  }

  const sinceStart = time - caption.start;
  const enter = interpolate(sinceStart, [0, 0.18], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  // Tasjeel knows when each line starts and ends, not each word, so words
  // are timed by their share of the line's letters.
  const words = caption.text.split(/\s+/).filter(Boolean);
  const letters = words.reduce((sum, word) => sum + word.length, 0) || 1;
  const duration = Math.max(caption.end - caption.start, 0.2);
  let spoken = 0;

  const short = Math.min(width, height);
  const fontSize = Math.max(18, short * 0.042);
  const top = settings.captions.position === "top";

  return (
    <AbsoluteFill
      style={{
        justifyContent: top ? "flex-start" : "flex-end",
        alignItems: "center",
        padding: short * 0.06,
        // Leave room for the progress bar.
        paddingBottom: short * 0.075,
      }}
    >
      <div
        dir={rightToLeft ? "rtl" : "ltr"}
        style={{
          maxWidth: "84%",
          padding: `${fontSize * 0.42}px ${fontSize * 0.7}px`,
          borderRadius: fontSize * 0.5,
          backgroundColor: "rgba(0, 0, 0, 0.68)",
          color: "white",
          fontSize,
          fontWeight: 600,
          lineHeight: 1.3,
          textAlign: "center",
          opacity: enter,
          transform: `translateY(${(1 - enter) * fontSize * 0.5}px)`,
        }}
      >
        {settings.captions.showSpeaker && caption.speaker ? (
          <div
            style={{
              fontSize: fontSize * 0.5,
              fontWeight: 700,
              color: settings.accent,
              marginBottom: fontSize * 0.1,
            }}
          >
            {caption.speaker}
          </div>
        ) : null}
        {words.map((word, index) => {
          const startsAt = (spoken / letters) * duration;
          spoken += word.length;
          const said = !settings.captions.highlightWords || sinceStart >= startsAt;
          return (
            <span key={index} style={{ opacity: said ? 1 : 0.5 }}>
              {word}
              {index < words.length - 1 ? " " : ""}
            </span>
          );
        })}
      </div>
    </AbsoluteFill>
  );
};
