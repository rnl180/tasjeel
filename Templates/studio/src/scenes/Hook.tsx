import React from "react";
import { AbsoluteFill, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { fitText, useLayout } from "../lib/layout";
import { rise, useEnter } from "../lib/motion";
import { brand } from "../storyboard";
import type { HookScene } from "../types";

// The opening line. One big sentence whose words rise in one after another,
// with an optional small line above it.
export const Hook: React.FC<{ scene: HookScene }> = ({ scene }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const { u, tall } = useLayout();
  const kicker = useEnter(0);
  const bar = useEnter(4, 24);

  const words = scene.text.split(/\s+/).filter(Boolean);
  const fontSize = fitText(scene.text, u * (tall ? 11 : 12.5), 30);

  return (
    <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", padding: u * 9 }}>
      <div style={{ textAlign: "center", maxWidth: "100%" }}>
        {scene.kicker ? (
          <div
            style={{
              fontSize: u * 3.4,
              fontWeight: 700,
              letterSpacing: u * 0.12,
              color: brand.accent,
              marginBottom: u * 3,
              ...rise(kicker, u * 2),
            }}
          >
            {scene.kicker}
          </div>
        ) : null}
        <div style={{ fontSize, fontWeight: 800, lineHeight: 1.08, letterSpacing: -fontSize * 0.02 }}>
          {words.map((word, index) => {
            const arrive = spring({
              frame: frame - 6 - index * 3,
              fps,
              config: { damping: 200 },
              durationInFrames: 16,
            });
            return (
              <span
                key={index}
                style={{ display: "inline-block", whiteSpace: "pre", ...rise(arrive, fontSize * 0.45) }}
              >
                {word}
                {index < words.length - 1 ? " " : ""}
              </span>
            );
          })}
        </div>
        <div
          style={{
            width: u * 16 * bar,
            height: u * 1,
            borderRadius: u,
            backgroundColor: brand.accent,
            margin: `${u * 4.5}px auto 0`,
          }}
        />
      </div>
    </AbsoluteFill>
  );
};
