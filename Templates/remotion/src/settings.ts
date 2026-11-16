// The quick switches. Change a value, save, and the Studio updates.

export const settings = {
  // Used for highlights, the progress bar and chapter cards.
  accent: "#8F7CFF",
  // System fonts, so nothing is downloaded. They cover Latin and Arabic.
  fontFamily:
    'system-ui, -apple-system, "SF Pro Display", "Helvetica Neue", "Geeza Pro", sans-serif',

  // The title over the first seconds of the video.
  title: { show: true, seconds: 3 },

  // The transcript, one line at a time.
  captions: {
    show: true,
    // Brighten each word as it is spoken.
    highlightWords: true,
    // Put "You" / "Others" above the line.
    showSpeaker: false,
    position: "bottom" as "bottom" | "top",
  },

  // A card that slides in when a new chapter starts.
  chapters: { show: true, seconds: 2.6 },

  // A thin bar along the bottom with a gap at every chapter.
  progress: { show: true },
};
