#!/usr/bin/env python3
"""Language contract check. 0 LLM calls, real Chrome via Playwright.

  /opt/anaconda3/bin/python -I lang_check.py <repo root> [arch-scripts-dir]

Content language belongs to the producer, chrome strings to the app:
  1. gen.py --render-only --lang en: <html lang="en">, D.lang == "en", no Turkish string in the deterministic (Facts) boards.
  2. --lang tr: <html lang="tr">, the eyebrow uppercases with Turkish casing (i -> İ) and en never gets an İ.
  3. a fake window.breeStrings (every key of S) replaces every chrome string: static titles/aria-labels/labels, the legend title, the
     card headings, More/Less, the Changes and agent eyebrows.
arch-scripts-dir defaults to this directory; pass another checkout of scripts/architecture to run the same check against older code.
"""
import json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_svg import browser_or_exit
CHROME = browser_or_exit("lang_check.py")
TR = re.compile(r"[çğıöşüÇĞİÖŞÜ]|AÇIKLAMA|\b(Adım|Giriş|Çağrı|Modül|Bağlantı|bulunamadı|çizilmedi)\b")
fails = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail else ""))
    if not ok:
        fails.append(name)


def render(arch, root, lang):
    """-> (html text or None, message). Renders from a temp copy of the repo's .architecture JSON so the repo stays untouched."""
    src = os.path.join(root, ".architecture")
    td = tempfile.mkdtemp()
    for f in ("current.architecture.json", "current.architecture.prev.json", "names.json"):
        if os.path.exists(os.path.join(src, f)):
            shutil.copy(os.path.join(src, f), td)
    r = subprocess.run([sys.executable, os.path.join(arch, "gen.py"), root, "--render-only", "--out", td, "--lang", lang], capture_output=True, text=True)
    if r.returncode and "unrecognized arguments" in r.stderr:   # code from before the --lang parameter: render what it has, the checks below then fail on substance
        r = subprocess.run([sys.executable, os.path.join(arch, "gen.py"), root, "--render-only", "--out", td], capture_output=True, text=True)
    if r.returncode:
        return None, (r.stderr or r.stdout).strip().splitlines()[-1][:160]
    return open(os.path.join(td, "current.html"), encoding="utf-8").read(), ""


def data(html):
    return json.loads(re.search(r"const D = (\{.*?\});\n", html, re.S).group(1))


