// Renders one video per size listed in the storyboard: out/wide.mp4,
// out/square.mp4, out/tall.mp4.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const storyboard = JSON.parse(
  readFileSync(new URL("../src/storyboard.json", import.meta.url), "utf8"),
);
const compositions = { wide: "Wide", square: "Square", tall: "Tall" };

for (const format of storyboard.formats) {
  console.log(`\nRendering the ${format} version…`);
  execFileSync(
    "npx",
    ["remotion", "render", compositions[format], `out/${format}.mp4`],
    { stdio: "inherit" },
  );
}
