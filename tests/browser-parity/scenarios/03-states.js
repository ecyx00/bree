// States, values, tables, links and whitespace on the states fixture.
// oracle: skip (snapshot text is bree-defined)
await page.goto(`${PRIMARY}/states.html?peer=${encodeURIComponent(PEER)}`);
emitBree("full", (await snapshot()).tree);
emitBree("options", (await snapshot({ options: true })).tree.split("\n").filter((l) => /combobox|option/.test(l)));
await page.locator("#name").fill("x");
await page.locator("#name").fill("");
await page.locator("#code").focus();
emitBree("user-invalid", (await snapshot()).tree.split("\n").filter((l) => /textbox "(Name|Code)"/.test(l)));
