#!/usr/bin/env python3
"""Layout check for the rendered boards, in real headless Chrome.  check_svg.py <current.html> [width=560]

For every board, at the given window width: (1) effective font size of every <text> (computed font-size * rendered scale); fewer than 11px is a FLOOR warning (printed, not an
issue: the fit scale of a wide board at a narrow window cannot be fixed by the renderer, zoom is the remedy), an unparsable size is an issue,
(2) every text box lies inside its node rect (no clipping) and inside the svg, (3) no two text boxes overlap,
(4) no text box overlaps a node rect it does not belong to,
(5) no edge passes through a node rect (inset 4px) other than its source/target, (6) no two edges share a collinear run (parallel within 12px, diagram-design rule 3) > 8px unless it is the last run of both and they end at the same point, (7) edge ports on one node side are >= 12px apart and >= 8px from a corner (rule 4), (8) every edge label mask keeps >= 6px from every edge stroke and does not touch a node (rules 2, 6), (9) counts: nodes and edges found in the SVG equal the model's (a wrapped group must not make the edge checks vacuous). Boxes come from getBoundingClientRect (tolerance 0.5px).
Usage: check_svg.py <current.html> [width=560] [height=1600]. Exit code 1 on any issue. Reads the HTML, never edits it (a temp copy gets the probe script).
"""
import glob, json, os, re, subprocess, sys, tempfile

ENV = "BREE_ARCHITECTURE_BROWSER"
_APPS = [("Google Chrome", "Google Chrome"), ("Chromium", "Chromium"), ("Google Chrome for Testing", "Google Chrome for Testing"),
         ("Microsoft Edge", "Microsoft Edge"), ("Brave Browser", "Brave Browser")]


def find_browser():
    """Path of a Chromium-family browser: $BREE_ARCHITECTURE_BROWSER, else the first installed one (Chrome, Chromium, Chrome for Testing, Edge, Brave, Playwright cache). None if absent."""
    env = os.environ.get(ENV)
    if env:
        return env if os.access(env, os.X_OK) else None
    home = os.path.expanduser("~")
    for root in ("/Applications", home + "/Applications"):
        for app, exe in _APPS:
            p = f"{root}/{app}.app/Contents/MacOS/{exe}"
            if os.access(p, os.X_OK):
                return p
    pw = sorted(glob.glob(home + "/Library/Caches/ms-playwright/chromium-*/chrome-mac*/*.app/Contents/MacOS/*"), reverse=True)
    return next((p for p in pw if os.access(p, os.X_OK) and "Helper" not in p), None)


def browser_or_exit(tool):
    p = find_browser()
    if not p:
        sys.exit(f"{tool}: no usable Chromium-family browser found (looked at ${ENV}, Chrome/Chromium/Chrome for Testing/Edge/Brave in /Applications and ~/Applications, the Playwright cache); install one or set {ENV} to its executable")
    return p

