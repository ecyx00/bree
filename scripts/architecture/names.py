#!/usr/bin/env python3
"""Short node names for the drawn boards: one haiku call over the existing step labels, cached by an input hash.

  names.py <dir with current.architecture.json>      writes <dir>/names.json (sidecar, the architecture JSON is never touched)

The label (a sentence) stays as `detail` in the click panel; the name is the 2-3 word imperative drawn in the node. A label whose
step has a must_label verb in gold/flows.json keeps that verb in the name (the prompt says so, measure.py checks it, 0 tokens).
Cap 10k tokens in total, usage is logged in the sidecar. Same labels -> same hash -> no call.

  names.py <dir> --only "<anchor>"      re-name that one step (gold verb hint in the prompt, cap 3k tokens), other names untouched
A name marked in the sidecar's "manual" map is hand-set: a full run never overwrites it.

`about` (card text): the same run then asks one more haiku call (cap 15k tokens for all boards) for 2-3 plain sentences per step, from the
step's signature, docstring, body and the line that calls it. Cached per step by an input hash (sidecar "about" / "about_in"). A 0-token
gate drops an `about` that is over 240 chars, holds code, or names an identifier absent from that step's signature/docstring/body; the card
then keeps the detail line.
"""
import hashlib, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
CAP = 10000
ABOUT_CAP = 15000   # tokens, all boards together, one full refresh of the `about` texts


def collect(doc):
    return {s["anchor"]: s["label"] for s in doc["nodes"] if s["kind"] == "step"}


def input_hash(labels):
    return hashlib.sha256(json.dumps(sorted(labels.items())).encode()).hexdigest()[:16]


def must_verbs(doc):
    """anchor -> must-verb stems from gold must_label (flows matched to boards by order, like measure.py)."""
    gpath = os.path.join(HERE, "gold", "flows.json")
    out = {}
    if not os.path.exists(gpath):
        return out
    gold = json.load(open(gpath))["flows"]
    for (_, g), f in zip(gold.items(), doc["flows"]):
        for s in f["steps"]:
            tail = s["anchor"].rsplit(":", 1)[-1]
            spec = g.get("must_label", {}).get(tail)
            if spec and spec.get("must"):
                out[s["anchor"]] = spec["must"][:6]
    return out


def one(d, doc, anchor):
    path = os.path.join(d, "names.json")
    side = json.load(open(path))
    lab = collect(doc)[anchor]
    must = must_verbs(doc).get(anchor)
    row = {"label": lab, **({"keep_a_verb_starting_with": must} if must else {})}
    prompt = ("Give this step a node name for a diagram: at most 3 words, imperative, no code, no articles, 24 characters at most. "
              "The name must contain a verb that starts with one of the keep_a_verb_starting_with stems and say what the step decides or picks. "
              "Faithfully summarise only this step.\n" + json.dumps(row) + '\nReturn {"name":"..."}.')
    sys.path.insert(0, HERE)
    import gen
    out, log = gen.llm(prompt, "haiku", "names-one")
    tok = log.get("tokens_in", 0) + log.get("tokens_out", 0)
    print("names --only call", {k: log.get(k) for k in ("ok", "tokens_in", "tokens_out")}, "->", (out or {}).get("name"))
    if not out or tok > 3000:
        sys.exit(f"call failed or over the 3k cap ({tok} tokens)")
    side["names"][anchor] = " ".join(str(out["name"]).split())[:24]
    side.setdefault("usage_one", []).append({"anchor": anchor, "tokens": tok})
    json.dump(side, open(path, "w"), indent=1, sort_keys=True)


