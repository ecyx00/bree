# Bree Architecture: a guide for coding agents

Bree shows architecture diagrams of the repository the terminal is in (tab bar diagram icon, ⌥⌘A).
The person you work with reads them to understand the project before they change it. A click on a
node opens a card: what the part is, what it does, why it exists, what it connects to, and links
that open the code at the exact line. You, the coding agent, draw the diagrams and write the cards.
Bree only reads the files and shows them.

## What it is for

- **The big picture first.** Diagram 1 is the backbone: the few parts a newcomer must know and how
  they connect.
- **From the whole to the parts.** Then the important runtime flows, state and lifecycles, data
  stores and file formats, extension points.
- **Changing code safely.** Every node links to the code that implements it, and can carry one real
  gotcha found in that code.

It is not a full dependency graph or a class diagram of everything. Six calm diagrams that a
person reads in order beat thirty dense ones.

## What you can do

| You can | How |
| --- | --- |
| Add a diagram | One `<id>.svg` plus one entry in `manifest.json` |
| Set the reading order | `order` in each entry; the pager follows it |
| Group diagrams | `section` (two to four shared names, e.g. "Structure", "Runtime", "Data") |
| Explain a node | `summary`, `what`, `why`, optional `watch` on each node |
| Link a node to code | `code: [{path, line, symbol}]`; a click opens the source at that line |
| Show what connects | `connects` on each node, matching the edges you draw |
| Mark the entry point | `class="nb focal"` on its box; datastores use `class="nb store"` |
| Pick the language | `lang` (BCP 47) in every entry; write in the person's language |

## Where to write

`<repo>/.architecture/agent/`: `manifest.json` and one `<id>.svg` per diagram. Write nowhere else.
`bree architecture render` then builds `.architecture/current.html`, which Bree shows.

## manifest.json

A JSON list, one entry per diagram:

```json
[
  {
    "id": "backbone",
    "lang": "en",
    "title": "payments-api: the big picture",
    "type": "architecture",
    "section": "Structure",
    "purpose": "Where a payment request enters, which services it crosses, where state is kept.",
    "why_type": "A layered view answers 'what are the parts and who calls whom' in one screen.",
    "order": 1,
    "svg": "backbone.svg",
    "nodes": [
      {
        "id": "backbone:api",
        "name": "HTTP API",
        "kind": "module",
        "summary": "Receives payment requests and validates them.",
        "what": "router.ts maps POST /payments to createPayment, which checks the idempotency key and enqueues a job.",
        "why": "Keeps request handling thin, so retries never reach the payment provider twice.",
        "connects": [{ "to": "backbone:queue", "label": "enqueues job", "dir": "out" }],
        "code": [{ "path": "src/router.ts", "line": 42, "symbol": "createPayment" }],
        "watch": "The idempotency check must run before the enqueue, not after."
      }
    ]
  }
]
```

- Required: `id`, `title`, `svg`, `nodes`, and on each node `id` and `name`.
- Node ids are `<diagram id>:<slug>`, `[a-z0-9-]` after the colon.
- `kind`: `module`, `function`, `process`, `store`, `actor`, `file`, `state` or `step`.
- `type` is free text that names the diagram type: for example `architecture`, `flow`,
  `sequence`, `state`, `data`, `dependency`.
- `section`, `title`, `purpose` and all node text are in the language of `lang`. Code
  identifiers and paths stay as they are in the code.
- `code`: one to three anchors you have read. `path` is relative to the repo root, `line` is the
  definition, `symbol` appears within three lines of it. An anchor that does not resolve is
  removed. A diagram with more than 20% of its nodes left without an anchor is rejected.
- `connects[].to` is another node in the same diagram. `dir` is `out` when this node starts it.
- `watch`: one real gotcha from the code. Leave it out when you found none. Never invent one.

## Steps

1. Read the repository. Find the entry points, the main modules, the stores and the flows.
2. Choose the diagrams (usually 6 to 12) and their order. Skip a type that has nothing real to show.
3. Write `manifest.json` and the SVG files. Follow the drawing contract below exactly.
4. Run `bree architecture check`. Fix every FAIL line, then run it again until it passes.
5. Run `bree architecture render`.
6. Tell the person the diagrams are ready and ask them to open the Architecture popover (⌥⌘A).
   You cannot see the popover yourself; `check` is your proof that the page will draw.

## Drawing contract

# The shell contract (what the Bree Architecture popover does with your SVG)