PROBE = """<script>
(function(){const out={};const T=0.5;const EXPECT=/*EXPECT*/;
for(const id in D.boards){open(id);fitView();const svg=document.querySelector('#b-'+id+' svg');
 if(svg.classList.contains('empty')){out[id]={scale:0,texts:0,nodes:0,edges:0,labels:0,minFontPx:0,floor:0,issues:[]};continue;}  // no diagram: the shell shows an HTML message
 const sr=svg.getBoundingClientRect();
 const sc=sr.width/svg.viewBox.baseVal.width;const issues=[];const floor=new Set();const texts=[];const rects=[];
 svg.querySelectorAll('.node').forEach((g,gi)=>{const r=g.querySelector('rect').getBoundingClientRect();rects.push({gi,r});
  g.querySelectorAll('text').forEach(t=>texts.push({t,gi,b:t.getBoundingClientRect()}));});
 svg.querySelectorAll(':scope > text, :scope > g:not(.node) text').forEach(t=>texts.push({t,gi:-1,b:t.getBoundingClientRect()}));
 let minFont=99;
 for(const x of texts){const fs=parseFloat(getComputedStyle(x.t).fontSize)*sc;const s=x.t.textContent;
  if(!(fs>0))issues.push('unparsable font size: '+s);else{minFont=Math.min(minFont,fs);if(fs<11)floor.add(s);}
  if(x.b.left<sr.left-T||x.b.right>sr.right+T||x.b.top<sr.top-T||x.b.bottom>sr.bottom+T)issues.push('outside svg: '+s);
  if(x.gi>=0){const r=rects[x.gi].r;if(x.b.left<r.left-T||x.b.right>r.right+T||x.b.top<r.top-T||x.b.bottom>r.bottom+T)issues.push('clipped by node: '+s);}
  for(const q of rects){if(q.gi===x.gi)continue;const r=q.r;if(x.b.left<r.right-T&&x.b.right>r.left+T&&x.b.top<r.bottom-T&&x.b.bottom>r.top+T)issues.push('over foreign node: '+s);}}
 for(let i=0;i<texts.length;i++)for(let j=i+1;j<texts.length;j++){const a=texts[i].b,b=texts[j].b;
  if(a.left<b.right-T&&a.right>b.left+T&&a.top<b.bottom-T&&a.bottom>b.top+T)issues.push('overlap: '+texts[i].t.textContent+' | '+texts[j].t.textContent);}
 // edges (svg > path): (5) no segment inside a foreign node rect shrunk by 4, (6) no two edges share a collinear run > 8 unless it is the last run of both and they end at the same point
 const NR=[];svg.querySelectorAll('.node').forEach(g=>{const e=g.querySelector('rect');NR.push({id:g.dataset.id,x:+e.getAttribute('x'),y:+e.getAttribute('y'),w:+e.getAttribute('width'),h:+e.getAttribute('height')});});
 const near=(q,p,t)=>p[0]>=q.x-t&&p[0]<=q.x+q.w+t&&p[1]>=q.y-t&&p[1]<=q.y+q.h+t;
 const E=[];svg.querySelectorAll(':scope > path').forEach((p,k)=>{const L=p.getTotalLength();const pts=[];
  for(let d=0;d<=L;d+=1){const q=p.getPointAtLength(d);pts.push([q.x,q.y]);}const q=p.getPointAtLength(L);pts.push([q.x,q.y]);
  const own=new Set(NR.filter(r=>near(r,pts[0],1.5)||near(r,pts[pts.length-1],1.5)).map(r=>r.id));
  const nm=NR.filter(r=>near(r,pts[0],1.5)).map(r=>r.id)[0]+'->'+NR.filter(r=>near(r,pts[pts.length-1],1.5)).map(r=>r.id)[0];
  const runs=[];let a=0;for(let i=1;i<=pts.length;i++){const hz=i<pts.length&&Math.abs(pts[i][1]-pts[a][1])<0.01,vt=i<pts.length&&Math.abs(pts[i][0]-pts[a][0])<0.01;
   if(i<pts.length&&(i-a===1||(Math.abs(pts[a][1]-pts[a+1][1])<0.01?hz:vt)))continue;
   if(i-1-a>=1)runs.push({a:pts[a],b:pts[i-1],h:Math.abs(pts[a][1]-pts[a+1][1])<0.01});a=i-1;}
  E.push({k,nm,own,pts,runs,end:pts[pts.length-1]});
  const hit=new Set();for(const r of NR){if(own.has(r.id))continue;
   for(const q of pts)if(q[0]>r.x+4&&q[0]<r.x+r.w-4&&q[1]>r.y+4&&q[1]<r.y+r.h-4){hit.add(r.id);break;}}
  hit.forEach(id=>issues.push('edge '+nm+' passes through node '+id));});
 for(let i=0;i<E.length;i++)for(let j=i+1;j<E.length;j++){const A=E[i],B=E[j];let worst=0,at=null;
  for(const ra of A.runs)for(const rb of B.runs){if(ra.h!==rb.h)continue;const c=ra.h?1:0,v=ra.h?0:1;
   if(Math.abs(ra.a[c]-rb.a[c])>=12)continue;
   const lo=Math.max(Math.min(ra.a[v],ra.b[v]),Math.min(rb.a[v],rb.b[v])),hi=Math.min(Math.max(ra.a[v],ra.b[v]),Math.max(rb.a[v],rb.b[v]));
   if(hi-lo>8){const ends=(r,P)=>Math.hypot(r.b[0]-P[0],r.b[1]-P[1])<1.5;const common=Math.hypot(A.end[0]-B.end[0],A.end[1]-B.end[1])<1.5&&ends(ra,A.end)&&ends(rb,B.end);
    if(!common&&hi-lo>worst){worst=hi-lo;at=(ra.h?'y=':'x=')+ra.a[c].toFixed(0);}}}
  if(worst>8)issues.push('edges '+A.nm+' and '+B.nm+' share '+worst.toFixed(0)+'px collinear at '+at);}
 // (7) fanned ports
 for(const r of NR){const sides={t:[],b:[],l:[],r:[]};
  E.forEach(e=>{for(const P of [e.pts[0],e.pts[e.pts.length-1]]){const T=1.5;
   if(Math.abs(P[1]-r.y)<T&&P[0]>=r.x-T&&P[0]<=r.x+r.w+T)sides.t.push([P[0],e.nm]);
   else if(Math.abs(P[1]-(r.y+r.h))<T&&P[0]>=r.x-T&&P[0]<=r.x+r.w+T)sides.b.push([P[0],e.nm]);
   else if(Math.abs(P[0]-r.x)<T&&P[1]>=r.y-T&&P[1]<=r.y+r.h+T)sides.l.push([P[1],e.nm]);
   else if(Math.abs(P[0]-(r.x+r.w))<T&&P[1]>=r.y-T&&P[1]<=r.y+r.h+T)sides.r.push([P[1],e.nm]);}});
  for(const k in sides){const a=sides[k].sort((u,v)=>u[0]-v[0]);
   for(let i=0;i+1<a.length;i++)if(a[i+1][0]-a[i][0]<12)issues.push('ports closer than 12px on '+k+' of '+r.id+': '+a[i][1]+' | '+a[i+1][1]);}}
 // (8) label masks: svg > rect.mask directly followed by text.al
 const masks=[...svg.querySelectorAll(':scope > rect.mask')].filter(m=>m.nextElementSibling&&m.nextElementSibling.classList.contains('al'));
 for(const m of masks){const x=+m.getAttribute('x'),y=+m.getAttribute('y'),w=+m.getAttribute('width'),h=+m.getAttribute('height');let md=1e9;
  for(const e of E)for(const q of e.pts){const dx=Math.max(x-q[0],0,q[0]-(x+w)),dy=Math.max(y-q[1],0,q[1]-(y+h));md=Math.min(md,Math.hypot(dx,dy));}
  if(md<6)issues.push('label '+m.nextElementSibling.textContent+' only '+md.toFixed(1)+'px from an edge stroke');
  if(md>10.5)issues.push('label '+m.nextElementSibling.textContent+' '+md.toFixed(1)+'px from the nearest stroke (> 10)');
  for(const r of NR)if(x<r.x+r.w&&x+w>r.x&&y<r.y+r.h&&y+h>r.y)issues.push('label '+m.nextElementSibling.textContent+' overlaps node '+r.id);}
 // (9) counts against the model
 // a board outside the flow model (a views/*.py board) is held to its own Board.nodes; its edge count is not declared, so only nodes are compared
 const X=EXPECT[id]||{nodes:Object.values(D.info).filter(i=>i.board===id).length,edges:null};if(NR.length!==X.nodes)issues.push('nodes in svg '+NR.length+' != model '+X.nodes);
 if(X.edges!==null&&E.length!==X.edges)issues.push('edges in svg '+E.length+' != model '+X.edges);
 out[id]={scale:+sc.toFixed(3),texts:texts.length,nodes:NR.length,edges:E.length,labels:masks.length,minFontPx:+minFont.toFixed(1),floor:[...floor].length,issues};}
document.title='PROBE'+JSON.stringify(out);})();
</script></body>"""


