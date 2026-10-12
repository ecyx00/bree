#!/usr/bin/env python3
"""Deterministic validation of agent-authored diagrams (0 tokens).   validate_agent.py <root> [--no-layout] [--check]

Reads <root>/.architecture/agent/manifest.json (+ the SVGs) and, per diagram:
  - every code anchor {path, line, symbol} must resolve: the file exists inside the repo, the line exists, the symbol appears within +-3 lines.
    A failing anchor is removed. A node left with no anchor gets unverified=true (the inspector never shows it as fact).
  - the SVG must be well-formed XML, hold no script / foreignObject / on* handler / external href / external url(), and its
    <g class="node" data-id> ids must equal the manifest node ids.
  - more than 20% unverified nodes rejects the diagram.
  - layout (optional, real Chrome via check_svg.py): 0 issues at 560 and 1400 px.
A rejected diagram is repaired once by author.py, then dropped. Writes manifest.json (cleaned, accepted diagrams only), manifest.raw.json (as the agent
wrote it, first time only) and validation.json (per-diagram result). --check writes nothing (the agent's self-check). Exit 0 always, except --check, which exits 1 when any diagram FAILs; the report says what was dropped.
"""
import json, os, re, shutil, subprocess, sys, tempfile
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
SLACK = 3            # the symbol may sit this many lines away from the claimed line
MAX_UNVERIFIED = 0.20
BANNED_TAGS = {"script", "foreignobject", "iframe", "object", "embed", "link", "meta", "audio", "video"}


def _local(tag):
    return tag.rsplit("}", 1)[-1].lower()


def resolve_anchor(root, a):
    """True if the anchor points at a real line and the symbol is within SLACK lines of it."""
    try:
        path, line, sym = a["path"], int(a["line"]), str(a.get("symbol", ""))
        full = os.path.realpath(os.path.join(root, path))
        if os.path.isabs(path) or not full.startswith(os.path.realpath(root) + os.sep) or not os.path.isfile(full):
            return False
        lines = open(full, encoding="utf-8", errors="replace").read().splitlines()
        if not 1 <= line <= len(lines):
            return False
        return not sym or any(sym in l for l in lines[max(0, line - 1 - SLACK):line + SLACK])
    except (KeyError, TypeError, ValueError, OSError):
        return False


def svg_problems(svg, node_ids):
    """Static SVG checks. Returns a list of error strings (empty = fine)."""
    try:
        tree = ET.fromstring(svg)
    except ET.ParseError as e:
        return [f"svg is not well-formed XML: {e}"]
    errs, found = [], []
    if _local(tree.tag) != "svg":
        errs.append("root element is not <svg>")
    for el in tree.iter():
        t = _local(el.tag)
        if t in BANNED_TAGS:
            errs.append(f"banned element <{t}>")
        for k, v in el.attrib.items():
            kl = _local(k)
            if kl.startswith("on"):
                errs.append(f"event handler attribute {kl}")
            elif kl == "href" and not v.strip().startswith("#"):
                errs.append(f"external href {v[:60]!r}")
            elif kl in ("style", "fill", "stroke", "filter", "mask", "clip-path", "marker-end", "marker-start") and re.search(r"url\(\s*['\"]?(?!#)", v):
                errs.append(f"external url() in {kl}")
            if kl == "style" and "@import" in v:
                errs.append("@import in style")
        if t == "style" and el.text and (re.search(r"url\(\s*['\"]?(?!#)", el.text) or "@import" in el.text):
            errs.append("external url()/@import in <style>")
        if t == "g" and "node" in (el.get("class") or "").split() and el.get("data-id"):
            found.append(el.get("data-id"))
    if len(found) != len(set(found)):
        errs.append("duplicate data-id in the svg")
    if set(found) != set(node_ids):
        errs.append(f"svg node ids != manifest ids (only in svg: {sorted(set(found) - set(node_ids))[:5]}, only in manifest: {sorted(set(node_ids) - set(found))[:5]})")
    return errs


def validate_diagram(root, d, svg):
    """-> {ok, errors, removed: [(node id, anchor)], diagram: cleaned copy of d, unverified_ratio}"""
    d = json.loads(json.dumps(d))
    removed, errors = [], []
    for nd in d.get("nodes", []):
        keep = []
        for a in nd.get("code") or []:
            (keep.append(a) if resolve_anchor(root, a) else removed.append((nd.get("id"), a)))
        nd["code"] = keep
        if keep:
            nd.pop("unverified", None)
        else:
            nd["unverified"] = True
    ids = [nd.get("id") for nd in d.get("nodes", [])]
    if not ids:
        errors.append("diagram has no nodes")
    if len(ids) != len(set(ids)):
        errors.append("duplicate node ids in the manifest")
    errors += svg_problems(svg, ids)
    ratio = sum(1 for nd in d.get("nodes", []) if nd.get("unverified")) / max(1, len(ids))
    if ratio > MAX_UNVERIFIED:
        errors.append(f"unverified nodes {ratio:.0%} > {MAX_UNVERIFIED:.0%} (anchors that did not resolve: " + "; ".join(f"{i} {a.get('path')}:{a.get('line')} {a.get('symbol')}" for i, a in removed)[:600] + ")")
    return {"ok": not errors, "errors": errors, "removed": removed, "diagram": d, "unverified_ratio": round(ratio, 3)}


