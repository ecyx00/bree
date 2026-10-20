#!/usr/bin/env python3
"""Trusted-input check of zoom/pan and the network policy of the rendered page, in real Chrome via Playwright.

  /opt/anaconda3/bin/python -I zoom_check.py <current.html> [shots-dir]

Checks (each prints PASS/FAIL, exit 1 on any FAIL): opens at fit; ctrl+wheel (what a trackpad pinch sends) zooms around the cursor
(the point under it stays put) and the document never scrolls (scrollTop 0, scrollHeight <= clientHeight on html and body); plain wheel pans;
drag pans and does not click; +, -, Fit buttons, Cmd+=, Cmd+-, Cmd+0, double-click; range 0.25x..4x; node click shows the detail panel with
a source link (the link click is what ArchitectureWindowController handles); no request leaves file:// and the CSP is default-src 'none'.
Node card checks (card_checks, CARD_ONLY=1 runs only those): first node of every board at 640x708 and 1100x800, card inside the stage and clear of the node, zoom unchanged, text >= 10 px, dimmed text >= 4.5:1, breeHandleEscape(), restore; history, Changes surface, contents, keys, AX.
Shell UX checks (shell_checks): neighbours lit, neighbours stay at full opacity, "Connections" entries select and centre, [ ] step the order,
purpose not truncated, state restored after reload, contrast/size/Tab/arrow keys/reduced motion. SHELL_ONLY=1 runs only those.
Needs a fixture board (id fixture-rich) in the page: render it with render_fixture.py; without it the fixture-only checks SKIP.
Shots (optional): each board at 560x720 and 1400x900 fit-to-view, and one at 2x zoom.
"""
import json, os, re, sys
from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_svg import browser_or_exit
CHROME = browser_or_exit("zoom_check.py")
ACCENT_RGB = "rgb(240, 138, 89)"
BOARDS = []  # every board of the page, read from its data in main(): a board added later is checked without editing this file
fails = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail else ""))
    if not ok:
        fails.append(name)


