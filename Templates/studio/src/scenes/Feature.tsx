import React from "react";
import { AbsoluteFill, Img, staticFile } from "remotion";
import { fitText, useLayout } from "../lib/layout";
import { rise, useEnter } from "../lib/motion";
import { brand } from "../storyboard";
import type { FeatureScene } from "../types";

const Point: React.FC<{ text: string; index: number; size: number }> = ({ text, index, size }) => {
  const arrive = useEnter(14 + index * 7);
  return (
    <div style={{ display: "flex", alignItems: "flex-start", gap: size * 0.5, ...rise(arrive, size * 0.5) }}>
      <div
        style={{
          flexShrink: 0,
          width: size * 0.42,
          height: size * 0.42,
          marginTop: size * 0.42,
          borderRadius: size,
          backgroundColor: brand.accent,
        }}
      />
      <div style={{ fontSize: size, fontWeight: 500, lineHeight: 1.3, opacity: 0.86 }}>{text}</div>
    </div>
  );
};

// One feature: a picture with a headline and a few points. Side by side when
// the video is wide, picture on top when it is square or tall. Works without
// a picture too.
export const Feature: React.FC<{ scene: FeatureScene }> = ({ scene }) => {
  const { u, sideBySide, height } = useLayout();
  const picture = useEnter(0, 22);
  const headline = useEnter(6);

  const headlineSize = fitText(scene.headline, u * (sideBySide ? 7 : 7.6), 28);
  const pointSize = u * (sideBySide ? 3.5 : 4);
  const centred = !scene.image;

  const words = (
    <div
      style={{
        flex: sideBySide && scene.image ? "0 0 40%" : "0 0 auto",
        display: "flex",
        flexDirection: "column",
        gap: u * 2.6,
        alignItems: centred ? "center" : "stretch",
        textAlign: centred ? "center" : "start",
      }}
    >
      <div
        style={{
          fontSize: headlineSize,
          fontWeight: 800,
          lineHeight: 1.1,
          letterSpacing: -headlineSize * 0.015,
          ...rise(headline, u * 2.5),
        }}
      >
        {scene.headline}
      </div>
      {scene.points.map((point, index) => (
        <Point key={index} text={point} index={index} size={pointSize} />
      ))}
    </div>
  );

  return (
    <AbsoluteFill
      style={{
        flexDirection: sideBySide ? "row" : "column",
        justifyContent: "center",
        alignItems: "center",
        gap: u * 6,
        padding: `${u * 12}px ${u * 8}px`,
      }}
    >
      {scene.image ? (
        <div
          style={{
            // Beside the words it takes the room that is left; above them it
            // is only as tall as the picture, so the pair stays centred.
            flex: sideBySide ? "1 1 0" : "0 0 auto",
            minWidth: 0,
            maxWidth: "100%",
            display: "flex",
            justifyContent: "center",
            alignItems: "center",
            opacity: picture,
            transform: `scale(${0.95 + 0.05 * picture})`,
          }}
        >
          <Img
            src={staticFile(scene.image)}
            style={{
              maxWidth: "100%",
              maxHeight: sideBySide ? height - u * 26 : height * 0.44,
              borderRadius: u * 1.8,
              boxShadow: `0 ${u * 3}px ${u * 9}px rgba(0, 0, 0, 0.45)`,
            }}
          />
        </div>
      ) : null}
      {words}
    </AbsoluteFill>
  );
};
