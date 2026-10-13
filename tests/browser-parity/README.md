# Browser REPL scenarios

Checks `bree browser repl` against its one API
([docs/browser-repl](../../docs/browser-repl/README.md)): behavior values
against real Playwright, snapshot and printing formats against reviewed
bree goldens, and parity against reference A and reference B with
differential cases. [capabilities.json](capabilities.json) maps every reference A
and reference B capability to the bree equivalent and the differential
cases that exercise it.

## Differential cases

`diff/` runs one task three ways: the bree API (the dev driver or the app),
reference A's dialect through its REPL (one-shot, loopback fixture pages only),
and reference B's through its reference runtime and the user's
reference client (`~/fun/bree-browser-cli/scripts/cua-reference-client.ts`:
one approved `127.0.0.1` origin, the disposable `parity-upload.txt`, tabs in
the "🧪 bree parity" group closed after each case, no other origin, raw CDP or
history). A case (`diff/cases/*.mjs`) lists the reference members and edge
case it covers, the code per dialect (`$P` is the dialect's Playwright page,
`$T(ms)` its timeout option, `$LOG` the fixture's event log), what bree must
produce (`expect`), and, where bree differs from a reference on purpose, the
reason and the check that proves it (`better`). Outcomes are normalized
(origins, error text to an error class, times to buckets); a verdict per
reference is `same`, `bree-better`, `bree-worse`, `not-applicable` or
`out-of-scope`. `unit/diff.test.mjs` recomputes every verdict from
`diff/results/*.json` and fails on any bree-worse verdict, any missed
expectation, a member without a same-or-better case, or an edge case in
[edge-cases.md](../../docs/browser-repl/edge-cases.md) without a case.

```sh
node tests/browser-parity/diff/run.mjs run --backend bree-dev     # record the dev driver
node tests/browser-parity/diff/run.mjs run --backend reference-a  # live reference A
node tests/browser-parity/diff/run.mjs run --backend reference-b  # live reference B
PARITY_BREE_CLI=<tagged bree CLI> BREE_SOCKET_PATH=/tmp/bree-debug-<tag>.sock \
  node tests/browser-parity/diff/run.mjs run --backend bree       # the app
node tests/browser-parity/diff/run.mjs check --backend bree-dev   # judge now, write nothing
node tests/browser-parity/diff/run.mjs verdicts                   # totals and gaps
node tests/browser-parity/diff/run.mjs sync-capabilities          # capabilities.json cases
node tests/browser-parity/diff/run.mjs report                     # docs/browser-repl/parity-report.md
```

`--only TEXT` or `--ids a,b` limit a run; results merge into what is recorded.
Verdicts use the app's result for a case when there is one.

## Layout

- `fixtures/`: pages served on two origins (`localhost` and `127.0.0.1`, so the
  peer is cross-site) by `lib/fixture-server.mjs`.
- `scenarios/NN-name.js`: REPL code in the bree API. `PRIMARY`, `PEER`,
  `emit(key, value)` and `emitBree(key, value)` are predefined.
  - `emit` records a behavior value; the oracle owns it.
  - `emitBree` records a value whose format bree defines (snapshot text,
    printing); bree-dev owns it and a person reviews it.
  - `// ---- cell [session=NAME] [capture] [bree-only]` starts a new call.
    Without `session` a call is one-shot (its tabs close unless kept);
    `capture` records the call's printed output as `output:N`; `bree-only`
    cells use APIs with no Playwright counterpart and the oracle skips them.
  - A header line `// oracle: skip (<reason>)` makes a whole scenario bree-owned.
- `goldens/NN-name.json`: `{ "oracle": {key: value}, "bree": {key: value} }`.
- `fixtures/corpus/`: nine public pages (Wikipedia, Hacker News, a GitHub
  repository, two MDN pages, one with live-example iframes, NPR text, BBC
  News, an e-commerce listing, Vercel's marketing SPA) frozen by
  `lib/corpus.mjs capture` in logged-out headless Chrome: post-JavaScript DOM,
  scripts removed, stylesheets inlined and pruned to matching rules, fonts and
  remote images replaced, iframes inlined as `srcdoc`. `NAME.oracle.json`
  (`lib/corpus.mjs oracle`) holds what Chrome's Playwright AI snapshot lists
  as interactive and the text Chrome does not render; `reference-a-sizes.json`
  holds the size of reference A's snapshot of each frozen page. Scenario
  `27-corpus` checks recall (every Chrome interactive element, same role and
  name), leaks (no unrendered text) and size (within 10% of reference A) per page.
  Re-capture only on purpose: it changes the pages under test.
- `fixtures/stress/`: synthetic large pages (`stress.html?kind=cards|table|list|deep|iframes|shadow|text|select|virtual&n=N`),
  built by script so the same query gives the same DOM. Scenario `30-stress`
  checks Playwright behavior on them against the oracle and the print budget.
- `perf/`: `bench.mjs` times snapshots, diffs and ref resolution per page for
  bree (dev driver or a tagged app), reference A and Playwright AI snapshot; `report.mjs`
  renders `perf/results/*.json` as the tables in
  [performance.md](../../docs/browser-repl/performance.md), including the
  reference B AX columns recorded earlier.
- `reference/`: API surfaces captured from reference A and reference B.

The format studies and the representation comparison live in the private
repository `ecyx00/bree-browser-parity-private`.
- `unit/`: `node --test` tests for the runtime and for capabilities.json,
  including `budget.test.mjs` (print budget, diff bounds, output spill) and
  `perf.test.mjs` (scaling and bounded-output guards on the stress pages).

## Backends

- `bree-dev`: the runtime in `Resources/browser-repl` in this Node process on
  Playwright WebKit through `lib/dev-driver.mjs`. No app build.
- `oracle`: real Playwright on headless Google Chrome (throwaway profile) with
  a thin shim of the globals (`lib/oracle.mjs`).
- `bree`: the app's CLI, one `bree browser repl --eval -` call per cell.

## Commands

```sh
node tests/browser-parity/run.mjs check --backend bree-dev     # all keys
node tests/browser-parity/run.mjs check --backend oracle       # oracle keys
node --test tests/browser-parity/unit/*.test.mjs

# A tagged app build
PARITY_BREE_CLI=<tagged bree CLI> BREE_SOCKET_PATH=/tmp/bree-debug-<tag>.sock \
  node tests/browser-parity/run.mjs check --backend bree

# Re-record: behavior from the oracle, then bree formats from bree-dev.
# Review every changed bree value line by line before committing it.
node tests/browser-parity/run.mjs record --backend oracle
node tests/browser-parity/run.mjs record --backend bree-dev

# Print values without comparing: run --backend <name> [--only NN] [-v]

# Corpus: freeze the pages again, then record Chrome's expectations
node tests/browser-parity/lib/corpus.mjs capture [--only NAME]
node tests/browser-parity/lib/corpus.mjs oracle [--only NAME]
```

Snapshot bytes on the corpus (bree-dev, reference A CLI 1.26.916.1741):

| Page | bree | Reference A | Chrome AI snapshot |
| --- | ---: | ---: | ---: |
| wikipedia | 63,363 | 68,640 | 210,081 |
| hackernews | 10,045 | 11,878 | 62,999 |
| github | 61,467 | 61,635 | 227,801 |
| mdn | 20,504 | 28,433 | 73,141 |
| mdn-iframe | 43,843 | 56,365 | 146,590 |
| npr | 2,500 | 4,835 | 5,561 |
| bbc | 16,616 | 16,139 | 50,935 |
| books | 9,165 | 14,974 | 35,677 |
| vercel | 6,698 | 10,398 | 26,338 |

bree keeps visible text reference A leaves out (card descriptions and times,
heading anchors, README table cells); on BBC, where that text is a large
share, bree is 3% larger. bree sizes include `[url=host/…]` on off-site
links. Recall is judged in the engine that renders bree: each recorded
element is found by its path and `fixtures/corpus/gt.js` decides there whether
a user can see it (70 GitHub links an overflow box clips out are not shown in
Chrome either); no element is exempt otherwise.

Playwright loads from `PARITY_PLAYWRIGHT_DIR`, the copy bundled with
`PARITY_REFERENCE_B_RUNTIME`, or `node_modules`; the reference backends need
`PARITY_REFERENCE_A_CLI` and `PARITY_REFERENCE_B_RUNTIME`
([lib/references.mjs](lib/references.mjs)); WebKit comes from `~/.cache/bree-parity-browsers`.
A record refuses a scenario with an uncaught error, so goldens never hold one.
