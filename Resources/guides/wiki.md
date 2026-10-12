# Bree Wiki: a guide for coding agents

Bree shows a small wiki next to the terminal (tab bar book icon, ⌥⌘K). The person you work with
opens it to understand the project they are in: its concepts, its decisions, and where each part
lives in the code. You, the coding agent, write it. Bree only reads files and renders them.

## What it is for

- **Learning the project.** One page per concept the person must understand to work here: what it
  is, why it exists, how it works, where it lives in the code.
- **Remembering decisions.** What was decided, why, what was rejected, what is still open.
- **Jumping into code.** Every claim can link to the exact file, line or symbol. A click opens the
  code inside the popover with the line highlighted.

It is not user documentation, a changelog or a chat log. Prefer few pages that stay true over many
pages that go stale. Update a page when the code it describes changes.

## What you can do

| You can | How |
| --- | --- |
| Add a page | Write a markdown file and list it in `index.json` |
| Group pages | `groups` in `index.json` (e.g. "Concepts", "Decisions") |
| Link pages | `[[slug]]` or `[[slug\|label]]` |
| Link code | `[label](code:path#symbol)` (preferred: it survives edits), `[label](code:path:42)`, `[label](code:path)` |
| Cite a commit | `[commit:3f2a9c1]` (Bree shows `git show --stat` in the popover) |
| Link a document | `[doc:docs/design.md]` (the chip shows the file name) |
| Format | GFM tables, code blocks, `> [!note]` callouts, ` ```mermaid ` diagrams, `$math$` and `$$math$$` (KaTeX) |
| Connect your own tools | Declare chips in `.bree-wiki.json` (memory, issue tracker, anything with a CLI) |

Paths in `code:` and `doc:` are relative to the project root.

## Where to write

- **Repo-local:** `<repo>/.bree/wiki/`. Travels with the repository and is shared with the team.
  Bree checks this first.
- **Personal:** the global wiki folder the person picked in Bree Settings > Wiki, one subfolder per
  project. Use it for notes that should not be committed. Ask the person before you write there.

## Files

`index.json`:

```json
{
  "schema": "bree-wiki/1",
  "project": "payments-api",
  "root": "/Users/me/src/payments-api",
  "lang": "en",
  "groups": [
    {
      "title": "Concepts",
      "pages": [
        {
          "slug": "idempotency-keys",
          "title": "Idempotency keys",
          "one_liner": "Why a retried payment never charges twice.",
          "updated": "2026-10-10",
          "status": "current"
        }
      ]
    }
  ]
}
```

- Required: `project`, each group `title`, each page `slug` and `title`. The rest is optional.
- `updated` is a date, `YYYY-MM-DD`. `status` is free text such as `current` or `draft`.
- `root` matches the wiki to a terminal: the terminal's folder must be inside it. A repo-local wiki
  may omit it.
- A page lives at `<slug>.md` next to `index.json`, or at `file` (relative to `index.json`).
- `slug` has no `/`, `\` or `..`.
- `lang` is the language you wrote in. Write in the person's language.

A page is plain markdown. Start with an `#` title that matches `title`. Keep the first paragraph
able to stand alone: it is what the person reads first.

## Connecting your own tools: `.bree-wiki.json`

Put this file in the wiki folder to give chips of your own a meaning:

```json
{
  "chips": {
    "issue": { "argv": ["gh", "issue", "view", "{value}"], "title": "Issue {value}",
               "valuePattern": "^[0-9]{1,8}$" },
    "note":  { "argv": ["my-memory", "show", "{value}"], "title": "Note {value}",
               "output": "markdown" }
  },
  "hiddenTags": ["draft"],
  "symbolCommand": ["my-index", "def", "{symbol}"]
}
```

- `[issue:42]` then runs `gh issue view 42` and shows its output as a page.
- `argv[0]` is a bare tool name. Bree finds it on the person's login-shell `PATH`.
- `valuePattern`: regex the value must match. Default: letters, digits, `.`, `_`, `-`.
- `output`: `text` (default, shown as a code block) or `markdown`.
- A chip without a handler shows as a plain label. Nothing breaks.
- `hiddenTags`: tags such as `[draft]` that Bree does not render.
- `agentKinds`: extra record kinds that a chip with `"output": "memory"` shows as an agent reply (`agent` and `assistant` always are).
- `symbolCommand`: optional faster lookup for `code:path#symbol`. Without it Bree scans the file.
- Bree asks the person once before it runs a command declared by a repo-local wiki.

## Before you finish

1. `index.json` parses and every listed page file exists.
2. Every `[[slug]]` names a listed page.
3. Every `code:` link points to a file that exists; line numbers match the current code.
4. No secrets, tokens or personal data in pages.
5. Run `bree wiki check` and fix every FAIL line.
6. Tell the person the pages are ready and ask them to open the wiki (⌥⌘K). You cannot see the
   popover yourself.
