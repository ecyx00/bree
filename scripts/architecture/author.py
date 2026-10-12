#!/usr/bin/env python3
"""One free authoring run: a headless `claude -p` session reads the repo and writes the diagrams the repo needs.

    author.py <root> [--model sonnet] [--cap 400000] [--no-repair]

Output: <root>/.architecture/agent/{manifest.json, <id>.svg, manifest.raw.json, validation.json, run.json}. Design: docs/state/2026-10-10-architecture-agent-authored-design.md, section A.

Isolation (checked with `claude --help` and the stream-json init event, see docs/state/2026-10-10-architecture-agent-pilot.md):
  --setting-sources ""            no user / project / local settings, so none of the user's hooks, enabled plugins or permission rules load
  --strict-mcp-config + empty --mcp-config   no MCP servers
  --disable-slash-commands        no skills (the diagram-design skill is read from vendor/ as plain files instead)
  --tools Read,Grep,Glob,Bash,Write,Edit, --permission-mode dontAsk, --allowedTools = the allow-list below (anything else is denied, not asked)
  --exclude-dynamic-system-prompt-sections, --no-session-persistence is NOT used: the repair turn resumes the same session
  (--bare would also skip OAuth/keychain, so it needs ANTHROPIC_API_KEY, which this machine does not set.)

Token cap: the stream is read live; fresh tokens = input + cache_creation + output over all assistant turns. At the cap the process is killed and the run
is reported as capped (the cap is never raised). Cache reads are reported separately; --max-budget-usd is a second backstop.
"""
import argparse, datetime, json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
INDEX_TOOL = os.environ.get("BREE_INDEX_TOOL", "code-index")  # same default as gen.py
VENDOR = os.path.join(HERE, "vendor", "diagram-design")
BACKSTOP_USD = 8.0

def _load_contract():
    """The drawing contract has one source: the "Drawing contract" section of Resources/guides/architecture.md (what `bree guide architecture` prints)."""
    g = open(os.path.join(HERE, "..", "..", "Resources", "guides", "architecture.md"), encoding="utf-8").read()
    body = g.split("\n## Drawing contract\n", 1)[1].strip("\n")
    return body.replace("bree architecture check", "python3 {validator} {root} --check") + "\n"


CONTRACT = _load_contract()

