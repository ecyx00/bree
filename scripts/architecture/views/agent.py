"""Agent-authored boards: reads <root>/.architecture/agent/manifest.json (written by author.py, cleaned by validate_agent.py).

One Board per diagram, in manifest `order`. A board's group is the diagram's `section`. views.collect() puts these boards first and moves every
deterministic board to one last section "Facts". Without agent output build() returns [] and the nav is today's.
The SVG is whitespace-collapsed between tags (stable_check's geometry regex reads one line per node). Node dicts carry the rich keys (kind, summary, what, why, connects, code, watch, unverified) next to the old {id, name, sub, about, anchor}.
"""
import json, os, re
from . import Board

DIR_OVERRIDE = None   # validate_agent.layout_issues points this at a work dir
KEEP = ("kind", "summary", "what", "why", "connects", "code", "watch", "unverified")


def agent_dir(root):
    return DIR_OVERRIDE or os.path.join(root or "", ".architecture", "agent")


def manifest_lang(root):
    """Content language the producer declared: the first manifest entry that carries a `lang` key (BCP 47 tag, e.g. "tr"). None when absent."""
    try:
        for e in json.load(open(os.path.join(agent_dir(root), "manifest.json"), encoding="utf-8")):
            if isinstance(e, dict) and e.get("lang"):
                return str(e["lang"])
    except (OSError, ValueError, TypeError):
        pass
    return None


def build(ctx):
    d = agent_dir(ctx.root)
    mp = os.path.join(d, "manifest.json")
    if not os.path.exists(mp):
        return []
    boards = []
    for e in sorted(json.load(open(mp, encoding="utf-8")), key=lambda e: (e.get("order", 0), e["id"])):
        sp = os.path.join(d, e["svg"])
        if not os.path.exists(sp):
            continue
        nodes = []
        for n in e["nodes"]:
            code = n.get("code") or []
            first = code[0] if code else {}
            nd = {k: n[k] for k in KEEP if k in n}
            nd.update(id=n["id"], name=n["name"], sub=n.get("kind", ""), about=" ".join(x for x in (n.get("summary"), n.get("what")) if x),
                      anchor=f"{first['path']}#{first.get('symbol', '')}" if first else "")
            nodes.append(nd)
        boards.append(Board(id=e["id"], group=e.get("section") or "Diagrams", title=e["title"], purpose=e.get("purpose", ""),
                            svg=re.sub(r">\s+<", "><", open(sp, encoding="utf-8").read().strip()), nodes=nodes, entry=nodes[0]["id"] if nodes and not boards else ""))
    return boards
