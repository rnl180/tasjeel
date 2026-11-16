// The shape of src/recording.json, which Tasjeel writes.
// Every time is in seconds on the clock of public/recording.mp4.

export type Caption = {
  start: number;
  end: number;
  text: string;
  // "You" is whoever made the recording, "Others" everyone else on the call.
  // null when the recording has a single sound source.
  speaker: string | null;
};

export type Chapter = {
  start: number;
  title: string;
};

export type ActionItem = {
  text: string;
  owner: string | null;
};

export type Notes = {
  summary: string;
  keyPoints: string[];
  decisions: string[];
  actionItems: ActionItem[];
};

export type Recording = {
  title: string;
  // BCP 47 tag of the spoken language, e.g. "en-US" or "ar-SA".
  language: string;
  rightToLeft: boolean;
  fps: number;
  width: number;
  height: number;
  durationInSeconds: number;
  // File name inside public/.
  video: string;
  captions: Caption[];
  chapters: Chapter[];
  notes: Notes | null;
};
