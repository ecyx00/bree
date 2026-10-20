#!/usr/bin/env python3
"""Trial: draw one verified flow with the diagram-design plugin (swimlane, dark), then check it.

usage: dd_draw.py <model.json> <flow-id> <out-dir> --model haiku|sonnet [--plugin /tmp/dd-ref/diagram-design]
The plugin content is treated as data; its self_check.py runs under `python3 -I`.
"""
import argparse, json, os, re, subprocess, sys, tempfile, pathlib

PAPER, INK = "#262624", "#ECEBE6"
SERIF, SANS, MONO = "ui-serif, Georgia, serif", "-apple-system, system-ui, sans-serif", "ui-monospace, Menlo, monospace"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_svg import browser_or_exit
CHROME = browser_or_exit("dd_draw.py")


def load(model_json, flow_id):
    d = json.load(open(model_json))
    f = next(b for b in d["flows"] if b["id"] == flow_id)
    names = json.load(open(pathlib.Path(model_json).parent / "names.json")).get("names", {})
    nodes = {n["anchor"]: n["id"] for n in d["nodes"] if n["board"] == flow_id and n.get("anchor")}
    steps = []
    for s in f["steps"]:
        steps.append({"id": nodes.get(s["anchor"], s["anchor"]), "name": s.get("name") or names.get(s["anchor"]) or s["label"],
                      "label": s["label"], "lane": s["actor"], "order": s["order"],
                      "fork": s["fork"], "branch": s["arm"], "decision_arms": (s.get("decision") or {}).get("arms")})
    lanes = list(dict.fromkeys(s["lane"] for s in steps))
    return f, steps, lanes


def prompt(f, steps, lanes):
    fork = next((s for s in steps if s["decision_arms"]), None)
    spec = {"title": f["title"], "lanes_top_to_bottom": lanes, "steps_in_order": [
        {k: s[k] for k in ("id", "name", "label", "lane", "fork", "branch") if s[k] is not None} for s in steps],
        "fork": {"at_step": fork["id"], "branch_labels": fork["decision_arms"]} if fork else None,
        "focal": {"entry": steps[0]["id"], "output": steps[-1]["id"]}}
    return f"""Use the diagram-design skill. Draw this flow as its SWIMLANE type, DARK variant (assets/example-swimlane-dark.html is the reference; read it and the swimlane reference, do not read other files).
Return ONLY the complete single-file HTML in one ```html fence, no other text. Do not write files.

Hard rules, the content is already verified:
- Exactly these steps: do not add, drop, rename or reorder any. Node title = "name"; put "label" as the small sub-line (shorten only by truncating with an ellipsis).
- One lane per entry of lanes_top_to_bottom, in that order. Each step sits in its "lane".
- Every step node is one SVG <g data-step="<id>"> wrapping its shapes and text, with the id copied exactly; each id occurs once. No other element gets data-step.
- Flow runs left to right in "order". The fork step is a decision node; its steps with branch 0 and branch 1 are the two branches, labelled on the edges with branch_labels (index = branch). The branches rejoin at the final step.
- Focal (accent) nodes: focal.entry and focal.output only.
- No external requests except the skill's Google Fonts link; no scripts.

SPEC:
{json.dumps(spec, indent=1)}"""


def call(model, p, plugin, out):
    r = subprocess.run(["claude", "-p", "--plugin-dir", plugin, "--output-format", "json", "--model", model,
                        "--allowedTools", "Read", "--add-dir", plugin, "--permission-mode", "dontAsk"],
                       input=p, capture_output=True, text=True, cwd=out, timeout=900)
    j = json.loads(r.stdout)
    (out / f"{model}.raw.json").write_text(json.dumps(j, indent=1))
    return j


def extract(text):
    m = re.search(r"```html\s*(.*?)```", text, re.S) or re.search(r"(<!doctype html.*</html>)", text, re.S | re.I)
    return m.group(1).strip() if m else None


def post(html):
    html = re.sub(r"<link[^>]*(fonts\.googleapis|fonts\.gstatic)[^>]*>\s*", "", html)
    html = re.sub(r"@import[^;]*fonts\.googleapis[^;]*;", "", html)
    for pat, rep in ((r"'Instrument Serif'", "ui-serif"), (r"'Geist Mono'", "ui-monospace"), (r"'Geist'", "-apple-system")):
        html = re.sub(pat, rep, html)
    html = re.sub(r"(--font-serif:\s*)[^;]+;", rf"\g<1>{SERIF};", html)
    html = re.sub(r"(--font-sans:\s*)[^;]+;", rf"\g<1>{SANS};", html)
    html = re.sub(r"(--font-mono:\s*)[^;]+;", rf"\g<1>{MONO};", html)
    for old, new in (("#2d3142", PAPER), ("#f5f5f5", INK)):
        html = re.sub(old, new, html, flags=re.I)
    return html


