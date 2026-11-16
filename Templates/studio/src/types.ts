// The shape of src/storyboard.json, which Tasjeel writes from the storyboard
// you gave it. Tasjeel has already checked it, filled in the defaults, copied
// the media into public/media and trimmed each clip to the part that is used.

export type Format = "wide" | "square" | "tall";

export type Brand = {
  name: string | null;
  // Path inside public/, or null.
  logo: string | null;
  background: string;
  text: string;
  accent: string;
  // A CSS font-family, or null for the system font.
  font: string | null;
};

// One spoken word and when it is heard, in seconds from the start of the voice.
export type Word = {
  text: string;
  start: number;
  end: number;
};

// What every scene has, whatever its kind.
type Timed = {
  // How long the scene lasts. Already long enough for its narration.
  seconds: number;
  // What the narrator says, or null.
  say: string | null;
  // The narration as sound: a path inside public/, or null when the video
  // was built without a voiceover.
  voice: string | null;
  voiceSeconds: number;
  // The narration's words with their timing, for captions. Empty without a voice.
  words: Word[];
};

export type HookScene = Timed & {
  type: "hook";
  text: string;
  kicker: string | null;
};

export type ScreenScene = Timed & {
  type: "screen";
  // Path inside public/. Already trimmed: it starts where the scene starts.
  video: string;
  videoWidth: number;
  videoHeight: number;
  caption: string | null;
  sound: boolean;
};

export type FeatureScene = Timed & {
  type: "feature";
  headline: string;
  points: string[];
  image: string | null;
};

export type QuoteScene = Timed & {
  type: "quote";
  quote: string;
  name: string | null;
  role: string | null;
};

export type NumberItem = {
  value: number;
  prefix: string;
  suffix: string;
  label: string;
};

export type NumbersScene = Timed & {
  type: "numbers";
  headline: string | null;
  items: NumberItem[];
};

export type CallToActionScene = Timed & {
  type: "cta";
  text: string;
  link: string | null;
};

export type Scene =
  | HookScene
  | ScreenScene
  | FeatureScene
  | QuoteScene
  | NumbersScene
  | CallToActionScene;

export type Storyboard = {
  version: number;
  title: string;
  language: string;
  rightToLeft: boolean;
  fps: number;
  formats: Format[];
  // Whether the narration is also shown as captions.
  captions: boolean;
  // Seconds of quiet before a scene's narration starts.
  voiceLeadIn: number;
  brand: Brand;
  scenes: Scene[];
};
