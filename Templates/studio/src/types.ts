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

export type HookScene = {
  type: "hook";
  seconds: number;
  text: string;
  kicker: string | null;
};

export type ScreenScene = {
  type: "screen";
  seconds: number;
  // Path inside public/. Already trimmed: it starts where the scene starts.
  video: string;
  videoWidth: number;
  videoHeight: number;
  caption: string | null;
  sound: boolean;
};

export type FeatureScene = {
  type: "feature";
  seconds: number;
  headline: string;
  points: string[];
  image: string | null;
};

export type QuoteScene = {
  type: "quote";
  seconds: number;
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

export type NumbersScene = {
  type: "numbers";
  seconds: number;
  headline: string | null;
  items: NumberItem[];
};

export type CallToActionScene = {
  type: "cta";
  seconds: number;
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
  brand: Brand;
  scenes: Scene[];
};
