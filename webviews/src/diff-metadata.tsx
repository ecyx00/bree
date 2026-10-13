import type { DiffViewerLabelResolver } from "./labels";

export type DiffMetadataKind = "binary" | "mode";

export function annotateDiffMetadata(fileDiff: any, patchText?: string): void {
  if (fileDiff == null || typeof fileDiff !== "object") {
    return;
  }
  const hunks = Array.isArray(fileDiff.hunks) ? fileDiff.hunks : [];
  const hasBinaryMarker = patchText != null && /(?:^|\n)(?:GIT binary patch|Binary files .* differ)(?:\n|$)/.test(patchText);
  const isParsedBinary = fileDiff.type === "change" && hunks.length === 0 &&
    typeof fileDiff.prevObjectId === "string" && typeof fileDiff.newObjectId === "string" &&
    fileDiff.prevMode == null;
  if (hasBinaryMarker || isParsedBinary) {
    fileDiff.breeDiffMetadataKind = "binary" satisfies DiffMetadataKind;
  } else if (typeof fileDiff.prevMode === "string" && typeof fileDiff.mode === "string" && fileDiff.prevMode !== fileDiff.mode) {
    fileDiff.breeDiffMetadataKind = "mode" satisfies DiffMetadataKind;
  }
}

export function resolveDiffHeaderMetadata(fileDiff: any, label: DiffViewerLabelResolver): string | undefined {
  if (fileDiff?.breeDiffMetadataKind === "binary") {
    return label("binaryFile");
  }
  if (fileDiff?.breeDiffMetadataKind === "mode") {
    return label("modeChange")
      .replace("{old}", fileDiff.prevMode ?? "")
      .replace("{new}", fileDiff.mode ?? "");
  }
  return undefined;
}

export function DiffHeaderMetadata({ fileDiff, label }: { fileDiff: any; label: DiffViewerLabelResolver }) {
  const metadata = resolveDiffHeaderMetadata(fileDiff, label);
  if (metadata == null) {
    return null;
  }
  return <span data-bree-diff-metadata={fileDiff.breeDiffMetadataKind}>{metadata}</span>;
}
