#!/usr/bin/env python3
"""Render <root>/.architecture/current.html from the agent boards alone (.architecture/agent/), Python 3 stdlib only.

    render_agent.py <root> [--lang BCP47]

No code index, no claude, no current.architecture.json. `bree architecture render` runs this; gen.py --render-only falls back to it when the
code-index model is missing. Exit 1 with one line when there is no manifest.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def render_root(root, lang=None):
    """Write <root>/.architecture/current.html. Returns the path."""
    import render
    root = os.path.abspath(root)
    out_dir = os.path.join(root, ".architecture")
    if not os.path.isfile(os.path.join(out_dir, "agent", "manifest.json")):
        sys.exit(f"render: no diagrams: {os.path.join(out_dir, 'agent', 'manifest.json')} is missing (run `bree guide architecture`)")
    doc = {"schema": "bree-architecture/2", "repo": os.path.basename(root), "boards": [], "nodes": [], "edges": [], "flows": [], "roles": {}}
    if lang:
        doc["lang"] = lang
    page = render.render_page(doc, {}, {}, root=root, registry=["agent"], arch_dir=out_dir)
    path = os.path.join(out_dir, "current.html")
    open(path, "w", encoding="utf-8").write(page)
    return path


if __name__ == "__main__":
    args = sys.argv[1:]
    lang = args[args.index("--lang") + 1] if "--lang" in args else None
    print(render_root(args[0] if args and not args[0].startswith("--") else ".", lang))
