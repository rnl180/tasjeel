import React from "react";
import { AbsoluteFill, useCurrentFrame, useVideoConfig } from "remotion";
import { settings } from "../settings";
import type { Chapter } from "../types";

// A thin bar along the bottom that fills as the video plays, split into one
// piece per chapter.
export const ProgressBar: React.FC<{ chapters: Chapter[] }> = ({ chapters }) => {
  const frame = useCurrentFrame();
  const { fps, durationInFrames, width, height } = useVideoConfig();
  const total = durationInFrames / fps;
  const time = frame / fps;

  const starts = chapters
    .map((chapter) => chapter.start)
    .filter((start) => start > 0 && start < total);
  const edges = [0, ...starts, total];
  const thickness = Math.max(4, Math.min(width, height) * 0.009);
  const gap = thickness * 0.7;

  return (
    <AbsoluteFill style={{ justifyContent: "flex-end" }}>
      <div style={{ display: "flex", gap, height: thickness, padding: `0 ${gap}px ${gap}px` }}>
        {edges.slice(0, -1).map((start, index) => {
          const end = edges[index + 1];
          const filled = Math.min(Math.max((time - start) / (end - start), 0), 1);
          return (
            <div
              key={start}
              style={{
                flexGrow: end - start,
                flexBasis: 0,
                borderRadius: thickness,
                backgroundColor: "rgba(255, 255, 255, 0.28)",
                overflow: "hidden",
              }}
            >
              <div
                style={{
                  width: `${filled * 100}%`,
                  height: "100%",
                  backgroundColor: settings.accent,
                }}
              />
            </div>
          );
        })}
      </div>
    </AbsoluteFill>
  );
};
