#!/usr/bin/env python3
"""Render a page that holds the real boards plus the rich-key fixture board (views/_fixture_rich.py). 0 LLM calls.

  python3 render_fixture.py <root> <model-dir> <out.html>

<model-dir> holds current.architecture.json and names.json (what gen.py --render-only reads)."""
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import render, views


def main(root, mdir, out):
    doc = json.load(open(os.path.join(mdir, "current.architecture.json"), encoding="utf-8"))
    names = json.load(open(os.path.join(mdir, "names.json"), encoding="utf-8")) if os.path.exists(os.path.join(mdir, "names.json")) else {}
    reg = list(views.REGISTRY) + ["_fixture_rich"]
    open(out, "w", encoding="utf-8").write(render.render_page(doc, names.get("names", names), names.get("about", {}), root=root, registry=reg))


if __name__ == "__main__":
    main(*sys.argv[1:4])
