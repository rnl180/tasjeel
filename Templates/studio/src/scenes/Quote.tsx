import React from "react";
import { AbsoluteFill } from "remotion";
import { fitText, useLayout } from "../lib/layout";
import { rise, useEnter } from "../lib/motion";
import { brand } from "../storyboard";
import type { QuoteScene } from "../types";

// Something a customer said, with who said it.
export const Quote: React.FC<{ scene: QuoteScene }> = ({ scene }) => {
  const { u } = useLayout();
  const mark = useEnter(0);
  const words = useEnter(5, 22);
  const who = useEnter(16);

  const fontSize = fitText(scene.quote, u * 7.2, 70);

  return (
    <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", padding: u * 11 }}>
      <div style={{ maxWidth: "100%" }}>
        <div
          style={{
            fontSize: u * 22,
            lineHeight: 0.7,
            height: u * 10,
            fontWeight: 800,
            // A serif face has the round, recognisable quotation mark.
            fontFamily: "Georgia, 'Times New Roman', serif",
            color: brand.accent,
            ...rise(mark, u * 2),
          }}
        >
          “
        </div>
        <div style={{ fontSize, fontWeight: 600, lineHeight: 1.22, ...rise(words, u * 2.5) }}>{scene.quote}</div>
        {scene.name ? (
          <div style={{ marginTop: u * 4.5, fontSize: u * 3.6, ...rise(who, u * 1.5) }}>
            <span style={{ fontWeight: 700 }}>{scene.name}</span>
            {scene.role ? <span style={{ opacity: 0.62 }}>{`  ·  ${scene.role}`}</span> : null}
          </div>
        ) : null}
      </div>
    </AbsoluteFill>
  );
};