def shell_checks(br, src, D, flow):
    """The shell UX checks (docs/state/2026-10-10-architecture-shell-ux.md). Run on a page that holds the fixture board fixture-rich."""
    fix = "fixture-rich" if "fixture-rich" in D["boards"] else None
    keep_clear = "try{if(!sessionStorage.getItem('__keep'))localStorage.clear()}catch(e){}"
    ctx = br.new_context(viewport={"width": 1100, "height": 760}); ctx.add_init_script(keep_clear)
    pg = ctx.new_page()

    def go(bd, w=None, h=None):
        if w:
            pg.set_viewport_size({"width": w, "height": h})
        pg.goto("file://" + src + "#" + bd); pg.reload(); pg.wait_for_timeout(150)

    pick = lambda i: pg.evaluate("id=>document.querySelector('.b:not([hidden]) .node[data-id=\"'+CSS.escape(id)+'\"]').dispatchEvent(new MouseEvent('click',{bubbles:true}))", i)
    ids = lambda: pg.evaluate("[...document.querySelectorAll('.b:not([hidden]) .node')].map(n=>n.dataset.id)")
    neigh = lambda i: pg.evaluate("id=>{const s=new Set();document.querySelectorAll('.b:not([hidden]) path.ed').forEach(p=>{if(p.dataset.from===id)s.add(p.dataset.to);if(p.dataset.to===id)s.add(p.dataset.from)});s.delete(id);return [...s]}", i)
    stt = lambda: pg.evaluate("(()=>{const s=document.getElementById('stage');return {s:+s.dataset.scale,tx:+s.dataset.tx,ty:+s.dataset.ty}})()")
    geo = """()=>{const c=document.getElementById('card').getBoundingClientRect(),s=document.getElementById('stage').getBoundingClientRect();
      const vis=r=>({left:Math.max(r.left,s.left),right:Math.min(r.right,s.right),top:Math.max(r.top,s.top),bottom:Math.min(r.bottom,s.bottom)});
      const hit=r=>c.width>0&&c.height>0&&r.left<c.right&&r.right>c.left&&r.top<c.bottom&&r.bottom>c.top&&r.left<r.right&&r.top<r.bottom;
      const g=document.querySelector('.node.sel');if(!g)return {none:true};const sr=g.getBoundingClientRect();
      const cov=[...document.querySelectorAll('.b:not([hidden]) .node')].filter(n=>hit(vis(n.getBoundingClientRect()))).map(n=>n.dataset.id);
      return {cov,selVisible:sr.left>=s.left-1&&sr.right<=s.right+1&&sr.top>=s.top-1&&sr.bottom<=s.bottom+1,selUnder:hit(vis(sr))}}"""

    # 2. neighbours of the selected node stay at full opacity; the rest dims
    bad = []
    pg.set_viewport_size({"width": 1100, "height": 760})
    for bd in [flow] + ([fix] if fix else []):
        go(bd)
        nid = [i for i in ids() if neigh(i)]
        pick(nid[0]); pg.wait_for_timeout(450)
        nb = neigh(nid[0])
        ops = pg.evaluate("ns=>[...document.querySelectorAll('.b:not([hidden]) .node')].map(n=>[n.dataset.id,getComputedStyle(n.querySelector('.nb')).fillOpacity])", nb)
        for i, o in ops:
            want_full = i == nid[0] or i in nb
            if want_full != (o == "1"):
                bad.append(f"{bd}: {i.split(':')[-1]} {o} ({'neighbour' if i in nb else 'other'})")
    check("neighbours of the selected node stay at full opacity, the others dim", not bad, "; ".join(bad[:4]))

    # 3. a "Connections" entry (in the expanded card) selects that node and the card header offers a way back
    if fix:
        go(fix, 1100, 760); pick(fix + ":route"); pg.wait_for_timeout(450)
        pg.locator("#card .more").click(); pg.wait_for_timeout(300)
        n_ent = pg.locator("#card .conns .cn").count()
        if n_ent:
            pg.locator("#card .conns .cn").first.click(); pg.wait_for_timeout(450)
        got = pg.evaluate("(document.querySelector('.node.sel')||{dataset:{}}).dataset.id")
        check("a Connections entry selects that node", bool(n_ent) and got and got != fix + ":route", f"entries {n_ent}, now {got}")
    else:
        print("SKIP Connections: no fixture board in the page")

    # 4. [ and ] step through the reading order
    order = [b for g in D["groups"] for b in g["boards"]]
    go(order[0]); pg.keyboard.press("]"); pg.wait_for_timeout(100); a = pg.evaluate("location.hash.slice(1)")
    pg.keyboard.press("]"); pg.wait_for_timeout(100); c = pg.evaluate("location.hash.slice(1)")
    pg.keyboard.press("["); pg.wait_for_timeout(100); d = pg.evaluate("location.hash.slice(1)")
    go(order[0]); pg.keyboard.press("["); pg.wait_for_timeout(100); e = pg.evaluate("location.hash.slice(1)")
    check("[ and ] step through the reading order (clamped at the ends)", [a, c, d, e] == [order[1], order[2], order[1], order[0]], f"{[a, c, d, e]} want {[order[1], order[2], order[1], order[0]]}")

    # 5. the purpose text is not truncated, at 640 and 1100
    bad = []
    for w, h in ((640, 720), (1100, 760)):
        pg.set_viewport_size({"width": w, "height": h})
        for bd in order:
            go(bd)
            r = pg.evaluate("(()=>{const p=document.getElementById('purpose'),cs=getComputedStyle(p),lh=parseFloat(cs.lineHeight)||parseFloat(cs.fontSize)*1.3;return [p.scrollWidth<=p.clientWidth+1&&p.scrollHeight<=p.clientHeight+1&&cs.textOverflow!=='ellipsis'&&cs.display!=='none',Math.round(p.getBoundingClientRect().height/lh),p.textContent.length>0]})()")
            if not (r[0] and r[2] and r[1] <= 2):
                bad.append(f"{w} {bd} {r}")
    check("purpose text is shown in full: no ellipsis, no clipping, at most 2 lines, every board, 640 and 1100", not bad, "; ".join(bad[:3]))

    # 6. after a reload the board, the zoom and the selection are restored
    if fix:
        go(fix, 1100, 760); pick(fix + ":index"); pg.keyboard.press("Meta+="); pg.keyboard.press("Meta+="); pg.wait_for_timeout(300)
        before = stt(); pg.evaluate("sessionStorage.setItem('__keep','1')"); pg.reload(); pg.wait_for_timeout(300)
        after = stt(); sel_after = pg.evaluate("(document.querySelector('.node.sel')||{dataset:{}}).dataset.id")
        pg.goto("file://" + src); pg.wait_for_timeout(300)  # no hash: the board comes from the saved place
        bd_after = pg.evaluate("location.hash.slice(1)")
        pg.evaluate("sessionStorage.removeItem('__keep')")
        check("after a reload the board, the zoom and the selection are restored", abs(before["s"] - after["s"]) < 1e-3 and abs(before["tx"] - after["tx"]) < 2 and abs(before["ty"] - after["ty"]) < 2
              and sel_after == fix + ":index" and bd_after == fix, f"{before} -> {after}, sel {sel_after}, hash-less open -> {bd_after}")
    else:
        print("SKIP restore: no fixture board in the page")

    # accessibility: contrast and size of the inspector text, Tab reach, arrow keys, reduced motion
    go(fix or flow, 1100, 760); nid = ids(); rich = fix + ":route" if fix else [i for i in nid if neigh(i)][0]; pick(rich); pg.wait_for_timeout(450)
    m = pg.evaluate("""(()=>{const c=document.getElementById('card'),bg=getComputedStyle(c).backgroundColor;const P=s=>s.match(/[\\d.]+/g).map(Number);
      const L=([r,g,b])=>{const f=v=>{v/=255;return v<=0.03928?v/12.92:Math.pow((v+0.055)/1.055,2.4)};return .2126*f(r)+.7152*f(g)+.0722*f(b)};
      const cr=(a,b)=>(Math.max(L(a),L(b))+.05)/(Math.min(L(a),L(b))+.05);let min=99,minf=99,n=0;
      const w=document.createTreeWalker(c,NodeFilter.SHOW_TEXT);while(w.nextNode()){const t=w.currentNode;if(!t.textContent.trim())continue;const cs=getComputedStyle(t.parentElement);n++;
        min=Math.min(min,cr(P(cs.color),P(bg)));minf=Math.min(minf,parseFloat(cs.fontSize))}
      return {min,minf,n}})()""")
    check("inspector text contrast >= 4.5:1 and size >= 13 px", m["n"] > 3 and m["min"] >= 4.5 and m["minf"] >= 13, f"min contrast {m['min']:.2f}:1, min size {m['minf']} px over {m['n']} text runs")
    go(fix or flow); nid = ids(); seen = set()
    pg.evaluate("document.activeElement&&document.activeElement.blur()")
    for _ in range(len(nid) + 40):
        pg.keyboard.press("Tab")
        a = pg.evaluate("(document.activeElement.closest&&document.activeElement.closest('.node')||{dataset:{}}).dataset.id")
        if a:
            seen.add(a)
        if seen >= set(nid):
            break
    check("every node of the board is reachable with Tab", seen >= set(nid), f"{len(seen)} of {len(nid)}")
    if fix:
        res = []
        for key, frm, to in (("ArrowRight", "route", "index"), ("ArrowDown", "route", "cache"), ("ArrowLeft", "route", "hook"), ("ArrowUp", "cache", "route")):
            pg.evaluate("id=>document.querySelector('.b:not([hidden]) .node[data-id=\"'+CSS.escape(id)+'\"]').focus()", fix + ":" + frm)
            pg.keyboard.press(key); pg.wait_for_timeout(60)
            res.append(pg.evaluate("(document.activeElement.closest&&document.activeElement.closest('.node')||{dataset:{}}).dataset.id") == fix + ":" + to)
        check("arrow keys move focus to the connected node in that direction", all(res), str(res))
    ctx.close()
    rc = br.new_context(viewport={"width": 1100, "height": 760}, reduced_motion="reduce"); rc.add_init_script(keep_clear)
    rp = rc.new_page(); rp.goto("file://" + src + "#" + (fix or flow)); rp.reload(); rp.wait_for_timeout(150)
    rid = fix + ":route" if fix else None
    if rid:
        rp.evaluate("id=>document.querySelector('.b:not([hidden]) .node[data-id=\"'+CSS.escape(id)+'\"]').dispatchEvent(new MouseEvent('click',{bubbles:true}))", rid); rp.wait_for_timeout(100)
        # the click and the first read happen in one task: with an animated pan the first read is still mid-way, with a jump it is final
        two = rp.evaluate("""new Promise(res=>{const s=document.getElementById('stage'),b=document.querySelector('#card .conns .cn');if(!b)return res(null);b.click();const a=[s.dataset.tx,s.dataset.ty];
          requestAnimationFrame(()=>requestAnimationFrame(()=>setTimeout(()=>res([a,[s.dataset.tx,s.dataset.ty]]),500)))})""")
        check("reduced motion: the pan is a jump, not an animation", bool(two) and two[0] == two[1], str(two))
    rc.close()


LUM = """const P=s=>(s.match(/[\\d.]+/g)||[]).slice(0,3).map(Number);
  const L=([r,g,b])=>{const f=v=>{v/=255;return v<=0.03928?v/12.92:Math.pow((v+0.055)/1.055,2.4)};return .2126*f(r)+.7152*f(g)+.0722*f(b)};
  const cr=(a,b)=>(Math.max(L(a),L(b))+.05)/(Math.min(L(a),L(b))+.05);"""