TASK = """You are the architecture author for the repository at {root}. Produce the diagrams a new engineer needs to understand this repo, and explain every node deeply.

THE SKILL. Read {vendor}/SKILL.md first, then the type reference for every diagram type you consider ({vendor}/references/type-*.md, semantic-patterns.md,
primitives-core.md, style-guide.md, layout-budget.md; example SVGs are in {vendor}/assets). Use the skill's judgement (which type fits which question, the
anti-patterns, the taste gate). Two overrides: (1) skip the first-time style-guide gate, the style is fixed by the shell; (2) do not write HTML pages or use the
skill's colours and templates, only the bare inline SVG described in {facts}/shell-contract.md, which you must read completely before drawing.

FACTS. {facts}/facts.md (condensed deterministic model: modules, flows, edges), {facts}/index-map.txt (`{index_tool} map`), {facts}/hooks.md (hook configuration entries pointing
into the repo), {facts}/current.architecture.json (the full model). They are a starting point, they can be wrong or shallow. You may and should read the repo freely:
Read, Grep, Glob, and Bash for `{index_tool} ...` (impact, refs, def, show, callees, map) and `git log` / `git show`. Nothing else is available, and you cannot reach the network.

DECIDE. You choose how many diagrams (usually 6 to 12) and which type each one needs, and the reading order. Diagram 1 is the backbone, the big picture a newcomer reads
first. Then go from the whole to the parts, and cover what a reader must understand to change the repo safely: the main structure, the important runtime flows, state or
lifecycle where it exists, data stores and file formats, extension or integration points. Skip a type that has nothing real to show; never pad. For every diagram put in
the manifest a `why_type` (one or two sentences: what question this diagram answers and why this type is the right one).

WRITE everything into {out} (create it; you can write nowhere else):
  {out}/manifest.json  a JSON list, one entry per diagram:
    {{"id": "backbone", "lang": "{lang}", "title": "...", "type": "<skill type>", "section": "<2 to 4 reader-facing section names, shared by neighbours>", "purpose": "<one or two sentences: what this diagram tells>",
      "why_type": "...", "order": 1, "svg": "backbone.svg", "nodes": [ NODE, ... ]}}
  NODE = {{"id": "backbone:hook", "name": "...", "kind": "module|function|process|store|actor|file|state|step", "summary": "...", "what": "...", "why": "...",
           "connects": [{{"to": "backbone:index", "label": "reads", "dir": "out"}}], "code": [{{"path": "hm/hook.py", "line": 81, "symbol": "hook_pretooluse"}}], "watch": "..."}}
  {out}/<id>.svg  one per diagram, following the shell contract.

NODE TEXT is the main product, and the reader said the old explanations were too thin. Write every title, purpose and node text in the language with BCP 47 tag `{lang}`; technical terms, identifiers and paths stay as they are in the code. Put `"lang": "{lang}"` in every manifest entry (the page language comes from it). For each node:
  summary  one line: what it is, in plain words.
  what     2 to 3 sentences, concrete: the actual functions, data and files involved, what goes in and what comes out. Never "handles X" without saying how.
  why      1 to 2 sentences: the problem it solves in this repo, and what breaks or gets harder without it.
  connects every edge touching the node, on both sides: `to` is the OTHER node id in the SAME diagram, `label` says what flows (the data or the call, a few words), dir "out" if this node
           initiates and "in" if it receives. They must match the edges you draw.
  code     1 to 3 anchors you have READ and confirmed: path relative to the repo root, the line of the definition, the exact symbol name that appears within 3 lines of that line.
           A node that is a pure concept (an actor, a store of files) may use the file or function that implements it. An anchor that does not resolve is deleted, and a diagram with
           more than 20% nodes left without any anchor is rejected, so read before you cite.
  watch    optional, one real gotcha you found in the code (an invariant, an ordering rule, a failure mode). Skip it when you found none; never invent one.
Edge labels on the drawing stay short (at most 14 characters, in the identifier's own case: never uppercase); the longer explanation lives in `connects`.

FINISH. Bash takes ONE simple command per call (no &&, ;, pipes or redirects), and only the commands listed above. Run `python3 {validator} {root} --check`, repair every FAIL it prints (layout failures: add space or reroute), and run it again until every diagram passes or you have
no budget left to fix it. Then reply with one line per diagram: id, type, why. Budget: you have a hard cap of about {cap} tokens for the whole run, so read what matters and write
the files as you go rather than saving everything for the end.
"""

REPAIR = """The validator rejected these diagrams. Fix them now in {out}: edit the entries in manifest.raw.json and the matching <id>.svg files in place (manifest.json is regenerated
from manifest.raw.json; do not edit it). Read the reasons, fix the cause (resolve anchors by reading the file again; layout: more space, fewer crossings), then run
`python3 {validator} {root} --check` until they pass.

{problems}
"""


def sh(cmd, cwd):
    r = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True, timeout=120)
    return (r.stdout + r.stderr).strip()


