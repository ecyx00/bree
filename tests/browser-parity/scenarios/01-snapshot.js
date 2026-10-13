// Snapshot format on the form fixture: header, full tree, interactive tree,
// scoping by ref and by locator, combobox options, and the maxChars print budget.
// oracle: skip (snapshot text is bree-defined)
await page.goto(`${PRIMARY}/`);
const s1 = await snapshot();
emitBree("full", s1.tree);
emitBree("prints-tree-first", String(s1) === s1.tree);
emitBree("interactive", (await snapshot({ interactive: true })).tree);
const nav = s1.tree.match(/navigation "Main" \[ref=(\w+)\]/)[1];
emitBree("scoped-ref", (await snapshot(nav)).tree);
emitBree("scoped-locator", (await snapshot(page.locator("form"))).tree);
emitBree("options", (await snapshot({ options: true })).tree.split("\n").filter((l) => /combobox|option/.test(l)));
// maxChars limits what prints (condensed, with a note); .tree stays complete.
// A new scope has no previous snapshot, so the tree prints.
const small = await snapshot(page.locator("body"), { maxChars: 500 });
emitBree("max-chars", String(small));
emitBree("max-chars-tree-complete", small.tree.split("\n").length === s1.tree.split("\n").length);
emitBree("page-arg", (await snapshot(page, { interactive: true })).tree === (await snapshot({ interactive: true })).tree);