def step_context(g, doc, anchor, st, flow):
    """(text shown to the model, text the grounding gate allows) for one step."""
    sym, path = anchor.rsplit(":", 1)[-1].split("#")[0], st["path"]
    L = g.lines(path)
    sp = g.span(sym, path)
    full = "\n".join(L[sp[0] - 1:sp[1]]) if sp else ""
    parent = ""
    for o in flow["steps"]:
        osym = o["anchor"].rsplit(":", 1)[-1].split("#")[0]
        osp = g.span(osym, o["path"]) if osym != sym else None
        if osp:
            for ln in g.lines(o["path"])[osp[0] - 1:osp[1]]:
                if re.search(r"\b" + re.escape(sym) + r"\b", ln):
                    parent = ln.strip()[:140]
                    break
        if parent:
            break
    row = {"signature": g.sig_line(sym, path), "doc": g.doc(path, sp[0]) if sp else "", "body": g.body_lines(sym, path, 4, 76), "called_in": parent}
    if "#" in anchor.rsplit(":", 1)[-1]:  # inline step: no function of its own, the lines around its own line say what it does
        i = st["line"]
        row["this_step_lines"] = [x.strip()[:80] for x in L[max(0, i - 3):i + 2] if x.strip()]
    return row, full


IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def about_ok(text, allowed):
    """0-token gate. -> (ok, reason)."""
    if not isinstance(text, str) or not text.strip():
        return False, "empty"
    if len(text) > 240:
        return False, "over 240 chars"
    if re.search(r"[`{}\[\]=;<>|\\]|\(\)|->|::|\bdef \b|\.py\b|\w/\w|\w\.\w", text):
        return False, "code-like characters"
    if re.search(r"cut off|given body|not shown|provided|unclear|snippet", text, re.I):
        return False, "talks about the prompt"
    if not 1 <= len(re.findall(r"[.!?](?:\s|$)", text)) <= 3:
        return False, "not 1-3 sentences"
    have = set(IDENT.findall(allowed))
    for w in IDENT.findall(text):
        if ("_" in w or re.search(r"[a-z][A-Z]", w)) and w not in have:
            return False, "identifier not in the step: " + w
    return True, ""


def abouts(d, doc, side):
    """Fill side["about"] for steps whose context changed; gate every text. Prints tokens and the pass count."""
    sys.path.insert(0, HERE)
    import gen
    g = gen.Graph(os.path.dirname(os.path.abspath(d)))
    ctx, allowed, step_of = {}, {}, {}
    for f in doc["flows"]:
        for st in f["steps"]:
            a = st["anchor"]
            if a not in ctx:
                ctx[a], allowed[a] = step_context(g, doc, a, st, f)
                ctx[a]["step"] = st["label"]
                step_of[a] = st
    hs = {a: hashlib.sha256(json.dumps(ctx[a], sort_keys=True).encode()).hexdigest()[:16] for a in ctx}
    side.setdefault("about", {}); side.setdefault("about_in", {})
    todo = sorted(a for a in ctx if side["about_in"].get(a) != hs[a])
    if todo:
        rows = [{"id": i, **ctx[a]} for i, a in enumerate(todo)]
        prompt = ("For each step of a software flow write `about`: 2 or 3 plain sentences, at most 230 characters in total, for a reader who has not seen the code. "
                  "Say what the step does, why it is there, and what goes in and what comes out. Use ordinary words only: no code, no function or variable names, "
                  "no file names, no quotes. Use only what the given signature, doc, body and called_in show; do not guess.\n"
                  + json.dumps(rows) + '\nReturn {"about":{"<id>":"text"}} for every id.')
        assert len(prompt) // 3 < ABOUT_CAP, "about prompt over cap"
        out, log = gen.llm(prompt, "haiku", "about")
        tok = log.get("tokens_in", 0) + log.get("tokens_out", 0)
        print("about prompt chars", len(prompt)); print("about call", {k: log.get(k) for k in ("ok", "tokens_in", "tokens_out", "cost_usd")}, f"for {len(todo)} steps, cap {ABOUT_CAP}")
        if not out or tok > ABOUT_CAP:
            sys.exit(f"about call failed or over the 15k cap ({tok} tokens): {log}")
        side.setdefault("usage_about_log", []).append({"steps": len(todo), "tokens": tok})
        side["usage_about"] = {"tokens_in": log.get("tokens_in", 0), "tokens_out": log.get("tokens_out", 0), "cost_usd": log.get("cost_usd", 0), "cap": ABOUT_CAP}
        for k, v in (out.get("about") or {}).items():
            if k.isdigit() and int(k) < len(todo):
                a = todo[int(k)]
                side["about_in"][a] = hs[a]
                side["about"][a] = " ".join(str(v).split())
    ok, bad = {}, {}
    for a in ctx:
        good, why = about_ok(side["about"].get(a), allowed[a])
        (ok if good else bad)[a] = why + (": " + str(side["about"].get(a))[:200] if not good and side["about"].get(a) else "")
    side["about_gate"] = {"pass": len(ok), "total": len(ctx), "failed": bad}
    for a in bad:
        side["about"].pop(a, None)  # the card keeps the detail line; the hash stays so a failure is not retried (and re-billed) until the step changes
    print(f"about gate: {len(ok)}/{len(ctx)} pass", {a: w for a, w in bad.items()})


