import { expect, test } from "bun:test";
import styles from "../src/styles.css" with { type: "text" };

test("toolbar and files pane keep structural surfaces transparent", () => {
  expect(styles).toContain("--bree-diff-toolbar-bg: transparent");
  expect(styles).toContain("--bree-diff-sidebar-bg: transparent");
  expect(styles).toMatch(/#toolbar\s*\{[^}]*border-bottom: 1px solid var\(--bree-diff-border\)[^}]*background: var\(--bree-diff-toolbar-bg\)/s);
  expect(styles).toMatch(/#toolbar\s*\{[^}]*padding: 3px 4px 3px 8px;/s);
  expect(styles).toMatch(/#files-sidebar\s*\{[^}]*background: var\(--bree-diff-sidebar-bg\)/s);
  expect(styles).toMatch(/#files-header\s*\{[^}]*border-bottom: 1px solid var\(--bree-diff-border\)[^}]*background: var\(--bree-diff-sidebar-bg\)/s);
  expect(styles).toMatch(/#file-list\s*\{[^}]*background: var\(--bree-diff-sidebar-bg\)/s);
  const rendererHostBlock = String(styles).match(/#viewer diffs-container\s*\{(?<body>[^}]*)\}/s)?.groups?.body ?? "";
  expect(rendererHostBlock).toContain("flex: 1 1 auto");
  expect(rendererHostBlock).toContain("min-height: 30px");
  expect(rendererHostBlock).not.toContain("background: var(--bree-diff-bg)");
  expect(styles).toContain("--trees-bg-override: var(--bree-diff-sidebar-bg)");
  expect(styles).toMatch(/\.toolbar-actions\s*\{[^}]*gap: 4px;/s);
  expect(styles).toMatch(/\.toolbar-icon\s*\{[^}]*width: 20px;[^}]*height: 20px;/s);
  expect(styles).toMatch(/\.toolbar-icon svg,\s*\.menu-item svg\s*\{[^}]*width: 14px;[^}]*height: 14px;/s);
  expect(styles).toMatch(/\.toolbar-icon svg,\s*\.menu-item svg\s*\{[^}]*stroke-width: 1;/s);
  expect(styles).toMatch(/#file-search-toggle svg\s*\{[^}]*stroke-width: 1;/s);
  expect(styles).not.toContain("#source-detail");
  expect(styles).not.toContain("box-shadow: 0 -1px 0 var(--bree-diff-border), 0 1px 0 var(--bree-diff-border)");
});
