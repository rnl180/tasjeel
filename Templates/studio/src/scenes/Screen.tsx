import { Video } from "@remotion/media";
import React from "react";
import { AbsoluteFill, staticFile } from "remotion";
import { useLayout } from "../lib/layout";
import { rise, useEnter } from "../lib/motion";
import type { ScreenScene } from "../types";

// A piece of a screen recording, shown as a floating window with an optional
// line underneath. The window is as large as the space allows while keeping
// the clip's own shape.
export const Screen: React.FC<{ scene: ScreenScene }> = ({ scene }) => {
  const { u, width, height } = useLayout();
  const arrive = useEnter(0, 22);
  const text = useEnter(10);

  const captionSize = u * 4.2;
  const captionSpace = scene.caption ? captionSize * 3.2 : 0;
  const availableWidth = width - u * 14;
  const availableHeight = height - u * 18 - captionSpace;
  const scale = Math.min(availableWidth / scene.videoWidth, availableHeight / scene.videoHeight);
  const boxWidth = scene.videoWidth * scale;
  const boxHeight = scene.videoHeight * scale;

  return (
    <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", gap: u * 3.5 }}>
      <div
        style={{
          width: boxWidth,
          height: boxHeight,
          borderRadius: u * 1.8,
          overflow: "hidden",
          boxShadow: `0 ${u * 3}px ${u * 9}px rgba(0, 0, 0, 0.45)`,
          border: "1px solid rgba(255, 255, 255, 0.14)",
          opacity: arrive,
          transform: `scale(${0.94 + 0.06 * arrive})`,
        }}
      >
        <Video
          src={staticFile(scene.video)}
          muted={!scene.sound}
          style={{ width: "100%", height: "100%", display: "block" }}
        />
      </div>
      {scene.caption ? (
        <div
          style={{
            fontSize: captionSize,
            fontWeight: 600,
            lineHeight: 1.25,
            textAlign: "center",
            maxWidth: "88%",
            ...rise(text, u * 2),
          }}
        >
          {scene.caption}
        </div>
      ) : null}
    </AbsoluteFill>
  );
};