def main():
    d = sys.argv[1]
    doc = json.load(open(os.path.join(d, "current.architecture.json")))
    if len(sys.argv) > 3 and sys.argv[2] == "--only":
        return one(d, doc, sys.argv[3])
    labels = collect(doc)
    h = input_hash(labels)
    path = os.path.join(d, "names.json")
    if os.path.exists(path) and json.load(open(path)).get("input_hash") == h:
        print("names cached", h)
        side = json.load(open(path))
        abouts(d, doc, side)
        json.dump(side, open(path, "w"), indent=1, sort_keys=True)
        return
    must = must_verbs(doc)
    rows = [{"id": i, "label": lab, **({"keep_a_verb_starting_with": must[a]} if a in must else {})} for i, (a, lab) in enumerate(sorted(labels.items()))]
    prompt = ("Give each step a node name for a diagram: at most 3 words, imperative, no code, no articles, 24 characters at most. "
              "Start with the same verb as the label (the label's first word); where keep_a_verb_starting_with is given, the name must contain "
              "a verb that starts with one of those stems. A decision question becomes an imperative like \"Pick read path\". The name must faithfully summarise only that step (never blend words from different clauses, never an odd conjunction like \"then\").\n"
              + json.dumps(rows) + '\nReturn {"names":{"<id>":"name"}} for every id.')
    assert len(prompt) // 4 < CAP, "prompt over cap"
    sys.path.insert(0, HERE)
    import gen
    out, log = gen.llm(prompt, "haiku", "names")
    tok = log.get("tokens_in", 0) + log.get("tokens_out", 0)
    print("names call", {k: log.get(k) for k in ("ok", "tokens_in", "tokens_out", "cost_usd")})
    if not out or tok > CAP:
        sys.exit(f"names call failed or over cap ({tok} tokens): {log}")
    ids = sorted(labels)
    nm = {ids[int(k)]: " ".join(str(v).split())[:24] for k, v in out["names"].items() if k.isdigit() and int(k) < len(ids)}
    old = json.load(open(path)) if os.path.exists(path) else {}
    manual = old.get("manual", {})
    nm.update({a: old["names"][a] for a in manual if a in old.get("names", {})})
    keep = {k: old[k] for k in ("about", "about_in", "usage_about", "about_gate") if k in old}
    json.dump({"input_hash": h, "model": "haiku", "names": nm, **keep, **({"manual": manual} if manual else {}), "usage": {"tokens_in": log.get("tokens_in", 0), "tokens_out": log.get("tokens_out", 0),
               "cost_usd": log.get("cost_usd", 0), "cap": CAP}}, open(path, "w"), indent=1, sort_keys=True)
    print("wrote", path, len(nm), "names")
    side = json.load(open(path))
    abouts(d, doc, side)
    json.dump(side, open(path, "w"), indent=1, sort_keys=True)


if __name__ == "__main__":
    main()
