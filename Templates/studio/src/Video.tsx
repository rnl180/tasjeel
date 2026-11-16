import React from "react";
import { AbsoluteFill, Img, Series, staticFile, useVideoConfig } from "remotion";
import { useLayout } from "./lib/layout";
import { useExit } from "./lib/motion";
import { CallToAction } from "./scenes/CallToAction";
import { Feature } from "./scenes/Feature";
import { Hook } from "./scenes/Hook";
import { Numbers } from "./scenes/Numbers";
import { Quote } from "./scenes/Quote";
import { Screen } from "./scenes/Screen";
import { brand, fontFamily, storyboard } from "./storyboard";
import type { Scene } from "./types";

const render = (scene: Scene): React.ReactNode => {
  switch (scene.type) {
    case "hook":
      return <Hook scene={scene} />;
    case "screen":
      return <Screen scene={scene} />;
    case "feature":
      return <Feature scene={scene} />;
    case "quote":
      return <Quote scene={scene} />;
    case "numbers":
      return <Numbers scene={scene} />;
    case "cta":
      return <CallToAction scene={scene} />;
  }
};

// Every scene sits in the same frame: padding, text direction, the logo in
// the corner, and a short fade out so the cut to the next scene is soft.
const SceneFrame: React.FC<{ scene: Scene; children: React.ReactNode }> = ({ scene, children }) => {
  const { u } = useLayout();
  const exit = useExit();
  return (
    <AbsoluteFill
      dir={storyboard.rightToLeft ? "rtl" : "ltr"}
      lang={storyboard.language}
      style={{ padding: u * 7, opacity: exit }}
    >
      {children}
      {brand.logo && scene.type !== "cta" ? (
        <Img
          src={staticFile(brand.logo)}
          style={{
            position: "absolute",
            top: u * 3.5,
            insetInlineStart: u * 4,
            height: u * 5,
            opacity: 0.85,
          }}
        />
      ) : null}
    </AbsoluteFill>
  );
};

// The whole video: the storyboard's scenes, one after another.
export const StoryboardVideo: React.FC = () => {
  const { fps } = useVideoConfig();
  return (
    <AbsoluteFill style={{ backgroundColor: brand.background, color: brand.text, fontFamily }}>
      <Series>
        {storyboard.scenes.map((scene, index) => (
          <Series.Sequence
            key={index}
            name={`${index + 1}. ${scene.type}`}
            durationInFrames={Math.round(scene.seconds * fps)}
          >
            <SceneFrame scene={scene}>{render(scene)}</SceneFrame>
          </Series.Sequence>
        ))}
      </Series>
    </AbsoluteFill>
  );
};
