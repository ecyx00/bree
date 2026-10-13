// Dialogs without a listener stay open: the snapshot shows them, page script
// calls fail with the way out, and page.dialog() answers them.
// oracle: skip (Playwright dismisses dialogs nobody listens for)
await page.goto(`${PRIMARY}/dialogs.html`);
await page.locator("#confirm").click();
emitBree("snapshot", (await snapshot()).tree);
const d = page.dialog();
emitBree("dialog", { type: d.type, message: d.message, defaultValue: d.defaultValue });
try {
  await page.locator("#r").textContent();
  emitBree("blocked", "no error");
} catch (e) {
  emitBree("blocked", e.message);
}
try {
  await page.evaluate(() => 1);
  emitBree("blocked-evaluate", "no error");
} catch (e) {
  emitBree("blocked-evaluate", e.message);
}
await d.accept();
emitBree("after-accept", await page.locator("#r").textContent());
emitBree("closed", page.dialog());
await page.locator("#prompt").click();
emitBree("prompt-line", (await snapshot()).tree.split("\n")[2]);
await page.dialog().accept("from agent");
emitBree("after-prompt", await page.locator("#r").textContent());
await page.locator("#prompt").click();
await page.dialog().dismiss();
emitBree("prompt-dismissed", await page.locator("#r").textContent());
await page.locator("#alert").focus();
await page.keyboard.press("Enter");
emitBree("keyboard-opened", page.dialog() && page.dialog().type);
await page.dialog().dismiss();
emitBree("after-alert", await page.locator("#r").textContent());
await page.evaluate(() => setTimeout(() => confirm("Later"), 50));
await page.waitForTimeout(300);
emitBree("timer-dialog", page.dialog() && page.dialog().message);
await page.dialog().dismiss();
emitBree("after-timer", (await snapshot()).tree.split("\n").length > 2);
