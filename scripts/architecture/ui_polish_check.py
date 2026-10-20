#!/usr/bin/env python3
"""UI polish check of the rendered page (docs/state/2026-10-10-arch-ui-polish.md), real Chrome via Playwright, at the popover's 760x708 stage.

  /opt/anaconda3/bin/python -I ui_polish_check.py <current.html> [shots-dir|-] [page-with-empty-changes.html]

Every board: the smallest <text> is >= 10 px on screen at open, and a Fit view never zooms above 100%.
Board 1: the eyebrow is uppercased in the document language (tr: "BÜYÜK RESİM"), the focal node drops to the normal stroke while another node is selected,
the card never covers a direct neighbour (or is docked in a stage corner with a leader), the contents menu opens below the title row,
the zoom control is one face, the card close button is borderless with a >= 28 px hit area.
Changes with no diagram: no pager, no zoom control, no "0 /", an HTML empty state.
Shots (optional): board 1 at open, selected (collapsed, expanded), contents open, a Facts board, the Changes empty state.
"""
import json, os, re, sys
from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_svg import browser_or_exit
CHROME = browser_or_exit("ui_polish_check.py")
fails = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail else ""))
    if not ok:
        fails.append(name)


MIN_TEXT = """()=>{const b=document.querySelector('.b:not([hidden])');if(!b)return null;
  let m=1e9;b.querySelectorAll('svg text').forEach(t=>{const r=t.getBoundingClientRect();if(!r.width&&!r.height)return;
    const k=t.getScreenCTM().a;m=Math.min(m,parseFloat(getComputedStyle(t).fontSize)*k)});return m>=1e9?null:m}"""
ST = "(()=>{const s=document.getElementById('stage');return {s:+s.dataset.scale,fit:s.dataset.fit==='1'}})()"


