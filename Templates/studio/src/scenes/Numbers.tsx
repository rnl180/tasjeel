import React from "react";
import { AbsoluteFill, Easing, interpolate, useCurrentFrame, useVideoConfig } from "remotion";
import { fitText, useLayout } from "../lib/layout";
import { rise, useEnter } from "../lib/motion";
import { brand } from "../storyboard";
import type { NumberItem, NumbersScene } from "../types";

const Figure: React.FC<{ item: NumberItem; index: number; size: number }> = ({ item, index, size }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const delay = 8 + index * 8;
  const arrive = useEnter(delay);

  // Count up to the value over about a second, slowing as it gets there.
  const counted = interpolate(frame, [delay, delay + fps * 1.1], [0, item.value], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.out(Easing.cubic),
  });
  // Show as many decimal places as the value itself has.
  const decimals = (String(item.value).split(".")[1] ?? "").length;

  return (
    <div style={{ textAlign: "center", ...rise(arrive, size * 0.25) }}>
      {/* Figures read left to right in every language. */}
      <div
        dir="ltr"
        style={{ fontSize: size, fontWeight: 800, lineHeight: 1, fontVariantNumeric: "tabular-nums", whiteSpace: "pre" }}
      >
        <span style={{ color: brand.accent }}>{item.prefix}</span>
        {counted.toFixed(decimals)}
        <span style={{ color: brand.accent }}>{item.suffix}</span>
      </div>
      {item.label ? (
        <div style={{ marginTop: size * 0.16, fontSize: size * 0.22, fontWeight: 500, opacity: 0.7 }}>{item.label}</div>
      ) : null}
    </div>
  );
};

// One to three figures that count up, with an optional line above them.
export const Numbers: React.FC<{ scene: NumbersScene }> = ({ scene }) => {
  const { u, tall, sideBySide } = useLayout();
  const headline = useEnter(0);
  const count = scene.items.length;
  // Fewer figures, or more room, means bigger type.
  const size = u * (tall ? 20 : sideBySide ? (count === 1 ? 30 : 17) : count === 1 ? 26 : 13);

  return (
    <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", gap: u * 8, padding: u * 8 }}>
      {scene.headline ? (
        <div
          style={{
            fontSize: fitText(scene.headline, u * 5.2, 36),
            fontWeight: 700,
            textAlign: "center",
            ...rise(headline, u * 2),
          }}
        >
          {scene.headline}
        </div>
      ) : null}
      <div
        style={{
          display: "flex",
          flexDirection: tall ? "column" : "row",
          justifyContent: "center",
          // Top-aligned, so a label that wraps does not push its figure up.
          alignItems: tall ? "center" : "flex-start",
          gap: tall ? u * 8 : u * (sideBySide ? 10 : 7),
        }}
      >
        {scene.items.map((item, index) => (
          <Figure key={index} item={item} index={index} size={size} />
        ))}
      </div>
    </AbsoluteFill>
  );
};