def write_facts(root, facts):
    """The fact sheet: condensed deterministic model, index map, hook entries, the shell contract."""
    os.makedirs(facts, exist_ok=True)
    mp = os.path.join(root, ".architecture", "current.architecture.json")
    lines = [f"# Facts about {os.path.basename(root)} (deterministic, may be shallow or wrong)", ""]
    if os.path.exists(mp):
        d = json.load(open(mp))
        shutil.copy(mp, os.path.join(facts, "current.architecture.json"))
        lines += [f"commit {d.get('commit')}, model generated {d.get('generated_at')}", "", "## Modules (label, role, files)"]
        mods = {x["id"]: x for x in d["nodes"] if x["kind"] == "module"}
        for x in sorted(mods.values(), key=lambda x: x["id"]):
            lines.append(f"- {x['label']}: {x.get('role', '')} [{', '.join(s['path'] for s in x.get('sources', []))}]")
        lines += ["", "## Module to module edges"]
        for e in d["edges"]:
            if e["from"] in mods and e["to"] in mods:
                lines.append(f"- {mods[e['from']]['label']} -> {mods[e['to']]['label']} ({e.get('via', '')})")
        for b in d["boards"]:
            if b["kind"] != "flow":
                continue
            lines += ["", f"## Flow: {b['title']} (entry {b['entry']['symbol']}, called by {b['entry'].get('caller')})"]
            steps = sorted((x for x in d["nodes"] if x["board"] == b["id"]), key=lambda x: x.get("order", 0))
            lines += [f"{x.get('order', 0)}. {x['label']} ({x.get('actor', '')}) {x.get('anchor', '')}" for x in steps]
    open(os.path.join(facts, "facts.md"), "w").write("\n".join(lines) + "\n")
    open(os.path.join(facts, "index-map.txt"), "w").write(sh(INDEX_TOOL + " map", root) + "\n")
    hooks = []
    for rel in (".claude/settings.json", ".claude/settings.local.json", "hooks/hooks.json", ".claude-plugin/plugin.json", ".codex/hooks.json"):
        p = os.path.join(root, rel)
        if os.path.exists(p):
            try:
                j = json.load(open(p))
                hooks.append(f"## {rel}\n" + json.dumps(j.get("hooks", j) if isinstance(j, dict) else j, indent=1)[:4000])
            except ValueError:
                pass
    open(os.path.join(facts, "hooks.md"), "w").write("\n\n".join(hooks) or "No hook configuration found in the repo.\n")


def claude_cmd(root, out, model, extra):
    allow = [f"Read", "Grep", "Glob", f"Bash({INDEX_TOOL} *)", "Bash(git log *)", "Bash(git show *)", f"Bash(python3 {HERE}/validate_agent.py *)",
             f"Write(//{out.lstrip('/')}/**)", f"Edit(//{out.lstrip('/')}/**)"]
    deny = ["Read(~/.secrets/**)", "Read(~/.claude/**)", "Read(~/.ssh/**)", "Read(~/.config/**)", "Read(//Users/*/Vault/**)"]
    return (["claude", "-p", "--model", model, "--output-format", "stream-json", "--verbose", "--setting-sources", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
             "--disable-slash-commands", "--tools", "Read,Grep,Glob,Bash,Write,Edit", "--permission-mode", "dontAsk", "--allowedTools", ",".join(allow),
             "--disallowedTools", ",".join(deny), "--exclude-dynamic-system-prompt-sections", "--max-budget-usd", str(BACKSTOP_USD)] + extra)


