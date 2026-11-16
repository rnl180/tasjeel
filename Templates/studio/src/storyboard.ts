import data from "./storyboard.json";
import type { Storyboard } from "./types";

export const storyboard = data as Storyboard;
export const brand = storyboard.brand;

export const fontFamily = brand.font
  ? `"${brand.font}", system-ui, sans-serif`
  : 'system-ui, -apple-system, "SF Pro Display", "Helvetica Neue", "Geeza Pro", sans-serif';