def coverage(html, steps):
    res = {}
    ids = re.findall(r'data-step="([^"]*)"', html)
    want = [s["id"] for s in steps]
    res["each_id_once"] = sorted(ids) == sorted(want) and len(ids) == len(set(ids))
    pos = {}
    for sid in want:
        m = re.search(r'<g\b[^>]*data-step="%s"[^>]*>(.*?)</g>' % re.escape(sid), html, re.S)
        if not m:
            continue
        tr = re.search(r'<g\b[^>]*data-step="%s"[^>]*transform="translate\(([-\d.]+)[ ,]+([-\d.]+)' % re.escape(sid), html)
        ox, oy = (float(tr[1]), float(tr[2])) if tr else (0.0, 0.0)
        c = re.search(r'<(?:rect|polygon|path)\b[^>]*?(?:x="([-\d.]+)"[^>]*?y="([-\d.]+)"|points="([-\d.]+)[ ,]+([-\d.]+)|d="M\s*([-\d.]+)[ ,]+([-\d.]+))', m[1])
        if c:
            g = [v for v in c.groups() if v is not None]
            pos[sid] = (float(g[0]) + ox, float(g[1]) + oy)
    if len(pos) == len(want):
        xs = [pos[i][0] for i in want]
        ys = [pos[i][1] for i in want]
        res["order_left_to_right"] = all(a <= b + 1 for a, b in zip(xs, xs[1:]))
        res["order_top_to_bottom"] = all(a <= b + 1 for a, b in zip(ys, ys[1:]))
        res["order_ok"] = res["order_left_to_right"] or res["order_top_to_bottom"]
    else:
        res["order_ok"] = False
    text = html.lower()
    arms = next((s["decision_arms"] for s in steps if s["decision_arms"]), [])
    res["fork_branch_labels"] = all(a.lower() in text for a in arms)
    return res


def network(html_path):
    """0 requests: static scan plus a Chrome net-log of the real load."""
    html = open(html_path).read()
    static = re.findall(r'(?:src|href|url\()\s*=?\s*["\']?(https?:)?//[^"\')\s>]+', html)
    log = pathlib.Path(tempfile.mkdtemp()) / "net.json"
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--disable-background-networking", f"--log-net-log={log}", "--virtual-time-budget=3000",
                    "--dump-dom", "file://" + os.path.abspath(html_path)], capture_output=True, timeout=60)
    http = [u for u in re.findall(r'"url":"(https?://[^"]+)"', log.read_text()) if log.exists()
            if not re.match(r"https?://(clients\d*|accounts|www|clientservices|translate|safebrowsingohttpgateway|csp)\.(google|withgoogle)", u)] if log.exists() else []
    return {"static_remote_refs": len(static), "chrome_http_requests": len(http), "ok": not static and not http}


def shot(html_path, png, width=1200):
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", f"--window-size={width},900",
                    "--force-device-scale-factor=2", f"--screenshot={png}", "file://" + os.path.abspath(html_path)],
                   capture_output=True, timeout=60)


def main():
    a = argparse.ArgumentParser()
    a.add_argument("model_json"); a.add_argument("flow"); a.add_argument("out")
    a.add_argument("--model", required=True); a.add_argument("--plugin", default="/tmp/dd-ref/diagram-design")
    a = a.parse_args()
    out = pathlib.Path(a.out); out.mkdir(parents=True, exist_ok=True)
    f, steps, lanes = load(a.model_json, a.flow)
    j = call(a.model, prompt(f, steps, lanes), a.plugin, out)
    u = j.get("usage", {})
    tok = {k: u.get(k, 0) for k in ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")}
    print("tokens", a.model, tok, "cost", j.get("total_cost_usd"), "turns", j.get("num_turns"), file=sys.stderr)
    html = extract(j.get("result", ""))
    if not html:
        print(json.dumps({"model": a.model, "error": "no html in result", "tokens": tok})); sys.exit(1)
    (out / f"{a.model}.raw.html").write_text(html)
    html = post(html)
    p = out / f"{a.model}.html"; p.write_text(html)
    sc = subprocess.run(["python3", "-I", f"{a.plugin}/skills/diagram-design/scripts/self_check.py", str(p)], capture_output=True, text=True)
    rep = {"model": a.model, "tokens": tok, "cost_usd": j.get("total_cost_usd"), "self_check": {"rc": sc.returncode, "out": (sc.stdout + sc.stderr)[-600:]},
           "coverage": coverage(html, steps), "network": network(p)}
    shot(p, out / f"{a.model}.png")
    (out / f"{a.model}.report.json").write_text(json.dumps(rep, indent=1))
    print(json.dumps(rep, indent=1))


if __name__ == "__main__":
    main()
