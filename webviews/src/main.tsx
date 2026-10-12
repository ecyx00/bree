const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Missing cmux webview root");
}

// The diff viewer is the only surface; load it as its own chunk so the
// `@pierre/diffs` vendor code stays out of the entry bundle.
void import("./surfaces/diffSurface").then((surface) => {
  surface.mountDiffSurface(rootElement);
});
