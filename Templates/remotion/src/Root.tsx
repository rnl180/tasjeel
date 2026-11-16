import React from "react";
import { Composition } from "remotion";
import data from "./recording.json";
import { toFrames } from "./lib/time";
import type { Recording } from "./types";
import { RecordingVideo } from "./Video";

const recording = data as Recording;

export const RemotionRoot: React.FC = () => {
  return (
    <Composition
      id="Recording"
      component={RecordingVideo}
      durationInFrames={Math.max(1, toFrames(recording.durationInSeconds, recording.fps))}
      fps={recording.fps}
      width={recording.width}
      height={recording.height}
      defaultProps={{ recording }}
    />
  );
};
