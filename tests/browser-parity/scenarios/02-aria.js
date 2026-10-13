// Roles, names, states and visibility on the ARIA fixture.
// oracle: skip (snapshot text is bree-defined)
await page.goto(`${PRIMARY}/aria.html`);
emitBree("full", (await snapshot()).tree);
emitBree("interactive", (await snapshot({ interactive: true })).tree);
emitBree("show-hidden", (await snapshot({ showHidden: true })).tree);