def main():
    src = os.path.abspath(sys.argv[1])
    shots = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] != "-" else None
    if shots:
        os.makedirs(shots, exist_ok=True)
    html = open(src, encoding="utf-8").read()
    D = json.loads(re.search(r"const D = (\{.*?\});\n", html, re.S).group(1))
    order = [b for g in D["groups"] for b in g["boards"]]
    facts = [b for g in D["groups"] if g["name"] == D.get("facts") for b in g["boards"]]
    shot = lambda pg, name: shots and pg.screenshot(path=os.path.join(shots, name + ".png"))
    with sync_playwright() as p:
        br = p.chromium.launch(executable_path=CHROME)
        ctx = br.new_context(viewport={"width": 760, "height": 708}, device_scale_factor=2)
        ctx.add_init_script("try{if(!sessionStorage.getItem('__keep'))localStorage.clear()}catch(e){}")
        pg = ctx.new_page()
        go = lambda bd: (pg.goto("file://" + src + "#" + bd), pg.reload(), pg.wait_for_timeout(150))

        # A1 + A3: smallest on-screen text at open, Fit never above 100%
        small, big = [], []
        for bd in order:
            go(bd)
            m, s = pg.evaluate(MIN_TEXT), pg.evaluate(ST)
            if m is not None and m < 10 - 0.05:
                small.append(f"{bd} {m:.1f}px")
            if s["fit"] and s["s"] > 1.0001:
                big.append(f"{bd} {s['s']:.2f}")
        check("A1 every board opens with its smallest text >= 10 px", not small, "; ".join(small[:6]))
        check("A3 Fit never zooms above 100%", not big, "; ".join(big[:6]))
        go(order[0])
        s0 = pg.evaluate(ST)
        check("A1 board 1 opens fitted at >= 0.91", s0["fit"] and s0["s"] >= 0.91, f"{s0}")

        # A2: Turkish casing
        eb = pg.evaluate("document.getElementById('eb').innerText")
        want = pg.evaluate("D.groups[0].name.toLocaleUpperCase(D.lang)")  # the chrome uppercases with the document language: tr gives BÜYÜK RESİM for "Büyük resim", en never an İ
        check("A2 eyebrow of board 1 is uppercased in the document language", eb == want, f"{eb!r} vs {want!r}")
        check("A2 <html lang> is the producer's lang", pg.evaluate("document.documentElement.lang") == (D.get("lang") or "en"), pg.evaluate("document.documentElement.lang"))
        shot(pg, "01-board1-open")

        # A13 zoom control one face, A15 close button
        faces = pg.evaluate("[...document.querySelectorAll('#zoom button')].map(b=>getComputedStyle(b).fontFamily)")
        check("A13 zoom control uses one face", len(set(faces)) == 1 and "tabular-nums" in pg.evaluate("getComputedStyle(document.getElementById('zoom')).fontVariantNumeric"), str(set(faces))[:80])

        # A4 / A5 / A15 / A6: select a node of board 1
        ids = pg.evaluate("[...document.querySelectorAll('.b:not([hidden]) .node')].map(n=>n.dataset.id)")
        focal = pg.evaluate("(()=>{const f=document.querySelector('.b:not([hidden]) .nb.focal');return f?f.closest('.node').dataset.id:null})()")
        other = next(i for i in ids if i != focal and pg.evaluate("id=>[...document.querySelectorAll('.b:not([hidden]) path.ed')].some(p=>p.dataset.from===id||p.dataset.to===id)", i))
        sw0 = pg.evaluate("parseFloat(getComputedStyle(document.querySelector('.b:not([hidden]) .nb.focal')).strokeWidth)") if focal else None
        pg.evaluate("id=>document.querySelector('.b:not([hidden]) .node[data-id=\"'+CSS.escape(id)+'\"]').dispatchEvent(new MouseEvent('click',{bubbles:true}))", other)
        pg.wait_for_timeout(450)
        sw1 = pg.evaluate("parseFloat(getComputedStyle(document.querySelector('.b:not([hidden]) .nb.focal')).strokeWidth)") if focal else None
        check("A4 focal node drops to the normal stroke while a node is selected", focal is not None and sw1 < sw0 and sw1 <= 1.2, f"{sw0} -> {sw1}")
        x = pg.evaluate("(()=>{const r=document.querySelector('#card .x').getBoundingClientRect(),c=getComputedStyle(document.querySelector('#card .x'));return {w:r.width,h:r.height,b:c.borderTopWidth+' '+c.borderTopStyle,bc:c.borderTopColor}})()")
        check("A15 close button borderless, hit area >= 28x28", x["w"] >= 28 and x["h"] >= 28 and (x["b"].startswith("0px") or "none" in x["b"] or x["bc"] == "rgba(0, 0, 0, 0)"), str(x))
        cov = """()=>{const c=document.getElementById('card').getBoundingClientRect(),sel=document.querySelector('.node.sel');if(!sel)return ['none'];
          const hit=r=>r.left<c.right&&r.right>c.left&&r.top<c.bottom&&r.bottom>c.top;
          const id=sel.dataset.id,nb=new Set();document.querySelectorAll('.b:not([hidden]) path.ed').forEach(p=>{if(p.dataset.from===id)nb.add(p.dataset.to);if(p.dataset.to===id)nb.add(p.dataset.from)});
          return [...nb].filter(i=>hit(document.querySelector('.b:not([hidden]) .node[data-id="'+CSS.escape(i)+'"]').getBoundingClientRect()))}"""
        # every node of board 1, collapsed and expanded: the card covers no direct neighbour
        bad = []
        for i in ids:
            pg.evaluate("id=>{const n=document.querySelector('.b:not([hidden]) .node[data-id=\"'+CSS.escape(id)+'\"]');if(document.querySelector('.node.sel'))document.getElementById('card').querySelector('.x').click();n.dispatchEvent(new MouseEvent('click',{bubbles:true}))}", i)
            pg.wait_for_timeout(300)
            for expd in (False, True):
                if expd:
                    more = pg.locator("#card .more")
                    if not more.is_visible():
                        continue
                    more.click(); pg.wait_for_timeout(350)
                c = pg.evaluate(cov)
                if c:
                    bad.append(f"{i.split(':')[-1]}{'+' if expd else ''}: {','.join(x.split(':')[-1] for x in c)}")
        check("A5 the card covers no direct neighbour on any node of board 1 (collapsed and expanded)", not bad, "; ".join(bad[:6]))
        # shots on the node picked
        pg.evaluate("id=>{if(document.querySelector('.node.sel'))document.querySelector('#card .x').click();document.querySelector('.b:not([hidden]) .node[data-id=\"'+CSS.escape(id)+'\"]').dispatchEvent(new MouseEvent('click',{bubbles:true}))}", other)
        pg.wait_for_timeout(450); shot(pg, "02-board1-selected-collapsed")
        if pg.locator("#card .more").is_visible():
            pg.locator("#card .more").click(); pg.wait_for_timeout(450)
        shot(pg, "03-board1-selected-expanded")
        pg.keyboard.press("Escape")

        # A14 contents menu below the title row
        go(order[0])
        pg.click("#toc"); pg.wait_for_timeout(150)
        gap = pg.evaluate("(()=>{const m=document.getElementById('contents').getBoundingClientRect(),b=document.querySelector('.bar').getBoundingClientRect();return m.top-b.bottom})()")
        check("A14 contents menu opens below the title row", gap >= -0.5, f"gap {gap:.1f}px")
        shot(pg, "04-contents-open")
        pg.keyboard.press("Escape")

        # A8: Facts board
        if facts:
            go(facts[0]); pg.wait_for_timeout(100)
            txt = pg.evaluate("document.querySelector('.b:not([hidden])').innerText + ' ' + document.getElementById('purpose').innerText")
            tr = re.findall(r"[çğıöşüÇĞİÖŞÜ]|AÇIKLAMA", txt)
            check("A8 deterministic strings of the first Facts board are English, whatever the page lang", not tr, ",".join(tr[:5]))
            shot(pg, "05-facts-board")

        # A3: Changes with no diagram (a page whose previous generation equals the current one: arg 3)
        if len(sys.argv) > 3:
            pg.goto("file://" + os.path.abspath(sys.argv[3]) + "#delta"); pg.reload(); pg.wait_for_timeout(150)
            vis = lambda sel: pg.evaluate("s=>{const e=document.querySelector(s);return !!e&&e.getClientRects().length>0}", sel)
            body = pg.evaluate("document.body.innerText")
            check("A3 Changes empty state: no pager, no zoom, no '0 /', an HTML message", not vis("#step") and not vis("#zoom") and "0 /" not in body and vis("#empty"), f"empty={pg.evaluate('(document.getElementById(\'empty\')||{}).innerText')!r}")
            shot(pg, "06-changes-empty")
        else:
            print("SKIP Changes empty state: pass a page with an empty Changes board as argument 3")
        br.close()
    print("FAILED: " + ", ".join(fails) if fails else "all UI polish checks passed")
    sys.exit(1 if fails else 0)


main()