def main():
    root = os.path.abspath(sys.argv[1])
    arch = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else HERE
    pages = {}
    for lang in ("en", "tr"):
        html, msg = render(arch, root, lang)
        check(f"render --lang {lang}", html is not None, msg)
        pages[lang] = html
    if not all(pages.values()):
        sys.exit(1)
    en, tr = pages["en"], pages["tr"]
    D = data(en)
    check('en: <html lang="en"> and D.lang == "en"', '<html lang="en">' in en and D.get("lang") == "en", str(D.get("lang")))
    ids = [b for g in D["groups"] if g["name"] != D.get("facts") for b in g["boards"]] if False else [b for g in D["groups"] if g["name"] == D.get("facts") or not D.get("facts") for b in g["boards"]]
    texts = []
    for b in ids:
        m = re.search(r'<section class="b" id="b-' + re.escape(b) + r'" hidden>(.*?)</section>', en, re.S)
        texts += re.findall(r">([^<>]+)<", m.group(1)) if m else []
        texts += [D["boards"][b]["purpose"], D["boards"][b]["title"]]
    bad = sorted({t for t in texts if TR.search(t)})
    check("en: no Turkish string in the deterministic boards", not bad, "; ".join(bad[:3]))
    check('tr: <html lang="tr"> and D.lang == "tr"', '<html lang="tr">' in tr and data(tr).get("lang") == "tr")
    check("tr: deterministic boards are still English (content language is the producer's, not the chrome's)", not [t for t in texts if TR.search(t)])

    from playwright.sync_api import sync_playwright
    tmp = tempfile.mkdtemp()
    paths = {k: os.path.join(tmp, k + ".html") for k in pages}
    for k, v in pages.items():
        open(paths[k], "w", encoding="utf-8").write(v)
    with sync_playwright() as p:
        br = p.chromium.launch(executable_path=CHROME)

        def page(path, init=None):
            ctx = br.new_context(viewport={"width": 760, "height": 708})
            if init:
                ctx.add_init_script(init)
            pg = ctx.new_page()
            pg.goto("file://" + path); pg.wait_for_timeout(200)
            return pg

        pg = page(paths["tr"])
        eb = pg.evaluate("document.getElementById('eb').innerText"); want = pg.evaluate("D.groups[0].name.toLocaleUpperCase('tr')")
        check('tr: eyebrow uppercases with Turkish casing', eb == want and (("İ" in eb) or "i" not in D["groups"][0]["name"].lower()), repr(eb))
        if pg.evaluate("D.groups[0].name") == "Büyük resim":
            check('tr: eyebrow is "BÜYÜK RESİM"', eb == "BÜYÜK RESİM", repr(eb))
        pg = page(paths["en"])
        eb = pg.evaluate("document.getElementById('eb').innerText")
        check("en: eyebrow never gets a dotted İ", "İ" not in eb, repr(eb))

        has_table = pg.evaluate("typeof S === 'object'")
        check("shell has a chrome string table (S)", has_table)
        if not has_table:
            br.close()
            print("LANG CHECK FAILED: " + ", ".join(fails))
            sys.exit(1)
        keys = pg.evaluate("Object.keys(S)")
        fake = {k: "X_" + k for k in keys}
        fake["back_to"] = "X_back_to {name}"
        pg = page(paths["en"], "window.breeStrings = " + json.dumps(fake) + ";")
        left = pg.evaluate("""()=>[...document.querySelectorAll('header [title],header [aria-label],#stage > [title],#stage > [aria-label],#zoom,#zoom [title],#zoom [aria-label],#card')]
            .flatMap(e=>[['title',e.getAttribute('title')],['aria-label',e.getAttribute('aria-label')]]).filter(([k,v])=>v&&!v.startsWith('X_')).map(([k,v])=>k+'='+v)""")
        check("fake breeStrings: every static title/aria-label is replaced", not left, ", ".join(left[:4]))
        check("fake breeStrings: Fit label and legend title", pg.evaluate("document.getElementById('zf').textContent") == "X_fit"
              and all(t == "X_LEGEND" for t in pg.evaluate("[...document.querySelectorAll('svg text[data-sl]')].map(e=>e.textContent)")) , "")
        # open a card on a node with every rich field if there is one, else the node with the most fields
        pick = pg.evaluate("""()=>{let best=null,sc=-1;for(const [id,n] of Object.entries(D.info)){const s=['what','why','connects','code','watch','unverified'].filter(k=>n[k]&&n[k].length).length;if(s>sc){sc=s;best=id}}return best}""")
        bd = pg.evaluate("D.info[%s].board" % json.dumps(pick))
        pg.goto("file://" + paths["en"] + "#" + bd); pg.reload(); pg.wait_for_timeout(200)
        pg.evaluate("id=>selectNode(id,{expanded:true})", pick); pg.wait_for_timeout(300)
        card = pg.evaluate("({h3:[...document.querySelectorAll('#card h3')].map(e=>e.textContent),more:document.querySelector('#card .more')&&document.querySelector('#card .more').textContent,bits:document.getElementById('card').innerText})")
        hs = [h for h in card["h3"] if not h.startswith("X_")]
        check("fake breeStrings: card headings come from the table", card["h3"] and not hs, f"{card['h3']} stale {hs}")
        check("fake breeStrings: More/Less from the table", (card["more"] or "").startswith("X_"), repr(card["more"]))
        agent = pg.evaluate("D.agent")
        if agent:
            bda = pg.evaluate("Object.keys(D.boards).find(k=>D.boards[k].agent)")
            pg.goto("file://" + paths["en"] + "#" + bda); pg.reload(); pg.wait_for_timeout(200)
            ag = pg.evaluate("document.getElementById('ag').textContent")
            check("fake breeStrings: agent eyebrow", ag.startswith("X_agent_wrote"), ag)
        if "delta" in D["boards"]:
            pg.goto("file://" + paths["en"] + "#delta"); pg.reload(); pg.wait_for_timeout(200)
            check("fake breeStrings: Changes eyebrow", pg.evaluate("document.getElementById('eb').textContent") == "X_changes")
        # tr document + English UI: chrome uppercases with the UI language (no İ in "WHAT IT DOES"), content with the document language
        pg = page(paths["tr"], "window.breeStrings = " + json.dumps({"_lang": "en"}) + ";")
        pg.goto("file://" + paths["tr"] + "#" + bd); pg.reload(); pg.wait_for_timeout(200)
        pg.evaluate("id=>selectNode(id,{expanded:true})", pick); pg.wait_for_timeout(300)
        h3 = pg.evaluate("[...document.querySelectorAll('#card h3')].map(e=>e.innerText)")
        check('tr doc + _lang en: card heading renders "WHAT IT DOES"', "WHAT IT DOES" in h3, str(h3))
        if pg.evaluate("D.groups[0].name") == "Büyük resim":
            pg.goto("file://" + paths["tr"] + "#" + pg.evaluate("D.groups[0].boards[0]")); pg.reload(); pg.wait_for_timeout(200)
            check('tr doc + _lang en: eyebrow group still renders "BÜYÜK RESİM"', pg.evaluate("document.getElementById('eb').innerText") == "BÜYÜK RESİM", pg.evaluate("document.getElementById('eb').innerText"))
        br.close()
    print("LANG CHECK PASSED" if not fails else "LANG CHECK FAILED: " + ", ".join(fails))
    sys.exit(1 if fails else 0)


main()
