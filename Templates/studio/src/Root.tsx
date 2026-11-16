import React from "react";
import { Composition } from "remotion";
import { storyboard } from "./storyboard";
import { StoryboardVideo } from "./Video";

// One composition per size. They share every scene; the scenes lay
// themselves out to fit.
const sizes = [
  { id: "Wide", width: 1920, height: 1080 },
  { id: "Square", width: 1080, height: 1080 },
  { id: "Tall", width: 1080, height: 1920 },
];

export const RemotionRoot: React.FC = () => {
  const frames = storyboard.scenes.reduce(
    (sum, scene) => sum + Math.round(scene.seconds * storyboard.fps),
    0,
  );
  return (
    <>
      {sizes.map((size) => (
        <Composition
          key={size.id}
          id={size.id}
          component={StoryboardVideo}
          durationInFrames={Math.max(1, frames)}
          fps={storyboard.fps}
          width={size.width}
          height={size.height}
        />
      ))}
    </>
  );
};