def expected_counts(jpath):
    """board -> {nodes, edges} the SVG must contain. Overview edges: visible ones minus back edges (render.py drops cycle edges, listed in the note)."""
    d = json.load(open(jpath))
    out = {}
    for b in d["boards"]:
        nodes = [x for x in d["nodes"] if x["board"] == b["id"]]
        edges = [e for e in d["edges"] if e["board"] == b["id"] and "hidden" not in e]
        out[b["id"]] = {"nodes": len(nodes), "edges": len(edges)}
    return out


def main():
    chrome = browser_or_exit("check_svg.py")
    src, width = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 560
    height = int(sys.argv[3]) if len(sys.argv) > 3 else 1600
    expect = expected_counts(os.path.join(os.path.dirname(os.path.abspath(src)), "current.architecture.json"))
    page = open(src, encoding="utf-8").read().replace("</body>", PROBE.replace("/*EXPECT*/", json.dumps(expect)))
    with tempfile.TemporaryDirectory() as td:
        p = os.path.join(td, "probe.html")
        open(p, "w", encoding="utf-8").write(page)
        r = subprocess.run([chrome, "--headless=new", "--disable-gpu", f"--window-size={width},{height}", "--dump-dom", "file://" + p],
                           capture_output=True, text=True, timeout=120)
    m = re.search(r"<title>PROBE(.*?)</title>", r.stdout, re.S)
    if not m:
        sys.exit("probe did not run: " + r.stderr[-300:])
    import html
    res = json.loads(html.unescape(m.group(1)))
    bad = 0
    for k, v in res.items():
        print(f"{k:22} scale={v['scale']} nodes={v['nodes']} edges={v['edges']} labels={v['labels']} texts={v['texts']} minFont={v['minFontPx']}px "
              f"floor11={'FAIL(' + str(v['floor']) + ' texts)' if v['floor'] else 'ok'} issues={len(v['issues'])}")
        for i in v["issues"]:
            print("   ", i)
        bad += len(v["issues"])
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