You write each diagram as ONE file `<id>.svg`: a bare inline `<svg>` (no HTML wrapper, no <style> needed). The page paints it on a warm dark paper.
Use ONLY these classes (the page defines them, with CSS variables; never write a colour, a font family or a hex value):

    .mask  opaque paper fill (hides edges behind a node or behind an edge label)     .nb  node box   .nb.focal  accent (the entry / the one thing)   .nb.store  datastore
    .nm  node name (sans)    .sb  mono sub-label    .al  arrow label (mono, identifier case)    .lg  legend text    .eb  eyebrow caps (mono)
    .tag  tag outline   .tg  tag text   .ed  edge stroke   .ar  arrowhead fill   .dg  diamond / decision stroke   .l1 .l2  hairlines   .band  lane / band fill   .zone  zone boundary fill+stroke   .hit  invisible hit area

Canvas: 4 px grid, 40 px outer margin, `viewBox="0 0 W H" width="W" height="H"`, W and H multiples of 4. Smallest text 11 (font-size attribute on every <text>); names 13 weight 600.
Fonts are set by the classes. No <script>, no <foreignObject>, no on* attributes, no http(s) anywhere, no external href (only href="#id" inside the svg), no @import.

Skeleton (this exact structure; the checker finds nodes and edges by it):

    <svg viewBox="0 0 W H" width="W" height="H" role="img" aria-labelledby="t-ID d-ID">
      <title id="t-ID">Title</title><desc id="d-ID">One-sentence description</desc>
      <defs><marker id="ar-ID" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto"><polygon class="ar" points="0 0, 8 3, 0 6"/></marker></defs>
      <!-- 1. back layer: zones, lanes, bands (rect.zone / rect.band + a masked label) -->
      <!-- 2. edges: DIRECT children of <svg>, one per connection -->
      <path class="ed" data-from="ID:a" data-to="ID:b" d="M x,y L ... Q ..." stroke-width="1.2" marker-end="url(#ar-ID)"/>
      <!-- dashed edge for async / optional: stroke-dasharray="5,4" -->
      <!-- 3. edge labels: <rect class="mask" x y width height rx="2"/> + <text class="al" x y font-size="11" text-anchor="middle">label</text>  (keep the identifier's own case, never uppercase it; at most 14 chars) -->
      <!-- 4. nodes -->
      <g class="node" data-id="ID:a" tabindex="0" role="button" aria-label="Name">
        <rect class="mask" x y width height rx="6"/>          <!-- FIRST rect of the group is the node box the checker measures -->
        <rect class="nb" x y width height rx="6" stroke-width="1"/>      <!-- or "nb focal" / "nb store" -->
        <text class="nm" x y font-size="13" font-weight="600" text-anchor="middle">Name</text>
        <text class="sb" x y font-size="11" text-anchor="middle">sub-label (mono, a path or a kind)</text>
      </g>
      <!-- 5. legend last: <line class="l1"> hairline + <text class="eb">LEGEND</text> + keys -->
    </svg>

Rules the checker enforces in real Chrome at 560 and 1400 px wide (a violation rejects the diagram):
- every `<g class="node">` has a unique `data-id` equal to a manifest node id, and every manifest node has exactly one such group (no group, no node);
- all text inside its node box (size the box from the text: about 0.55 x font-size per character in sans, 0.62 in mono) and inside the svg; no two text boxes overlap; no text over a foreign node;
- edges are orthogonal polylines with 8 px rounded corners (L and Q path commands) and never pass through a node they do not connect (4 px clearance);
- two edges never share a collinear run longer than 8 px (offset parallel edges by 12 px or more), edge ends on one node side are at least 12 px apart and 8 px from a corner;
- an edge label sits on its own mask rect, at least 6 px from every edge stroke and clear of every node. Put the label BESIDE its edge, not on the stroke: above a horizontal run, to the right of a vertical run, with 7 px or more of clearance;
- a node that is a diamond uses <polygon class="nb" points=...> after the mask polygon and an invisible <rect class="hit"> first.
- Leave generous space: column pitch of at least node width + 56, row pitch of at least node height + 48. A calm, sparse diagram passes; a dense one fails.
Aim for 6 to 14 nodes per diagram (the skill's complexity budget); split rather than cram. Ids are `<diagram id>:<slug>`, [a-z0-9-] after the colon.
Self-check anytime (writes nothing, ~10 s): bree architecture check    and fix every FAIL line before you finish.