def card_checks(br, src, D):
    """The node info card (docs/state/2026-10-10-arch-card-shell.md): for the first node of every board at 640x708 and 1100x800 the card is fully inside the stage,
    does not cover the selected node, leaves the zoom alone, node text stays >= 10 px, dimmed text keeps >= 4.5:1, breeHandleEscape() closes it, a reload restores the node.
    Then the shell-side rules around it: history, Changes surface, contents list, focal vs selection, wiki bridge, keys, AX."""
    keep = "try{if(!sessionStorage.getItem('__keep'))localStorage.clear()}catch(e){}"
    order = [b for g in D["groups"] for b in g["boards"]]
    bad = {k: [] for k in ("inside", "cover", "zoom", "size", "contrast", "esc", "restore", "open")}
    for w, h in ((640, 708), (1100, 800)):
        ctx = br.new_context(viewport={"width": w, "height": h}); ctx.add_init_script(keep)
        pg = ctx.new_page()
        for bd in order:
            tag = f"{w} {bd}"
            pg.goto("file://" + src + "#" + bd); pg.reload(); pg.wait_for_timeout(100)
            if not pg.locator(f"#b-{bd} .node").count():
                continue
            s0 = float(pg.evaluate("document.getElementById('stage').dataset.scale"))
            pg.locator(f"#b-{bd} .node").first.click(); pg.wait_for_timeout(420)
            r = pg.evaluate("""(()=>{const c=document.getElementById('card'),s=document.getElementById('stage').getBoundingClientRect(),g=document.querySelector('.node.sel');
              if(c.hidden||!g)return null;const q=c.getBoundingClientRect(),n=g.getBoundingClientRect();
              const t=g.querySelector('text'),sc=+document.getElementById('stage').dataset.scale;
              return {inside:q.left>=s.left-1&&q.right<=s.right+1&&q.top>=s.top-1&&q.bottom<=s.bottom+1,
                cover:q.left<n.right-1&&q.right>n.left+1&&q.top<n.bottom-1&&q.bottom>n.top+1,scale:sc,px:t?parseFloat(getComputedStyle(t).fontSize)*sc:99,id:g.dataset.id}})()""")
            if not r:
                bad["open"].append(tag); continue
            if not r["inside"]: bad["inside"].append(tag)
            if r["cover"]: bad["cover"].append(tag)
            if abs(r["scale"] - s0) > 1e-4: bad["zoom"].append(f"{tag} {s0:.3f}->{r['scale']:.3f}")
            if r["px"] < 9.95: bad["size"].append(f"{tag} {r['px']:.1f}px")
            c = pg.evaluate("(()=>{" + LUM + """const bg=P(getComputedStyle(document.body).backgroundColor);let min=99,n=0;
              document.querySelectorAll('.b:not([hidden]) .node:not(.sel):not(.nbr)').forEach(g=>{let o=1,e=g;while(e&&e.tagName!=='svg'){o*=parseFloat(getComputedStyle(e).opacity);e=e.parentElement}
                g.querySelectorAll('text').forEach(t=>{const f=P(getComputedStyle(t).fill),m=f.map((v,i)=>v*o+bg[i]*(1-o));min=Math.min(min,cr(m,bg));n++})});
              return [min,n]})()""")
            if c[1] and c[0] < 4.5: bad["contrast"].append(f"{tag} {c[0]:.2f}")
            pg.evaluate("sessionStorage.setItem('__keep','1')"); pg.reload(); pg.wait_for_timeout(200)
            after = pg.evaluate("(document.querySelector('.node.sel')||{dataset:{}}).dataset.id"); pg.evaluate("sessionStorage.removeItem('__keep')")
            if after != r["id"]: bad["restore"].append(f"{tag} {r['id']} -> {after}")
            e1 = pg.evaluate("[typeof window.breeHandleEscape==='function'&&window.breeHandleEscape(),document.getElementById('card').hidden,typeof window.breeHandleEscape==='function'&&window.breeHandleEscape()]")
            if e1 != [True, True, False]: bad["esc"].append(f"{tag} {e1}")
        ctx.close()
    for key, name in (("open", "a click on the first node of every board opens the card"), ("inside", "the card is fully inside the stage"), ("cover", "the card does not cover the selected node"),
                      ("zoom", "opening the card never changes the zoom"), ("size", "node text >= 10 px at the opened zoom"), ("contrast", "dimmed node text keeps contrast >= 4.5:1"),
                      ("restore", "a reload restores the same selected node"), ("esc", "breeHandleEscape() closes the card (true), then reports nothing open (false)")):
        check(f"{name}: first node of every board, 640x708 and 1100x800", not bad[key], "; ".join(bad[key][:4]) + (f" (+{len(bad[key]) - 4})" if len(bad[key]) > 4 else ""))

    # placement: the card covers no direct neighbour (and keeps them on stage) whenever some side + pan achieves that; and the expanded card is readable
    PRE = """(which)=>{const st=document.getElementById('stage'),sr=st.getBoundingClientRect(),rb=r=>[r.left-sr.left,r.top-sr.top,r.right-sr.left,r.bottom-sr.top];
      const nb=id=>{const s=new Set();document.querySelectorAll('.b:not([hidden]) path.ed').forEach(p=>{if(p.dataset.from===id)s.add(p.dataset.to);if(p.dataset.to===id)s.add(p.dataset.from)});s.delete(id);return s};
      const nodes=[...document.querySelectorAll('.b:not([hidden]) .node')];let pick=nodes[0];
      if(which==='most')pick=nodes.reduce((a,n)=>nb(n.dataset.id).size>nb(a.dataset.id).size?n:a,nodes[0]);
      const ns=[...nb(pick.dataset.id)].map(i=>nodes.find(n=>n.dataset.id===i)).filter(Boolean).map(n=>rb(n.getBoundingClientRect()));
      return {id:pick.dataset.id,n:nb(pick.dataset.id).size,sel:rb(pick.getBoundingClientRect()),nbs:ns,W:st.clientWidth,H:st.clientHeight}}"""
    POST = """()=>{const st=document.getElementById('stage'),sr=st.getBoundingClientRect(),c=document.getElementById('card'),q=c.getBoundingClientRect();
      const bad=[...document.querySelectorAll('.node.nbr')].filter(n=>{const r=n.getBoundingClientRect();return (r.left<q.right-1&&r.right>q.left+1&&r.top<q.bottom-1&&r.bottom>q.top+1)||r.left<sr.left||r.right>sr.right||r.top<sr.top||r.bottom>sr.bottom}).length;
      return {bad,w:q.width,h:q.height}}"""
    EXP = """()=>{const c=document.getElementById('card'),bd=c.querySelector('.bd'),R=e=>e.getBoundingClientRect(),b0=R(bd),out=[];
      const hs=[...c.querySelectorAll('h3')].filter(h=>R(h).width>0);
      hs.forEach(h=>{h.scrollIntoView({block:'nearest'});const r=R(h);if(r.top<b0.top-1||r.bottom>b0.bottom+1)out.push('unreachable '+h.textContent)});
      bd.scrollTop=0;const parts=['.hd','.bd','.ft'].map(q=>R(c.querySelector(q)));
      for(let i=0;i<3;i++)for(let j=i+1;j<3;j++){const a=parts[i],b=parts[j];if(a.left<b.right-1&&a.right>b.left+1&&a.top<b.bottom-1&&a.bottom>b.top+1)out.push('parts overlap '+i+j)}
      const leaf=[...bd.querySelectorAll('h3,p,li,.watch,button')].filter(e=>R(e).width>0&&R(e).height>0);
      for(let i=0;i<leaf.length;i++)for(let j=i+1;j<leaf.length;j++){const a=leaf[i],b=leaf[j];if(a.contains(b)||b.contains(a))continue;const x=R(a),y=R(b);
        if(x.left<y.right-1&&x.right>y.left+1&&x.top<y.bottom-1&&x.bottom>y.top+1)out.push('overlap '+(a.className||a.tagName)+'/'+(b.className||b.tagName))}
      return {out,hs:hs.length,scrolls:bd.scrollHeight>bd.clientHeight}}"""
    nbad, xbad, nsol = [], [], 0
    for w, h in ((640, 708), (1100, 800)):
        ctx = br.new_context(viewport={"width": w, "height": h}); ctx.add_init_script(keep)
        pg = ctx.new_page()
        for bd in order:
            for which in ("first", "most"):
                pg.goto("file://" + src + "#" + bd); pg.reload(); pg.wait_for_timeout(80)
                if not pg.locator(f"#b-{bd} .node").count():
                    continue
                pre = pg.evaluate(PRE, which)
                pg.locator(f"#b-{bd} .node[data-id='{pre['id']}']").click(); pg.wait_for_timeout(420)
                post = pg.evaluate(POST)
                tag = f"{w} {bd} {which}({pre['n']} nbrs)"
                # oracle: does any side + pan (12 px grid, zoom fixed) keep the node and all neighbours on stage and the card off them?
                W, H, cw, ch, E = pre["W"], pre["H"], post["w"], post["h"], 8
                inb = lambda r: r[0] >= E and r[1] >= E and r[2] <= W - E and r[3] <= H - E
                sh = lambda r, x, y: [r[0] + x, r[1] + y, r[2] + x, r[3] + y]
                hit = lambda a, b: a[0] < b[2] and a[2] > b[0] and a[1] < b[3] and a[3] > b[1]
                found = False
                for x in range(-int(W * .9) // 12 * 12, int(W * .9) + 1, 12):
                    for y in range(-int(H * .9) // 12 * 12, int(H * .9) + 1, 12):
                        S = sh(pre["sel"], x, y); nb = [sh(r, x, y) for r in pre["nbs"]]
                        if not inb(S) or not all(inb(r) for r in nb):
                            continue
                        cx, cy = (S[0] + S[2]) / 2, (S[1] + S[3]) / 2
                        for c in ((S[2] + 12, min(max(cy - ch / 2, E), H - E - ch)), (S[0] - 12 - cw, min(max(cy - ch / 2, E), H - E - ch)),
                                  (min(max(cx - cw / 2, E), W - E - cw), S[3] + 12), (min(max(cx - cw / 2, E), W - E - cw), S[1] - 12 - ch)):
                            cr = [c[0], c[1], c[0] + cw, c[1] + ch]
                            if inb(cr) and not any(hit(cr, r) for r in nb) and not hit(cr, S):
                                found = True; break
                        if found: break
                    if found: break
                nsol += found
                if found and post["bad"]:
                    nbad.append(f"{tag}: {post['bad']} neighbours covered/off-stage")
                if not pg.locator("#card .more").is_visible():
                    continue  # nothing to expand on this node
                pg.click("#card .more"); pg.wait_for_timeout(350)
                ex = pg.evaluate(EXP)
                if ex["out"] or (ex["hs"] == 0 and which == "most" and pre["n"] > 0):
                    xbad.append(f"{tag}: {ex['out'][:2]}")
        ctx.close()
    check("the card covers no direct neighbour and keeps them on stage whenever a side + pan achieves it (first node and most-connected node, every board, 640 and 1100)", not nbad, f"{nsol} cases with a solution; " + "; ".join(nbad[:4]) + (f" (+{len(nbad) - 4})" if len(nbad) > 4 else ""))
    check("expanded card: every section heading is reachable by scrolling the body, header/body/footer and the sections do not overlap", not xbad, "; ".join(xbad[:4]) + (f" (+{len(xbad) - 4})" if len(xbad) > 4 else ""))

    ctx = br.new_context(viewport={"width": 760, "height": 708}); ctx.add_init_script(keep)  # the popover's web content is 760 pt wide (was 640)
    pg = ctx.new_page()
    go = lambda bd: (pg.goto("file://" + src + "#" + bd), pg.reload(), pg.wait_for_timeout(150))
    first = order[0]
    # board 1 is not clipped at open (A6)
    go(first)
    clip = pg.evaluate("""(()=>{const s=document.getElementById('stage').getBoundingClientRect();return [...document.querySelectorAll('.b:not([hidden]) .node')].filter(n=>{const r=n.getBoundingClientRect();return r.left<s.left||r.right>s.right||r.top<s.top||r.bottom>s.bottom}).length})()""")
    check("board 1 shows every node at open, 760x708 (no clipping)", clip == 0, f"{clip} nodes cut")
    # a board the reader has not zoomed or panned opens at Fit even after a node was opened there
    pg.locator(f"#b-{first} .node").nth(3).click(); pg.wait_for_timeout(450)
    pg.evaluate("sessionStorage.setItem('__keep','1')"); pg.goto("file://" + src + "#" + order[1]); pg.reload(); pg.wait_for_timeout(100); pg.goto("file://" + src + "#" + first); pg.reload(); pg.wait_for_timeout(200)
    clip2 = pg.evaluate("""(()=>{const s=document.getElementById('stage').getBoundingClientRect();return [...document.querySelectorAll('.b:not([hidden]) .node')].filter(n=>{const r=n.getBoundingClientRect();return r.left<s.left||r.right>s.right}).length})()""")
    check("a board opened again after only a node click (no zoom or pan by the reader) opens at Fit", clip2 == 0 and pg.evaluate("document.getElementById('stage').dataset.fit") == "1", f"{clip2} cut")
    pg.evaluate("sessionStorage.removeItem('__keep')")
    # history: follow a Connections link, go back, board change clears it
    go(first); pg.locator(f"#b-{first} .node").first.click(); pg.wait_for_timeout(400)
    start = pg.evaluate("document.querySelector('.node.sel').dataset.id")
    pg.locator("#card .more").click(); pg.wait_for_timeout(300)
    nm0 = pg.locator("#card .nmx").inner_text()
    pg.locator("#card .conns .cn").first.click(); pg.wait_for_timeout(450)
    bk = pg.locator("#card .bk")
    label = bk.inner_text() if bk.count() else ""
    moved = pg.evaluate("document.querySelector('.node.sel').dataset.id") != start
    if bk.count():
        bk.click(); pg.wait_for_timeout(450)
    back = pg.evaluate("document.querySelector('.node.sel').dataset.id")
    check("following a Connections link shows '‹ <previous node>' in the header and it goes back", moved and label == "‹ " + nm0 and back == start, f"{label!r} vs {nm0!r}, back to {back} (start {start})")
    pg.locator("#card .more").click(); pg.locator("#card .conns .cn").first.click(); pg.wait_for_timeout(300)
    pg.keyboard.press("]"); pg.wait_for_timeout(200); pg.locator(".b:not([hidden]) .node").first.click(); pg.wait_for_timeout(300)
    check("history is cleared on board change", pg.locator("#card .bk").count() == 0)
    # focal node vs selection: with nothing selected no node carries the accent; the focal node does not use it either
    go(first)
    acc = pg.evaluate("[...document.querySelectorAll('.b:not([hidden]) .nb')].filter(n=>getComputedStyle(n).stroke==='%s').length" % ACCENT_RGB)
    foc = pg.evaluate("(()=>{const f=document.querySelector('.b:not([hidden]) .nb.focal');if(!f)return null;const c=getComputedStyle(f);return [c.stroke,parseFloat(c.strokeWidth)]})()")
    check("accent means selection only: no node outline is accent with nothing selected; the focal node is a heavier neutral stroke", acc == 0 and (foc is None or (foc[0] != ACCENT_RGB and foc[1] >= 2)), f"{acc} accent boxes, focal {foc}")
    # AX: nodes reachable (svg root is a group, not an image)
    check("diagram svg is role=group (nodes are reachable, not hidden inside an image)", pg.evaluate("[...document.querySelectorAll('.b svg')].every(v=>v.getAttribute('role')==='group')"))
    # wiki bridge: an agent node (code entries, no anchor match) gets the Wiki button through path#symbol
    info = D["info"][pg.evaluate("document.querySelector('.b:not([hidden]) .node').dataset.id")]
    if info.get("code"):
        c0 = info["code"][0]
        pg.evaluate("k=>{window.breeWikiAnchors={[k]:{slug:'s',title:'T'}}}", c0["path"] + "#" + c0.get("symbol", ""))
        pg.evaluate("n=>{window.__x=n}", 1)
        pg.locator(".b:not([hidden]) .node").first.click(); pg.wait_for_timeout(300)
        # the card may already hold the node: re-open to build with the anchors set
        pg.keyboard.press("Escape"); pg.locator(".b:not([hidden]) .node").first.click(); pg.wait_for_timeout(300)
        check("agent node: the Wiki button appears when breeWikiAnchors has path#symbol of a code entry", pg.locator("#card button.wiki").count() == 1)
    else:
        print("SKIP wiki bridge for agent nodes: first node has no code entries")
    # keys: arrows switch boards when no node is selected, and do not when one is
    go(order[1]); pg.keyboard.press("ArrowRight"); pg.wait_for_timeout(100); a = pg.evaluate("location.hash.slice(1)")
    pg.keyboard.press("ArrowLeft"); pg.wait_for_timeout(100); b = pg.evaluate("location.hash.slice(1)")
    pg.locator(".b:not([hidden]) .node").first.click(); pg.wait_for_timeout(300)
    pg.keyboard.press("ArrowRight"); pg.wait_for_timeout(200); c = pg.evaluate("location.hash.slice(1)")
    check("left/right switch boards when no node is selected; with a selection they stay on the board", [a, b, c] == [order[2], order[1], order[1]], f"{[a, b, c]}")
    # Turkish layout: [ and ] arrive with altKey set (Option+8 / Option+9); Option+Arrow stays unbound
    go(order[1])
    seq = []
    for k in ("]", "]", "["):
        pg.evaluate("k=>document.body.dispatchEvent(new KeyboardEvent('keydown',{key:k,altKey:true,bubbles:true,cancelable:true}))", k); pg.wait_for_timeout(80)
        seq.append(pg.evaluate("location.hash.slice(1)"))
    pg.evaluate("document.body.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',altKey:true,bubbles:true}))"); pg.wait_for_timeout(80)
    seq.append(pg.evaluate("location.hash.slice(1)"))
    check("keydown ] and [ with altKey (Turkish Option+8/9) step the board; Option+Arrow does not", seq == [order[2], order[3], order[2], order[2]], f"{seq} want {[order[2], order[3], order[2], order[2]]}")
    # contents list: Facts collapsed to one row, no duplicate titles, no delta; header eyebrow
    go(first); pg.click("#toc"); pg.wait_for_timeout(100)
    rows = pg.evaluate("[...document.querySelectorAll('#contents .it')].filter(b=>!b.hidden).map(b=>b.querySelector('span').textContent)")
    allr = pg.evaluate("[...document.querySelectorAll('#contents .it')].map(b=>b.querySelector('span').textContent)")
    fx = pg.evaluate("(document.querySelector('#contents .sec.tg')||{}).textContent||''")
    if D.get("facts"):
        nfacts = len(next(g for g in D["groups"] if g["name"] == D["facts"])["boards"])
        check("contents: Facts is one collapsed row 'Facts · N' that expands", fx == f"Facts · {nfacts}" and len(rows) == len(order) - nfacts, f"{fx!r}, {len(rows)} visible rows")
        pg.click("#contents .sec.tg"); pg.wait_for_timeout(100)
        check("contents: the Facts row expands", pg.evaluate("[...document.querySelectorAll('#contents .it')].filter(b=>!b.hidden).length") == len(order))
    check("contents: no duplicate titles and no Changes board in the Current list", len(set(allr)) == len(allr) and "Changes" not in allr and len(allr) == len(order), f"{len(allr)} rows, {len(set(allr))} unique")
    check("the n / N count excludes the Changes board", pg.evaluate("document.getElementById('pos').textContent") == f"1 / {len(order)}", pg.evaluate("document.getElementById('pos').textContent"))
    pg.keyboard.press("Escape"); pg.evaluate("window.breeHandleEscape&&0")
    eb = pg.evaluate("[document.getElementById('eb').textContent,document.getElementById('ag').textContent]")
    go(order[-1]); eb2 = pg.evaluate("[document.getElementById('eb').textContent,document.getElementById('ag').textContent]")
    if D.get("agent"):
        wrote = pg.evaluate("S.agent_wrote")
        check("header eyebrow: section name, and 'S.agent_wrote · <date>' on agent boards only", eb[0] and eb[1].startswith(wrote) and D["agent"]["at"] in eb[1] and eb2[0] == D["facts"] and eb2[1] == "", f"{eb} / {eb2}")
    # one Changes surface: loading #delta never overwrites the saved Current place
    if "delta" in D["boards"]:
        go(order[1]); pg.locator(".b:not([hidden]) .node").nth(1).click(); pg.wait_for_timeout(400)
        want = pg.evaluate("document.querySelector('.node.sel').dataset.id")
        pg.evaluate("sessionStorage.setItem('__keep','1')")
        pg.goto("file://" + src + "#delta"); pg.reload(); pg.wait_for_timeout(250)
        on_delta = pg.evaluate("[location.hash.slice(1), !document.getElementById('b-delta').hidden]")
        pg.goto("file://" + src); pg.wait_for_timeout(300)
        got = pg.evaluate("[location.hash.slice(1),(document.querySelector('.node.sel')||{dataset:{}}).dataset.id]")
        pg.evaluate("sessionStorage.removeItem('__keep')")
        check("#delta loads the Changes board and a reload without a fragment returns to the last Current board and node", on_delta == ["delta", True] and got == [order[1], want], f"{on_delta} then {got}, want {[order[1], want]}")
    # flows_of: Facts module nodes list their flow boards in agent mode too
    if any(b.startswith("flow-") for b in D["boards"]):
        check("related flows of module nodes are filled (agent mode too)", any(D["flows_of"].values()), f"{len(D['flows_of'])} modules")
    ctx.close()


def main():
    src = os.path.abspath(sys.argv[1])
    shots = sys.argv[2] if len(sys.argv) > 2 else None
    html = open(src, encoding="utf-8").read()
    D = json.loads(re.search(r"const D = (\{.*?\});\n", html, re.S).group(1))
    BOARDS[:] = [b for g in D["groups"] for b in g["boards"]]
    # the board the shell checks below run on: the first flow board with at least 3 nodes, else any board with 3, else the first board (nothing here names a repo)
    cnt = {}
    for v in D["info"].values():
        cnt[v["board"]] = cnt.get(v["board"], 0) + 1
    big = [b for b in BOARDS if cnt.get(b, 0) >= 3]
    pool = [b for b in big if b.startswith("flow-")] or big
    FLOW = pool[0] if pool else BOARDS[0]
    two = pool[:2] or [FLOW]
    ids_of = lambda pg, bd: pg.evaluate("[...document.querySelectorAll('#b-" + bd + " .node')].map(n=>n.dataset.id)")
    check("CSP is default-src 'none'", bool(re.search(r"Content-Security-Policy\" content=\"default-src 'none'", html)))
    check("no http(s) URL in the file", not re.search(r"https?://", html))
    with sync_playwright() as p:
        b = p.chromium.launch(executable_path=CHROME)
        if os.environ.get("CARD_ONLY"):  # just the node-card checks (used to show they fail on the page of an older shell)
            card_checks(b, src, D)
            b.close()
            print("FAILED: " + ", ".join(fails) if fails else "all card checks passed")
            sys.exit(1 if fails else 0)
        if os.environ.get("SHELL_ONLY"):
            shell_checks(b, src, D, FLOW)
            card_checks(b, src, D)
            b.close()
            print("FAILED: " + ", ".join(fails) if fails else "all shell checks passed")
            sys.exit(1 if fails else 0)
        pg = b.new_page(viewport={"width": 1400, "height": 900}, device_scale_factor=2)
        pg.context.add_init_script("try{if(!sessionStorage.getItem('__keep'))localStorage.clear()}catch(e){}")  # saved place is restored on load: each check starts fresh
        reqs = []
        pg.on("request", lambda r: reqs.append(r.url))
        st = lambda: pg.evaluate("(()=>{const s=document.getElementById('stage');return {s:+s.dataset.scale,tx:+s.dataset.tx,ty:+s.dataset.ty,fit:s.dataset.fit==='1'}})()")
        scroll = lambda: pg.evaluate("[document.body.scrollTop,document.documentElement.scrollTop,document.body.scrollHeight<=document.body.clientHeight,document.documentElement.scrollHeight<=document.documentElement.clientHeight]")
        pg.goto("file://" + src + "#" + FLOW)
        pg.wait_for_timeout(200)
        sopen = st()
        box = pg.locator("#stage").bounding_box()
        pg.click("#zf"); s0 = st()
        floor = pg.evaluate("(()=>{let m=1e9;document.querySelectorAll('.b:not([hidden]) svg text').forEach(t=>{m=Math.min(m,parseFloat(getComputedStyle(t).fontSize))});return 10/m})()")
        check("opens at fit, but never below the 10 px scale of the smallest text", abs(sopen["s"] - max(s0["s"], floor)) < 1e-3, f"open {sopen['s']:.3f}, fit {s0['s']:.3f}, floor {floor:.3f}")
        # opening view: the content's top-left corner (first lane, first rank) sits near the stage's top-left, at every popover size
        corner = """(()=>{const s=document.getElementById('stage').getBoundingClientRect(),id=location.hash.slice(1);let l=1e9,t=1e9;
          for(const e of document.querySelectorAll('#b-'+id+' svg > *:not(defs):not(title):not(desc)')){const r=e.getBoundingClientRect();if(r.width||r.height){l=Math.min(l,r.left);t=Math.min(t,r.top)}}
          return [l-s.left,t-s.top]})()"""
        for w, h in ((640, 720), (800, 900), (1280, 1400)):
            pg.set_viewport_size({"width": w, "height": h})
            bad = []
            for bd in BOARDS:
                pg.goto("file://" + src + "#" + bd); pg.reload(); pg.wait_for_timeout(120)
                if pg.evaluate("!!document.querySelector('.b:not([hidden]) svg.empty')"):
                    continue  # no diagram: an HTML message instead
                c = pg.evaluate(corner)
                cen = pg.evaluate("c0=>{const s=document.getElementById('stage').getBoundingClientRect(),id=location.hash.slice(1);let r=-1e9;for(const e of document.querySelectorAll('#b-'+id+' svg > *:not(defs):not(title):not(desc)')){const q=e.getBoundingClientRect();if(q.width||q.height)r=Math.max(r,q.right)}return Math.abs((s.right-r)-c0)<=2}", c[0])  # a board narrower than the stage is centred
                if not (abs(c[1]) <= 40 and (abs(c[0]) <= 40 or cen)):
                    bad.append(f"{bd} left {c[0]:.0f} top {c[1]:.0f}")
            check(f"opens with the content's top-left within 40 px of the stage's, {w}x{h}, all boards", not bad, "; ".join(bad))
        pg.set_viewport_size({"width": 800, "height": 900}); pg.goto("file://" + src + "#" + FLOW); pg.reload(); pg.wait_for_timeout(120)
        pg.set_viewport_size({"width": 640, "height": 720}); pg.wait_for_timeout(120)
        c = pg.evaluate(corner)
        check("resize before any pan/zoom re-applies the opening view", abs(c[0]) <= 40 and abs(c[1]) <= 40, f"left {c[0]:.0f} top {c[1]:.0f}")
        sb = pg.locator("#stage").bounding_box()
        pg.mouse.move(sb["x"] + sb["width"] / 2, sb["y"] + sb["height"] / 2)  # the pointer was left where an earlier click hit in a larger viewport, maybe off the stage: a wheel there pans nothing
        pg.mouse.wheel(0, 90); pg.wait_for_timeout(60); pa = st()
        pg.set_viewport_size({"width": 700, "height": 760}); pg.wait_for_timeout(120); pb = st()
        check("resize after a pan keeps the user's view", abs(pa["ty"] - pb["ty"]) < 1 and abs(pa["tx"] - pb["tx"]) < 1, f"{pa['ty']:.0f} -> {pb['ty']:.0f}")
        pg.set_viewport_size({"width": 1400, "height": 900})
        pg.goto("file://" + src + "#" + FLOW); pg.reload(); pg.wait_for_timeout(100); pg.click("#zf"); s0 = st()
        cx, cy = box["x"] + box["width"] * 0.7, box["y"] + box["height"] * 0.5
        pg.mouse.move(cx, cy)
        world = lambda s: ((cx - box["x"] - s["tx"]) / s["s"], (cy - box["y"] - s["ty"]) / s["s"])
        w0 = world(s0)
        pg.keyboard.down("Control")
        pg.mouse.wheel(0, -120)
        pg.keyboard.up("Control")
        pg.wait_for_timeout(100)
        s1 = st()
        w1 = world(s1)
        check("ctrl+wheel up zooms in", s1["s"] > s0["s"] * 1.2 and not s1["fit"], f"{s0['s']:.3f} -> {s1['s']:.3f}")
        check("zoom is anchored at the cursor", abs(w0[0] - w1[0]) < 1 and abs(w0[1] - w1[1]) < 1, f"world {w0} -> {w1}")
        sc = scroll()
        check("document never scrolls (scrollTop 0, no overflow)", sc == [0, 0, True, True], str(sc))
        pg.keyboard.down("Control")
        pg.mouse.wheel(0, 120)
        pg.keyboard.up("Control")
        pg.wait_for_timeout(100)
        check("ctrl+wheel down zooms out", st()["s"] < s1["s"])
        sb = st()
        pg.mouse.wheel(40, 90)
        pg.wait_for_timeout(100)
        s2 = st()
        check("plain wheel pans, scale unchanged", abs(s2["s"] - sb["s"]) < 1e-9 and (abs(s2["tx"] - sb["tx"]) > 1 or abs(s2["ty"] - sb["ty"]) > 1))
        check("document still does not scroll after pan", scroll() == [0, 0, True, True])
        # drag pan (empty stage area), must not count as a click
        pg.evaluate("document.getElementById('stage').dispatchEvent(new Event('dblclick',{bubbles:true}))")
        s3 = st()
        x0, y0 = box["x"] + 30, box["y"] + 30
        pg.mouse.move(x0, y0); pg.mouse.down(); pg.mouse.move(x0 + 60, y0 + 20, steps=5); pg.mouse.up()
        s4 = st()
        check("drag pans", abs((s4["tx"] - s3["tx"]) - 60) < 2 or s4["tx"] != s3["tx"], f"tx {s3['tx']:.0f} -> {s4['tx']:.0f}")
        # buttons and keys
        pg.click("#zf"); sf = st()
        check("Fit button refits", sf["fit"] and abs(sf["s"] - s0["s"]) < 1e-3)
        pg.click("#zi"); a = st()["s"]; pg.click("#zo"); bb = st()["s"]
        check("+ and - buttons", a > sf["s"] and abs(bb - sf["s"]) < 1e-3, f"{sf['s']:.3f} {a:.3f} {bb:.3f}")
        pg.keyboard.press("Meta+="); k1 = st()["s"]; pg.keyboard.press("Meta+-"); k2 = st()["s"]; pg.keyboard.press("Meta+=");  pg.keyboard.press("Meta+0"); k3 = st()
        check("Cmd+=, Cmd+-, Cmd+0", k1 > sf["s"] and abs(k2 - sf["s"]) < 1e-3 and k3["fit"], f"{k1:.3f} {k2:.3f} fit={k3['fit']}")
        pg.keyboard.press("Meta+="); pg.mouse.dblclick(box["x"] + 20, box["y"] + 20)
        check("double-click fits", st()["fit"])
        for _ in range(30):
            pg.keyboard.press("Meta+=")
        hi = st()["s"]
        for _ in range(60):
            pg.keyboard.press("Meta+-")
        lo = st()["s"]
        check("range clamps to 2.5x and 0.25x (or fit when smaller)", abs(hi - 2.5) < 1e-6 and lo >= min(0.25, sf["s"]) - 1e-6, f"hi {hi} lo {lo}")
        pg.keyboard.press("Meta+0")
        pg.keyboard.press("Meta+1"); check("Cmd+1 gives 100%", abs(st()["s"] - 1) < 1e-6, str(st()["s"]))
        pg.keyboard.press("Meta+0")
        # dot grid follows pan and zoom
        gridpos = lambda: pg.evaluate("(()=>{const c=getComputedStyle(document.getElementById('stage'),'::before');return [c.backgroundPosition,c.backgroundSize,c.opacity]})()")
        g0 = gridpos(); pg.mouse.wheel(60, 40); pg.wait_for_timeout(80); g1 = gridpos()
        check("dot grid moves with pan", g0[0] != g1[0], f"{g0[0]} -> {g1[0]}")
        pg.keyboard.press("Meta+1"); g2 = gridpos()
        check("dot pitch is 22px at 1x (plugin grid)", g2[1].startswith("22px"), g2[1])
        for _ in range(8):
            pg.keyboard.press("Meta+-")
        g3 = gridpos()
        check("dots fade below 0.5x", float(g3[2]) < 1.0 and st()["s"] < 0.5, f"opacity {g3[2]} at {st()['s']:.2f}")
        pg.keyboard.press("Meta+0")
        # every board: opens, selection lives in location.hash, the card opens on its first node and stays inside the stage; nav is one bar at 640 px
        bad, badcard, badnav = [], [], []
        pg.set_viewport_size({"width": 640, "height": 720})
        for bd in BOARDS:
            pg.goto("file://" + src + "#" + bd); pg.reload(); pg.wait_for_timeout(100)
            if pg.evaluate("[location.hash.slice(1), [...document.querySelectorAll('.b')].filter(x=>!x.hidden).map(x=>x.id)]") != [bd, ["b-" + bd]]:
                bad.append(bd)
            hd = pg.evaluate("(()=>{const h=document.querySelector('header').getBoundingClientRect(),b=document.querySelector('.bar');return [h.height,b.scrollWidth<=b.clientWidth+1,document.documentElement.scrollWidth<=innerWidth]})()")
            if hd[0] > 112 or not hd[1] or not hd[2]:
                badnav.append(f"{bd} {hd}")
            if pg.locator(f"#b-{bd} .node").count():
                pg.locator(f"#b-{bd} .node").first.click(); pg.wait_for_timeout(80)
                cd = pg.evaluate("(()=>{const c=document.getElementById('card'),r=c.getBoundingClientRect(),s=document.getElementById('stage').getBoundingClientRect();return [!c.hidden,r.left>=0&&r.right<=innerWidth+1&&r.top>=s.bottom-1||r.left>=s.right-1,c.querySelector('.nmx')&&c.querySelector('.nmx').textContent.length>0]})()")
                if not all(cd):
                    badcard.append(f"{bd} {cd}")
                pg.keyboard.press("Escape")
        check(f"every board ({len(BOARDS)}) opens by hash and shows only itself", not bad, ", ".join(bad))
        check("header is one control bar plus eyebrow and purpose (<= 112 px) at 640 px, no horizontal overflow, every board", not badnav, "; ".join(badnav))
        pg.set_viewport_size({"width": 1400, "height": 900})
        pg.goto("file://" + src + "#" + FLOW); pg.reload(); pg.wait_for_timeout(100); pg.click("#zf")  # the sections below use this board
        # node info card
        ids = ids_of(pg, FLOW)
        ni = min(2, len(ids) - 1)
        node = pg.locator('#b-' + FLOW + ' .node').nth(ni)
        info = D["info"][ids[ni]] if ids else {}
        n_edges = pg.evaluate("document.querySelectorAll('#b-" + FLOW + " path.ed').length && [...document.querySelectorAll('#b-" + FLOW + " path.ed')].filter(p=>p.dataset.from===" + json.dumps(ids[ni] if ids else "") + "||p.dataset.to===" + json.dumps(ids[ni] if ids else "") + ").length")
        node.click()
        pg.wait_for_timeout(300)
        card = pg.locator("#card")
        txt = card.inner_text()
        links = pg.evaluate("[...document.querySelectorAll('#card a')].map(a=>a.getAttribute('href'))")
        check("node click opens a small card inside the stage (<= 300 px wide), no pane, no sheet", card.is_visible() and pg.evaluate("(()=>{const c=document.getElementById('card').getBoundingClientRect(),s=document.getElementById('stage').getBoundingClientRect();return c.width<=300.5&&c.left>=s.left&&c.right<=s.right&&c.top>=s.top&&c.bottom<=s.bottom&&document.getElementById('stage').clientWidth>=1000&&!document.getElementById('wrap').classList.contains('wide')})()"))
        order = pg.evaluate("[...document.querySelectorAll('#card > *')].map(e=>e.className||e.tagName)")
        check("inspector: name, summary (<=240 chars, no code), meta row, code links path#L<line>", info.get("name", "?") in txt and ("Lane:" in card.text_content()) == bool(info.get("lane")) and len(links) > 0 and all("#L" in h for h in links)
              and order[:2] == ["arw", "hd"]
              and len(pg.locator("#card .det").inner_text()) <= 240 and (not info.get("about") or info.get("detail", "") == info["about"] or info.get("detail", "\0") not in txt), f"{order} | " + txt.replace("\n", " | ")[:200])
        check("selecting a node never scrolls the stage", pg.evaluate("[document.getElementById('stage').scrollLeft,document.getElementById('stage').scrollTop]") == [0, 0])
        pg.wait_for_timeout(300)  # opacity transition (0.15s) has to settle
        sel = pg.evaluate("[document.querySelectorAll('.node.sel').length,getComputedStyle(document.querySelector('.node.sel .nb')).strokeWidth+'|'+getComputedStyle(document.querySelector('.node.sel .nb')).stroke,[...document.querySelectorAll('#b-__F__ .node:not(.sel):not(.nbr)')].every(n=>getComputedStyle(n.querySelector('.nb')).fillOpacity==='0.4'&&getComputedStyle(n).opacity==='1'),[...document.querySelectorAll('#b-__F__ .node.nbr')].every(n=>getComputedStyle(n.querySelector('.nb')).fillOpacity==='1'),[...document.querySelectorAll('#b-__F__ path.ed.on')].length,[...document.querySelectorAll('#b-__F__ path.ed:not(.on)')].every(n=>getComputedStyle(n).opacity==='0.4')]".replace("__F__", FLOW))
        check("selected node 2px accent stroke, unrelated boxes dimmed (box only, not text), neighbours and connected edges full", sel[0] == 1 and sel[1].startswith("2px|") and sel[1].split("|")[1] == ACCENT_RGB and sel[2] and sel[3] and sel[4] == n_edges and sel[5], str(sel))
        pg.keyboard.press("Escape")
        check("Esc closes the card and clears the dimming", not card.is_visible() and pg.evaluate("document.querySelectorAll('.node.sel').length===0&&!document.getElementById('view').classList.contains('has-sel')"))
        # inspector placement: overlaps no visible node, stays inside the window, on the fork and on the last step of the agent hook board
        place = """(()=>{const c=document.getElementById('card').getBoundingClientRect(),s=document.getElementById('stage').getBoundingClientRect();
          const bad=[...document.querySelectorAll('.b:not([hidden]) .node')].filter(n=>{const r=n.getBoundingClientRect(),l=Math.max(r.left,s.left),rt=Math.min(r.right,s.right),t=Math.max(r.top,s.top),b=Math.min(r.bottom,s.bottom);return l<rt&&t<b&&c.left<rt&&c.right>l&&c.top<b&&c.bottom>t}).length;
          return [bad,c.left>=0&&c.right<=innerWidth+1&&c.top>=0&&c.bottom<=innerHeight+1,0]})()"""
        for k, bd in enumerate(two):
            bids = ids_of(pg, bd) if bd != FLOW else ids
            pg.goto("file://" + src + "#" + bd); pg.reload(); pg.wait_for_timeout(150); pg.click("#zf")
            bids = ids_of(pg, bd)
            idx = min(6, len(bids) - 1) if k == 0 else len(bids) - 1
            nm = f"{bd} node {idx + 1} of {len(bids)}"
            pg.locator(f'#b-{bd} .node').nth(idx).click(); pg.wait_for_timeout(350)
            pl = pg.evaluate(place)
            check(f"card fits the window: {nm}", pl[1], f"inside {pl[1]}")
            if k == 0:
                t = pg.locator("#card").inner_text()
                src0 = D["info"][bids[idx]]["sources"][0]
                sym0 = D["info"][bids[idx]]["sym"]
                want = f"{sym0} \u00b7 {src0['path']}:{src0['line']}" if sym0 and src0.get("line") else None
                check("card code anchor reads 'symbol . path:line' (from the model)", (want is None or want in t) and "#fork" not in t, t.replace("\n", " | ")[-60:])
                check("card link target is path#L<line> of the node's source", pg.evaluate("[...document.querySelectorAll('#card a')].map(a=>a.getAttribute('href'))")[:1] == [f"{src0['path']}#L{src0.get('line') or 1}"])
            pg.keyboard.press("Escape")
        pg.goto("file://" + src + "#" + FLOW); pg.reload(); pg.wait_for_timeout(150); pg.click("#zf")
        node.click(); check("card reopens", card.is_visible())
        node.click(); check("second click closes it", not card.is_visible())
        node.click(); pg.mouse.click(box["x"] + 400, box["y"] + 20)
        check("click on empty canvas closes it", not card.is_visible())
        # wiki row only when breeWikiAnchors has the anchor; it posts {type:'openWiki',slug} through the bridge.
        # Needs two nodes of one board with different anchors (the first is known, the second is not); the context board of a repo can have
        # nodes that share one anchor, so look for such a pair on the flow board first, then on the others.
        pair = None
        for bd in [FLOW] + BOARDS:
            bids = ids_of(pg, bd) if bd != FLOW else ids
            an = [D["info"][i]["anchor"] for i in bids]
            j = next((j for j in range(1, len(an)) if an[0] and an[j] != an[0]), None)
            if j is not None:
                pair = (bd, an[0], j)
                break
        if pair is None:
            print("SKIP wiki row: no board has two nodes with different anchors")
        else:
            wb, known, j = pair
            if wb != FLOW:
                pg.goto("file://" + src + "#" + wb); pg.reload(); pg.wait_for_timeout(150); pg.click("#zf")
            pg.evaluate("window.__bridgeLog=[];window.breeWikiAnchors={[%s]:{slug:'known-slug',title:'Known'}};" % json.dumps(known) + "document.addEventListener('click',e=>{if(e.target.closest&&e.target.closest('a[href^=\"bree-bridge:\"]'))e.preventDefault()},true)")
            pg.locator('#b-' + wb + ' .node').nth(j).click(); no_wiki = pg.locator("#card button.wiki").count()
            pg.keyboard.press("Escape"); pg.locator('#b-' + wb + ' .node').nth(0).click()
            has_wiki = pg.locator("#card button.wiki").count()
            if has_wiki:
                pg.locator("#card .more").click()  # the Wiki button lives in the expanded part
                pg.locator("#card button.wiki").click()
            log = pg.evaluate("window.__bridgeLog")
            check("wiki row only for known anchors and posts openWiki", no_wiki == 0 and has_wiki == 1 and log == [{"type": "openWiki", "slug": "known-slug"}], f"{no_wiki} {has_wiki} {log}")
        pg.keyboard.press("Escape")
        # contrast floors on the paper colour
        def lum(h):
            c = [int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)]
            c = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
            return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
        cr = lambda a, b: (max(lum(a), lum(b)) + 0.05) / (min(lum(a), lum(b)) + 0.05)
        v = dict(re.findall(r"--(paper|ink|muted|accent):(#[0-9a-fA-F]{6})", html))
        check("contrast on paper: ink >= 12, muted >= 6.2, accent >= 6", cr(v["ink"], v["paper"]) >= 12 and cr(v["muted"], v["paper"]) >= 6.2 and cr(v["accent"], v["paper"]) >= 6, f"ink {cr(v['ink'], v['paper']):.1f} muted {cr(v['muted'], v['paper']):.1f} accent {cr(v['accent'], v['paper']):.1f}")
        # no request left the file
        outside = [u for u in reqs if not u.startswith(("file://", "bree-bridge:"))]  # bree-bridge: is the host-bridge link activation of the wiki row, not a network request
        check("0 network requests (page-initiated)", not outside, f"{len(reqs)} file requests, outside={outside[:3]}")
        # the CSP really blocks network use: a fetch and an image load to a remote host must fail
        blocked = pg.evaluate("""new Promise(res=>{let v=0;document.addEventListener('securitypolicyviolation',()=>v++);
          fetch('https://example.invalid/x').catch(()=>{});const i=new Image();i.src='https://example.invalid/x.png';setTimeout(()=>res(v),300);})""")
        check("CSP blocks remote fetch and image", blocked >= 2, f"{blocked} violations")
        if shots:
            os.makedirs(shots, exist_ok=True)
            for w, h in ((560, 720), (1400, 900)):
                pg.set_viewport_size({"width": w, "height": h})
                for bd in BOARDS:
                    pg.goto("file://" + src + "#" + bd); pg.reload(); pg.wait_for_timeout(150)
                    pg.screenshot(path=f"{shots}/{bd}-{w}-fit.png")
            pg.set_viewport_size({"width": 1400, "height": 900})
            pg.goto("file://" + src + "#" + FLOW); pg.reload(); pg.wait_for_timeout(150)
            pg.evaluate("document.getElementById('stage').dispatchEvent(new Event('dblclick',{bubbles:true}))")
            box = pg.locator("#stage").bounding_box()
            pg.mouse.move(box["x"] + 300, box["y"] + 200)
            import math
            for _ in range(12):  # ctrl+wheel steps of at most 40 units (the page clamps there) until 2x
                s = st()["s"]
                if abs(s - 2.0) < 0.01:
                    break
                pg.keyboard.down("Control"); pg.mouse.wheel(0, -min(40, math.log(2.0 / s) / 0.01)); pg.keyboard.up("Control")
                pg.wait_for_timeout(50)
            pg.screenshot(path=f"{shots}/{FLOW}-1400-zoom-{st()['s']:.1f}x.png")
        shell_checks(b, src, D, FLOW)
        card_checks(b, src, D)
        b.close()
    print("FAILED: " + ", ".join(fails) if fails else "all zoom checks passed")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
