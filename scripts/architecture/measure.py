#!/usr/bin/env python3
"""Score generated flows against gold/flows.json.  measure.py <dir with current.architecture.json> [gold.json]

Per flow and run: step precision (generated, non-optional steps that are gold), step recall (gold steps found),
order agreement (pairwise concordance on shared steps), entry correct. Reports median and range over runs.
Boards are matched to gold flows by order (the --flow order used in the run).
"""
import json, os, re, statistics, sys

HERE = os.path.dirname(os.path.abspath(__file__))
GATE = {"precision": 0.8, "recall": 0.8, "order": 0.9, "label": 1.0}


def gid(s):
    return s if isinstance(s, str) else s["id"]


def to_gold_ids(run, g):
    """Generated steps -> gold step ids. Symbol steps match by the anchor tail; inline steps (anchor `path:parent#line`) by parent + regex
    over their source line; decision (fork) steps are not scored."""
    inl = {x["id"]: x for x in g["steps"] + g.get("inline", []) if isinstance(x, dict)}
    out = []
    for a in run["steps"]:
        tail = a.rsplit(":", 1)[-1]
        if "#fork" in tail:
            continue
        if "#" in tail:
            par = tail.split("#")[0]
            hit = next((i for i, x in inl.items() if x["in"] == par and re.search(x["re"], run.get("srcs", {}).get(a, ""))), None)
            out.append(hit or tail)
        else:
            out.append(tail)
    return out


def label_check(run, g, ids):
    """Meaning check. -> (score, problems) or (None, []) when the run has no labels. A label must hit one `must` word prefix and may not
    START with a `not` word (an opposite verb). Steps absent from the run are not checked (recall covers them)."""
    lab = run.get("labels")
    if not lab:
        return None, []
    by = dict(zip([a for a in run["steps"] if "#fork" not in a], ids))
    byid = {i: lab.get(a, "") for a, i in by.items()}
    bad, n = [], 0
    for sid, spec in g.get("must_label", {}).items():
        if sid not in byid:
            continue
        n += 1
        words = re.findall(r"[a-z0-9/-]+", byid[sid].lower())
        if spec.get("must") and not any(w.startswith(m) for w in words for m in spec["must"]):
            bad.append(f"{sid}: '{byid[sid]}' lacks one of {spec['must'][:4]}")
        elif words and any(words[0].startswith(m) for m in spec.get("not", [])):
            bad.append(f"{sid}: '{byid[sid]}' starts with the opposite verb '{words[0]}'")
    return 1 - len(bad) / max(n, 1), bad


def name_check(run, g, ids, names):
    """0-token check of the short node names (names.json sidecar). A step with a must_label spec: the name must contain one `must` stem and no
    word of it may start with an opposite (`not`) stem. -> (checked, problems)"""
    by = dict(zip([a for a in run["steps"] if "#fork" not in a], ids))
    bad, n = [], 0
    for a, sid in sorted(by.items()):
        spec = g.get("must_label", {}).get(sid)
        if not spec or a not in names:
            continue
        n += 1
        words = re.findall(r"[a-z0-9/-]+", names[a].lower())
        if any(w.startswith(m) for w in words for m in spec.get("not", [])):
            bad.append(f"{sid}: name '{names[a]}' contains an opposite verb")
        elif spec.get("must") and not any(w.startswith(m) for w in words for m in spec["must"]):
            bad.append(f"{sid}: name '{names[a]}' lacks one of {spec['must'][:4]}")
    return n, bad


def score(gen, g):
    steps, opt = [gid(x) for x in g["steps"]], set(g.get("optional", []))
    gen = list(dict.fromkeys(gen))
    core = [s for s in gen if s not in opt]
    hit = [s for s in gen if s in steps]
    shared = [s for s in gen if s in steps]
    pairs = [(a, b) for i, a in enumerate(shared) for b in shared[i + 1:]]
    ok = sum(steps.index(a) < steps.index(b) for a, b in pairs)
    return {"precision": len([s for s in core if s in steps]) / max(len(core), 1), "recall": len(hit) / len(steps),
            "order": ok / len(pairs) if pairs else 0.0, "entry": bool(gen) and gen[0] == g["entry"]}


def main():
    d = json.load(open(os.path.join(sys.argv[1], "current.architecture.json")))
    gold = json.load(open(sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "gold", "flows.json")))["flows"]
    res = {}
    for (key, g), f in zip(gold.items(), d["flows"]):
        runs = f.get("runs") or [{"steps": [s["anchor"] for s in f["steps"]], "pairs": f["stats"]["pairs"], "pairs_solid": f["stats"]["pairs_solid"]}]
        runs = [dict(r) for r in runs]
        # the drawn board is run 1: its labels/sources come from the steps (older JSON stores labels only there)
        runs[0].setdefault("labels", {s["anchor"]: s["label"] for s in f["steps"]})
        runs[0].setdefault("srcs", {s["anchor"]: s["src"] for s in f["steps"] if s.get("src")})
        rows, bads = [], []
        for r in runs:
            ids = to_gold_ids(r, g)
            m = score(ids, g)
            m["solid"] = r["pairs_solid"] / max(r["pairs"], 1)
            m["label"], bad = label_check(r, g, ids)
            bads += bad
            rows.append(m)
        med = lambda k: statistics.median(x[k] for x in rows if x[k] is not None)
        rng = lambda k: (min(x[k] for x in rows if x[k] is not None), max(x[k] for x in rows if x[k] is not None))
        res[key] = {"title": f["title"], "runs": len(rows), "entry": f"{sum(x['entry'] for x in rows)}/{len(rows)}",
                    **{k: {"median": round(med(k), 2), "range": [round(v, 2) for v in rng(k)]} for k in ("precision", "recall", "order", "solid", "label")}, "label_problems": sorted(set(bads))}
        res[key]["pass"] = all(res[key][k]["median"] >= v for k, v in GATE.items()) and (all(x["entry"] for x in rows) or not g.get("entry_required"))
        print(f"{key:12} runs={len(rows)} entry={res[key]['entry']}  " + "  ".join(
            f"{k}={res[key][k]['median']:.2f} [{res[key][k]['range'][0]:.2f}-{res[key][k]['range'][1]:.2f}]" for k in ("precision", "recall", "order", "solid", "label")),
            "PASS" if res[key]["pass"] else "FAIL")
        for b in res[key]["label_problems"]:
            print("    label:", b)
    tot = d["generation"]["totals"]
    print("tokens", tot["tokens_in"] + tot["tokens_out"], "cost", tot["cost_usd"])
    json.dump(res, open(os.path.join(sys.argv[1], "gold-score.json"), "w"), indent=1)
    npath = os.path.join(sys.argv[1], "names.json")  # appended after the lines above, so a diff of the old output stays empty
    if os.path.exists(npath):
        names = json.load(open(npath))["names"]
        for (key, g), f in zip(gold.items(), d["flows"]):
            run = {"steps": [s["anchor"] for s in f["steps"]], "srcs": {s["anchor"]: s["src"] for s in f["steps"] if s.get("src")}}
            n, bad = name_check(run, g, to_gold_ids(run, g), names)
            print(f"names {key:12} checked={n} problems={len(bad)}")
            for b_ in bad:
                print("    name:", b_)


if __name__ == "__main__":
    main()
