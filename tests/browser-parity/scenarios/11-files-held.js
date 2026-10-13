// A file chooser without a listener stays open: the snapshot shows it with
// the ref of its input, and page.fileChooser() answers it.
// oracle: skip (without a listener Playwright opens no chooser to hold)
await page.goto(`${PRIMARY}/files.html`);
await page.locator("#picker").click();
emitBree("snapshot", (await snapshot()).tree);
const c = page.fileChooser();
emitBree("multiple", c.multiple);
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "parity-"));
fs.writeFileSync(path.join(dir, "held.txt"), "held file");
await c.setFiles(path.join(dir, "held.txt"));
await page.waitForFunction(() => document.getElementById("files").textContent.startsWith("hidden-file:"));
emitBree("set", await page.locator("#files").textContent());
emitBree("answered", page.fileChooser());
await page.locator("#many").click();
emitBree("many-line", (await snapshot()).tree.split("\n")[2]);
emitBree("many-multiple", page.fileChooser().multiple);
await page.fileChooser().cancel();
emitBree("cancelled", page.fileChooser());
emitBree("unchanged", await page.locator("#files").textContent());
try {
  await c.setFiles(path.join(dir, "held.txt"));
  emitBree("answer-twice", "no error");
} catch (e) {
  emitBree("answer-twice", e.message);
}
fs.rmSync(dir, { recursive: true, force: true });
