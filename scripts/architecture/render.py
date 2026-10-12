"""The page shell of the architecture views. Deterministic, no-JS SVG renderer for the architecture JSON model (schema bree-architecture/2).

Visual grammar follows diagram-design (MIT, Cathryn Lavery; see LICENSE.diagram-design): swimlane for a flow with 2+ lanes
(horizontal lanes, lane labels in a left column, flow runs left to right), the same grammar without lane chrome for one actor,
architecture for the module overview (flow top to bottom, zone boundary with a masked label). Nodes are a short centred name
over one mono sub-label, edges are orthogonal with r=8 corners, only meaningful edges carry a masked uppercase label, the
accent marks the entry node only, the legend sits at the bottom, 4 px grid, 40 px outer margin.

Colours come from CSS variables defined in template.html (class names only here), fonts are system fonts. Sizes are SVG units
and deliberately above diagram-design's 8/9 px roles: the smallest text is 11 so it stays legible when the board is fitted.

Layout is pure arithmetic on the model (no LLM, no randomness, no timestamps, every set is sorted before iteration).

The boards themselves live in views/ (one module per view, registry in views/__init__.py); the drawing kit is draw.py. This file only
collects the boards, builds the card data and fills template.html (grouped nav, card, zoom and pan are the same for every board).
"""
import json, os, copy

import views
from views.agent import agent_dir
from draw import HERE, esc, humanize

__all__ = ["render_page"]

CHANGES = "delta"
TYPE_OF = (("flow-", "flow"), ("seq-", "sequence"), ("data-", "data flow"))  # board id prefix -> view type shown after the flow's name


def run_date(root):
    """Date (YYYY-MM-DD) the agent boards were written: run.json 'at' next to the manifest. None when absent."""
    try:
        return json.load(open(os.path.join(agent_dir(root), "run.json"), encoding="utf-8"))["at"][:10]
    except (OSError, ValueError, KeyError, TypeError):
        return None

RICH = ("kind", "summary", "what", "why", "connects", "code", "watch", "unverified")  # node keys of the agent-authored boards (all optional)


def fix_labels(doc):
    """A module the naming pass skipped has its id as label ('hm_term_py'); show the humanized file stem ('Term') instead. Returns a copy."""
    doc = copy.deepcopy(doc)
    for x in doc["nodes"]:
        if x["kind"] == "module" and x["label"] == x["id"].partition(":")[2] and x.get("sources"):
            x["label"] = humanize(x["sources"][0]["path"])
    return doc


def page_lang(doc, root=None, lang=None):
    """Content language of the page: the explicit argument, else the agent manifest's, else the document's, else en. Chrome strings are the host's (window.breeStrings)."""
    return (lang or views.agent.manifest_lang(root) or doc.get("lang") or "en").strip() or "en"


def render_page(doc, names=None, about=None, root=None, budget=None, registry=None, arch_dir=None, lang=None):
    doc = fix_labels(doc)
    lang = page_lang(doc, root, lang)
    ctx = views.Ctx(doc, root, names, about, budget, arch_dir)
    boards = views.collect(ctx, registry)
    info, flows_of = {}, {}
    for b in boards:
        for nd in b.nodes:
            src = nd.get("sources") or ([{"path": nd["anchor"].split("#")[0]}] if nd.get("anchor") else [])
            info[nd["id"]] = {"name": nd["name"], "detail": nd.get("detail", ""), "about": nd.get("about", ""), "role": nd.get("role", ""),
                              "board": b.id, "module": nd.get("module"), "actor": nd.get("actor"), "sources": src, "anchor": nd.get("anchor", ""),
                              "lane": nd.get("lane", ""), "sym": nd.get("sym") or nd.get("anchor", "").partition("#")[2],
                              **{k: nd[k] for k in RICH if nd.get(k)}}  # optional authored keys: absent on deterministic boards, which fall back to `about`
            if b.id.startswith("flow-") and nd.get("module") and b.id not in flows_of.setdefault(nd["module"], []):
                flows_of[nd["module"]].append(b.id)
    flow_title = {x.id: x.title for x in boards}
    for b in boards:  # a Facts board named only by its flow title ("agent hook") gets its view type, so no two rows in the contents list read alike
        kind = next((k for p, k in TYPE_OF if b.id.startswith(p)), None)
        base = flow_title.get("flow-" + b.id.partition("-")[2]) if kind else None
        if kind and base:
            b.title = f"{base} \u00b7 {kind}"
    agent = run_date(root) if views.GROUPS and views.GROUPS[-1] == views.FACTS else None
    shown = [b for b in boards if b.id != CHANGES]  # the Changes tab loads #delta: one Changes surface, so the board is not in the Current list
    groups = [{"name": g, "boards": [b.id for b in shown if b.group == g]} for g in views.GROUPS]
    groups = [g for g in groups if g["boards"]]
    data = json.dumps({"repo": doc["repo"], "lang": lang, "groups": groups,
                       "boards": {b.id: {"title": b.title, "note": " ".join(b.notes), "purpose": b.purpose, "entry": b.entry, "group": b.group, "agent": bool(agent) and b.group != views.FACTS} for b in boards},
                       "agent": {"at": agent} if agent else None, "facts": views.FACTS if agent else None,
                       "info": info, "flows_of": flows_of}, sort_keys=True).replace("</", "<\\/")
    divs = "\n".join(f'<section class="b" id="b-{esc(b.id)}" hidden>' + (f"<style>{b.css}</style>" if b.css else "") + b.svg + "</section>" for b in boards)
    tpl = open(os.path.join(HERE, "template.html"), encoding="utf-8").read()
    return tpl.replace('<html lang="en">', f'<html lang="{esc(lang)}">', 1).replace("<!--BOARDS-->", divs).replace("/*DATA*/", data).replace("{{TITLE}}", esc(doc["repo"]))
