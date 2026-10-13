// Closed shadow roots, top level and nested in an open root: the snapshot,
// refs and locators reach inside, as an accessibility tree does. Playwright
// does not pierce closed roots, so this scenario is bree-owned.
// oracle: skip (Playwright locators do not enter closed shadow roots)
await page.goto(`${PRIMARY}/closed-shadow.html`);
const s = await snapshot();
emitBree("full", s.tree);
const input = s.tree.match(/textbox "Closed input" \[ref=(\w+)\]/)[1];
await page.locator(input).fill("typed");
emitBree("ref-fill", await page.locator(input).inputValue());
await page.getByRole("button", { name: "Closed button" }).click();
emitBree("locator-click", await page.locator("#out").textContent());
emitBree("nested-link", await page.getByRole("link", { name: "Nested closed link" }).count());
emitBree("css-pierces", await page.locator("#ci").count());
