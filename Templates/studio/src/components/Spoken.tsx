import React from "react";
import { useCurrentFrame, useVideoConfig } from "remotion";
import { useLayout } from "../lib/layout";
import { brand } from "../storyboard";
import type { Word } from "../types";

// Splits a line of narration into short phrases to show one at a time: at a
// pause, at the end of a sentence, or after a few words.
const phrases = (words: Word[]): Word[][] => {
  const groups: Word[][] = [];
  let current: Word[] = [];
  words.forEach((word, index) => {
    current.push(word);
    const next = words[index + 1];
    const letters = current.reduce((sum, w) => sum + w.text.length + 1, 0);
    const endsSentence = /[.!?؟،,;:]$/.test(word.text);
    const pause = next ? next.start - word.end > 0.45 : true;
    if (!next || pause || (endsSentence && current.length >= 2) || current.length >= 5 || letters >= 28) {
      groups.push(current);
      current = [];
    }
  });
  return groups;
};

// The narration as captions that follow the voice: the phrase being spoken,
// with the word being said picked out. Times count from the start of the
// voice, so this sits inside the same Sequence as the sound.
export const Spoken: React.FC<{ words: Word[] }> = ({ words }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const { u, tall } = useLayout();
  const time = frame / fps;
  const groups = React.useMemo(() => phrases(words), [words]);

  // A phrase stays until the next one begins, and the last one a moment
  // after its final word.
  let current: Word[] | null = null;
  for (const group of groups) {
    if (time >= group[0].start - 0.05) {
      current = group;
    }
  }
  const end = words.length ? words[words.length - 1].end : 0;
  if (!current || time > end + 0.5) {
    return null;
  }

  return (
    <div
      style={{
        position: "absolute",
        left: 0,
        right: 0,
        // Tall videos keep the bottom clear for the buttons apps put there.
        bottom: tall ? u * 11 : u * 2.6,
        display: "flex",
        justifyContent: "center",
      }}
    >
      <div
        style={{
          display: "flex",
          flexWrap: "wrap",
          justifyContent: "center",
          columnGap: u * 0.9,
          maxWidth: "88%",
          padding: `${u * 0.8}px ${u * 2}px`,
          borderRadius: u * 1.3,
          backgroundColor: "rgba(0, 0, 0, 0.62)",
          color: "#FFFFFF",
          fontSize: u * 3.8,
          fontWeight: 700,
          lineHeight: 1.3,
        }}
      >
        {current.map((word, index) => {
          const spoken = time >= word.start;
          const active = spoken && time < word.end + 0.08;
          return (
            <span key={index} style={{ color: active ? brand.accent : "#FFFFFF", opacity: spoken ? 1 : 0.55 }}>
              {word.text}
            </span>
          );
        })}
      </div>
    </div>
  );
};
