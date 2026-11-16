import { Video } from "@remotion/media";
import React from "react";
import { AbsoluteFill, Sequence, staticFile, useVideoConfig } from "remotion";
import { Captions } from "./components/Captions";
import { ChapterCard } from "./components/ChapterCard";
import { ProgressBar } from "./components/ProgressBar";
import { TitleCard } from "./components/TitleCard";
import { toFrames } from "./lib/time";
import { settings } from "./settings";
import type { Recording } from "./types";

export type RecordingVideoProps = {
  recording: Recording;
};

// The whole video: the recording from Tasjeel with graphics layered on top.
// Tasjeel has already applied the cuts, zooms, wallpaper and camera, so
// everything here is an overlay. Layers are drawn in order, last on top.
export const RecordingVideo: React.FC<RecordingVideoProps> = ({ recording }) => {
  const { fps, durationInFrames } = useVideoConfig();
  const titleFrames = settings.title.show ? toFrames(settings.title.seconds, fps) : 0;

  return (
    <AbsoluteFill
      style={{ backgroundColor: "black", fontFamily: settings.fontFamily }}
      lang={recording.language}
    >
      <Video
        src={staticFile(recording.video)}
        style={{ width: "100%", height: "100%" }}
      />

      {settings.progress.show ? <ProgressBar chapters={recording.chapters} /> : null}

      {settings.captions.show ? (
        <Captions captions={recording.captions} rightToLeft={recording.rightToLeft} />
      ) : null}

      {settings.chapters.show
        ? recording.chapters.map((chapter, index) => {
            const from = toFrames(chapter.start, fps);
            // The title card already introduces the first chapter.
            if (from < titleFrames || from >= durationInFrames) {
              return null;
            }
            return (
              <Sequence
                key={`${index}-${chapter.start}`}
                name={`Chapter: ${chapter.title}`}
                from={from}
                durationInFrames={toFrames(settings.chapters.seconds, fps)}
                layout="none"
              >
                <ChapterCard
                  number={index + 1}
                  title={chapter.title}
                  rightToLeft={recording.rightToLeft}
                />
              </Sequence>
            );
          })
        : null}

      {titleFrames > 0 ? (
        <Sequence name="Title" durationInFrames={titleFrames} layout="none">
          <TitleCard recording={recording} />
        </Sequence>
      ) : null}
    </AbsoluteFill>
  );
};