def layout_issues(root, agent_dir, manifest_path=None, widths=(560, 1400)):
    """Render the agent boards through the real shell and run check_svg.py. -> {diagram id: [issue lines]} (0 tokens, needs Chrome)."""
    sys.path.insert(0, HERE)
    import render
    from views import agent
    out = {}
    with tempfile.TemporaryDirectory() as td:
        src = os.path.join(root, ".architecture", "current.architecture.json")
        doc = json.load(open(src)) if os.path.exists(src) else {"repo": os.path.basename(root), "boards": [], "nodes": [], "edges": []}
        json.dump(doc, open(os.path.join(td, "current.architecture.json"), "w"))
        ad = os.path.join(td, "agent")      # a private copy: the board source is the manifest being checked, not whatever manifest.json holds now
        shutil.copytree(agent_dir, ad)
        if manifest_path:
            shutil.copy(manifest_path, os.path.join(ad, "manifest.json"))
        agent.DIR_OVERRIDE = ad
        try:
            open(os.path.join(td, "current.html"), "w", encoding="utf-8").write(render.render_page(doc, {}, {}, root, registry=["agent"]))
        except (KeyError, TypeError, ValueError, SystemExit) as e:   # malformed manifest: the static checks name the cause per diagram
            return {"_probe": [f"render failed: {type(e).__name__} {e}"]}
        finally:
            agent.DIR_OVERRIDE = None
        for w in widths:
            r = subprocess.run([sys.executable, os.path.join(HERE, "check_svg.py"), os.path.join(td, "current.html"), str(w)], capture_output=True, text=True, timeout=300)
            if r.returncode and not re.search(r"scale=.*issues=\d+", r.stdout):   # the checker died (no Chrome, probe failed): never read that as "no issues"
                out.setdefault("_probe", []).append(f"layout check could not run at {w}px: " + (r.stderr or r.stdout).strip()[-300:])
                continue
            cur = None
            for line in (r.stdout + r.stderr).splitlines():
                m = re.match(r"^(\S+)\s+scale=.*?issues=(\d+)$", line)
                if m:
                    cur = m.group(1)
                    out.setdefault(cur, [])
                elif line.startswith("    ") and cur:
                    out[cur].append(f"{w}px: {line.strip()}")
                elif "probe did not run" in line:
                    out.setdefault("_probe", []).append(line)
    return out


def validate_all(root, agent_dir=None, layout=True, write=True):
    """Validate every diagram of manifest.raw.json (else manifest.json). write=True: manifest.json (accepted only), manifest.raw.json, validation.json.
    write=False (--check, the agent's own self-check) touches nothing. Returns the report."""
    agent_dir = agent_dir or os.path.join(root, ".architecture", "agent")
    mpath, rpath = os.path.join(agent_dir, "manifest.json"), os.path.join(agent_dir, "manifest.raw.json")
    if write and not os.path.exists(rpath):
        shutil.copy(mpath, rpath)
    src = rpath if os.path.exists(rpath) else mpath
    raw = json.load(open(src))
    report, accepted = {}, []
    lay = layout_issues(root, agent_dir, src) if layout else {}
    if lay.get("_probe"):   # not tied to one diagram: fail them all instead of passing open
        for d in raw:
            lay.setdefault(d.get("id"), []).append(lay["_probe"][0])
    for d in raw:
        sp = os.path.join(agent_dir, d.get("svg", ""))
        if not d.get("svg") or not os.path.isfile(sp):
            report[d.get("id")] = {"ok": False, "errors": ["svg file missing"], "removed": [], "unverified_ratio": 1}
            continue
        r = validate_diagram(root, d, open(sp, encoding="utf-8").read())
        if layout and r["ok"] and lay.get(d["id"]):
            r["errors"] += ["layout: " + e for e in lay[d["id"]][:12]]
            r["ok"] = False
        if r["ok"]:
            accepted.append(r["diagram"])
        report[d["id"]] = {k: r[k] for k in ("ok", "errors", "removed", "unverified_ratio")}
    if write:
        json.dump(sorted(accepted, key=lambda x: x.get("order", 0)), open(mpath, "w"), indent=1, ensure_ascii=False)
        json.dump(report, open(os.path.join(agent_dir, "validation.json"), "w"), indent=1, ensure_ascii=False)
    return report


if __name__ == "__main__":
    rep = validate_all(os.path.abspath(sys.argv[1]), layout="--no-layout" not in sys.argv, write="--check" not in sys.argv)
    for k, v in rep.items():
        print(("PASS " if v["ok"] else "FAIL ") + k, f"unverified={v['unverified_ratio']:.0%} removed_anchors={len(v['removed'])}", "; ".join(v["errors"])[:300])
    if "--check" in sys.argv and not all(v["ok"] for v in rep.values()):
        sys.exit(1)   # --check is the agent's self-check and `bree architecture check`: a FAIL must not read as success
