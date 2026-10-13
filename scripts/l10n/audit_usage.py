#!/usr/bin/env python3
"""Classify Resources/Localizable.xcstrings keys as used or unused.

A key is USED when its exact text appears as a token in Sources/, CLI/, Packages/,
TunnelExtension/ or bree-tui/ (build dirs excluded), or when a string literal in code
builds a key family (interpolation with a static part, or a trailing-dot prefix).
Conservative by design: comments and docs count as usage.

Outputs (default /tmp/l10n): unused.txt, used-missing-tr.json, audit-report.txt
"""
import argparse, json, os, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCAN_DIRS = ["Sources", "CLI", "Packages", "TunnelExtension", "bree-tui"]
EXTS = {".swift", ".m", ".mm", ".h", ".json", ".py", ".rs", ".ts", ".tsx", ".js", ".md",
        ".plist", ".sh", ".toml", ".yml", ".yaml", ".txt", ".kt", ".java"}
SKIP_DIRS = {".build", "target", "node_modules", ".git", "DerivedData", "build", "__pycache__"}
TOKEN = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.\-:]*")
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
LOC_CTX = re.compile(r"(localized:|(?<![A-Za-z])key:|(?:title|label|subtitle|message|description)Key:|LocalizedStringKey\(|NSLocalizedString\(|bundle:\s*\w+,)\s*$")
INTERP = re.compile(r"\\\((?:[^()]|\([^()]*\))*\)")  # \( ... ) with one nesting level


def walk():
    for d in SCAN_DIRS:
        for dp, dns, fns in os.walk(ROOT / d):
            dns[:] = [x for x in dns if x not in SKIP_DIRS]
            for fn in fns:
                p = Path(dp) / fn
                if p.suffix in EXTS and not fn.endswith(".xcstrings"):
                    yield p


def families(lit):
    """Regex for a literal that interpolates, or prefix for one ending with '.'."""
    if "\\(" in lit:
        parts = INTERP.split(lit)
        static = "".join(parts)
        if "." not in static or len(parts[0]) < 3 and not parts[-1].startswith("."):
            return None
        # require a dotted static portion that is not just a bare suffix like ".title"
        if not parts[0] and len(parts) > 1 and not any("." in p[1:] for p in parts):
            return None
        rx = ".+?".join(re.escape(p) for p in parts)
        return ("rx", rx, lit)
    if lit.endswith(".") and lit.count(".") >= 2 and re.fullmatch(r"[A-Za-z0-9_.\-]+", lit):
        return ("prefix", lit, lit)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", default=str(ROOT / "Resources/Localizable.xcstrings"))
    ap.add_argument("--out", default="/tmp/l10n")
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    cat = json.load(open(a.catalog, encoding="utf-8"))["strings"]

    tokens, fams = set(), {}
    for p in walk():
        try:
            txt = p.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        tokens.update(TOKEN.findall(txt))
        tokens.update(t.rstrip(".:-") for t in TOKEN.findall(txt))  # "see foo.bar:" in comments
        if p.suffix == ".swift" and "/Tests/" not in str(p):
            for m in LITERAL.finditer(txt):
                # only literals in a localization context; otherwise log tags/RPC names
                # like "feed.\(id)" or "browser.\(sub)" would mark whole prefixes used
                if " " in m.group(1) or not LOC_CTX.search(txt[max(0, m.start() - 60):m.start()]):
                    continue
                f = families(m.group(1))
                if f:
                    fams.setdefault((f[0], f[1]), set()).add(f[2])
    rxs = [(re.compile("^" + k[1] + "$"), k, v) for k, v in fams.items() if k[0] == "rx"]
    prefixes = [(k[1], v) for k, v in fams.items() if k[0] == "prefix"]

    used, why, unused = {}, {}, []
    for key in cat:
        if key in tokens:
            used[key] = "literal"; continue
        hit = next((f"pattern {r[1][1]}" for r in rxs if r[0].match(key)), None)
        if not hit:
            pf = next((p for p, _ in prefixes if key.startswith(p)), None)
            hit = f"prefix {pf}" if pf else None
        if hit:
            used[key] = hit
        else:
            unused.append(key)

    def tr_ok(entry):
        tr = entry.get("localizations", {}).get("tr")
        if not tr:
            return "missing"
        states = []
        def walk_u(n):
            if isinstance(n, dict):
                if "stringUnit" in n: states.append(n["stringUnit"].get("state"))
                for v in n.values(): walk_u(v)
        walk_u(tr)
        return "ok" if states and all(s == "translated" for s in states) else "not-translated"

    def en_src(entry):
        en = entry["localizations"]["en"]
        if "stringUnit" in en and "variations" not in en and "substitutions" not in en:
            return en["stringUnit"]["value"]
        return en  # plural/substitution structure, keep verbatim

    missing, nontr = {}, {}
    for key in cat:
        if key in used:
            s = tr_ok(cat[key])
            if s == "ok": continue
            rec = {"en": en_src(cat[key]), "comment": cat[key].get("comment", ""), "tr_status": s}
            if s == "not-translated":
                rec["tr_current"] = cat[key]["localizations"]["tr"]
            (missing if s == "missing" else nontr)[key] = rec

    (out / "unused.txt").write_text("\n".join(unused) + "\n", encoding="utf-8")
    allneed = {**missing, **nontr}
    json.dump(allneed, open(out / "used-missing-tr.json", "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    # unused-but-dynamic review hints: dynamic patterns that matched many keys
    dyn = {}
    for k, w in used.items():
        if w != "literal": dyn.setdefault(w, []).append(k)
    rep = [f"catalog keys: {len(cat)}", f"used: {len(used)} (literal {sum(1 for w in used.values() if w=='literal')}, dynamic {sum(1 for w in used.values() if w!='literal')})",
           f"unused: {len(unused)}", f"used & tr missing: {len(missing)}", f"used & tr not translated: {len(nontr)}", "", "dynamic families:"]
    for w, ks in sorted(dyn.items(), key=lambda x: -len(x[1])):
        rep.append(f"  {len(ks):5d} {w}  e.g. {ks[0]}")
    (out / "audit-report.txt").write_text("\n".join(rep) + "\n")
    print("\n".join(rep[:7]))


if __name__ == "__main__":
    main()
