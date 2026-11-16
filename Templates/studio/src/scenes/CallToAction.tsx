import React from "react";
import { AbsoluteFill, Img, staticFile } from "remotion";
import { fitText, useLayout } from "../lib/layout";
import { rise, useEnter } from "../lib/motion";
import { brand } from "../storyboard";
import type { CallToActionScene } from "../types";

// The last scene: the logo, what to do next, and where to go.
export const CallToAction: React.FC<{ scene: CallToActionScene }> = ({ scene }) => {
  const { u } = useLayout();
  const logo = useEnter(0, 22);
  const words = useEnter(8);
  const link = useEnter(16);

  const fontSize = fitText(scene.text, u * 9, 26);

  return (
    <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", gap: u * 5, padding: u * 9 }}>
      {brand.logo ? (
        <Img
          src={staticFile(brand.logo)}
          style={{ height: u * 14, opacity: logo, transform: `scale(${0.8 + 0.2 * logo})` }}
        />
      ) : brand.name ? (
        <div style={{ fontSize: u * 4.5, fontWeight: 700, color: brand.accent, ...rise(logo, u * 2) }}>{brand.name}</div>
      ) : null}
      <div style={{ fontSize, fontWeight: 800, lineHeight: 1.1, textAlign: "center", ...rise(words, u * 2.5) }}>
        {scene.text}
      </div>
      {scene.link ? (
        // A web address reads left to right in every language.
        <div
          dir="ltr"
          style={{
            padding: `${u * 1.8}px ${u * 4.2}px`,
            borderRadius: u * 10,
            backgroundColor: brand.accent,
            color: "white",
            fontSize: u * 4,
            fontWeight: 700,
            ...rise(link, u * 2),
          }}
        >
          {scene.link}
        </div>
      ) : null}
    </AbsoluteFill>
  );
};