class Meter:
    """Token accounting over the live stream. fresh = input + cache_creation + output, deduplicated by message id (last usage per message wins)."""

    def __init__(self, cap):
        self.cap, self.msgs, self.base, self.result = cap, {}, 0, None

    def feed(self, ev):
        if ev.get("type") == "assistant":
            m = ev["message"]
            u = dict(m.get("usage", {}))
            # streamed usage carries only the first output_tokens count: take the larger of it and a size estimate of the content (about 3.5 chars per token)
            est = int(sum(len(b.get("text", "") or "") + len(json.dumps(b.get("input", ""))) + len(b.get("thinking", "") or "") for b in m.get("content", [])) / 3.5)
            u["output_tokens"] = max(u.get("output_tokens", 0) or 0, est)
            self.msgs[m.get("id") or str(len(self.msgs))] = u
        elif ev.get("type") == "result":
            self.result = ev

    def tot(self):
        if self.result and self.result.get("usage"):   # the final result event carries the authoritative totals
            r = self.result["usage"]
            u = {k: r.get(k, 0) or 0 for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")}
            u["fresh"] = u["input_tokens"] + u["cache_creation_input_tokens"] + u["output_tokens"]
            return u
        u = {k: sum(x.get(k, 0) or 0 for x in self.msgs.values()) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")}
        u["fresh"] = u["input_tokens"] + u["cache_creation_input_tokens"] + u["output_tokens"]
        return u


def session(cmd, prompt, cwd, meter, log):
    """Run one claude turn; kill it when fresh tokens reach the cap. Returns (session_id, capped)."""
    p = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)  # prompt on stdin: --add-dir/--tools are variadic
    p.stdin.write(prompt)
    p.stdin.close()
    sid, capped = None, False
    for line in p.stdout:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        log.write(line)
        sid = ev.get("session_id") or sid
        meter.feed(ev)
        if meter.tot()["fresh"] >= meter.cap:
            capped = True
            p.kill()
            break
    p.wait()
    if p.returncode not in (0, None, -9) and not capped:
        sys.stderr.write(f"claude exited {p.returncode}\n")
    return sid, capped


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--cap", type=int, default=400000)
    ap.add_argument("--no-repair", action="store_true")
    ap.add_argument("--lang", default="en", help="language of the node text (BCP 47, default en); written into the manifest")
    a = ap.parse_args()
    if not shutil.which("claude"):
        sys.exit("author.py: claude not found on PATH (the agent path runs `claude -p`)")
    root = os.path.abspath(a.root)
    out = os.path.join(root, ".architecture", "agent")
    os.makedirs(out, exist_ok=True)
    for f in os.listdir(out):   # a fresh run replaces the previous one
        if f.endswith((".svg", ".json", ".jsonl")):
            os.remove(os.path.join(out, f))
    validator = os.path.join(HERE, "validate_agent.py")
    sys.path.insert(0, HERE)
    import validate_agent
    meter = Meter(a.cap)
    t0 = datetime.datetime.now().astimezone()
    with tempfile.TemporaryDirectory() as facts:
        write_facts(root, facts)
        open(os.path.join(facts, "shell-contract.md"), "w").write(CONTRACT.replace("{validator}", validator).replace("{root}", root))
        fmt = dict(lang=a.lang, root=root, vendor=VENDOR, facts=facts, out=out, validator=validator, cap=a.cap, index_tool=INDEX_TOOL)
        cmd = claude_cmd(root, out, a.model, ["--add-dir", VENDOR, "--add-dir", facts])
        with open(os.path.join(out, "session.jsonl"), "w") as log:
            sid, capped = session(cmd, TASK.format(**fmt), root, meter, log)
            report, repaired = None, []
            if not capped and os.path.exists(os.path.join(out, "manifest.json")):
                report = validate_agent.validate_all(root)
                bad = {k: v for k, v in report.items() if not v["ok"]}
                if bad and sid and not a.no_repair:
                    repaired = sorted(bad)
                    probs = "\n".join(f"- {k}: " + "; ".join(v["errors"])[:1500] for k, v in bad.items())
                    sid2, capped = session(claude_cmd(root, out, a.model, ["--resume", sid, "--add-dir", VENDOR, "--add-dir", facts]), REPAIR.format(problems=probs, **fmt), root, meter, log)
                    if not capped:
                        report = validate_agent.validate_all(root)
    commit = sh("git rev-parse --short HEAD", root)
    tot = meter.tot()
    run = {"at": t0.isoformat(timespec="seconds"), "commit": commit, "model": a.model, "cap": a.cap, "capped": capped, "tokens": tot,
           "cost_usd": (meter.result or {}).get("total_cost_usd"), "repair_turn_for": repaired,
           "validation": {k: {"ok": v["ok"], "errors": v["errors"], "removed_anchors": len(v["removed"]), "unverified_ratio": v["unverified_ratio"]} for k, v in (report or {}).items()}}
    json.dump(run, open(os.path.join(out, "run.json"), "w"), indent=1, ensure_ascii=False)
    print(json.dumps({k: run[k] for k in ("capped", "tokens", "cost_usd", "repair_turn_for")}))
    if capped:
        sys.exit(f"token cap {a.cap} reached: stopped. Files so far are in {out}; the cap was not raised.")


if __name__ == "__main__":
    main()
