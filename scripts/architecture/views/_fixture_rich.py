"""Fixture board with the optional rich node keys (kind, summary, what, why, connects, code, watch, unverified): exercises the full inspector.
NOT in REGISTRY. render_fixture.py adds it to a page; zoom_check.py renders it for the inspector checks.
The keys are the contract with the agent-authored diagrams (docs/state/2026-10-10-architecture-agent-authored-design.md, section A)."""
from draw import Canvas, M, NODE_H, STEP_W, up4
from . import Board

BOARD_ID = "fixture-rich"
W_, H_ = 2 * M + 4 * 264, 2 * M + 2 * 150 + NODE_H


def _n(k, name, kind, summary, what, why, connects, code, watch="", unverified=False):
    d = {"id": f"{BOARD_ID}:{k}", "name": name, "sub": kind, "about": summary, "kind": kind, "summary": summary, "what": what, "why": why,
         "connects": [{"to": f"{BOARD_ID}:{t}", "label": lab, "dir": dr} for t, lab, dr in connects], "code": code}
    if watch:
        d["watch"] = watch
    if unverified:
        d["unverified"] = True
    return d


NODES = [
    _n("hook", "Agent hook", "entry", "Ajan bir komut çalıştırınca ilk tetiklenen kanca.",
       "Ajanın her araç çağrısından önce ve sonra çalışır. Çağrının adını ve yolunu okuyup indeks sorgusuna çevirir.",
       "Ajan koda bakarken hangi dosyaya gittiğini bilmeden dolaşır; kanca ona doğru haritayı o anda verir.",
       [("route", "olay", "out")], [{"path": "scripts/architecture/gen.py", "line": 839, "symbol": "main"}],
       "Kanca 2 saniyeden uzun sürerse ajan onu atlar."),
    _n("route", "Router", "step", "Gelen olayı doğru sorguya yönlendirir.",
       "Olay türüne bakar ve map, refs veya show sorgularından birini seçer. Bilinmeyen türü sessizce atlar.",
       "Tek bir giriş noktası olmasa her kanca kendi sorgu mantığını kopyalardı.",
       [("hook", "olay", "in"), ("index", "sorgu", "out"), ("cache", "bakış", "out")],
       [{"path": "scripts/architecture/render.py", "line": 36, "symbol": "render_page"}, {"path": "scripts/architecture/draw.py", "line": 63, "symbol": "Canvas"}]),
    _n("index", "Index", "store", "Kodun sembol ve çağrı haritasını tutan depo.",
       "Her dosyadaki sembolleri, çağıranları ve testleri bir SQLite dosyasında saklar. Sorgular bu dosyadan okur.",
       "Her sorguda depoyu baştan taramak yüzlerce milisaniye tutardı; indeks bunu birkaç milisaniyeye indirir.",
       [("route", "sorgu", "in"), ("fmt", "satırlar", "out")], [{"path": "scripts/architecture/names.py", "line": 59, "symbol": "load"}],
       "İndeks eskiyse sonuçlar yanlış yeri gösterir; dosya değişince yeniden kurulmalı."),
    _n("fmt", "Formatter", "step", "Sonuçları ajanın okuyacağı kısa metne çevirir.",
       "Satırları dosya ve satır numarasıyla birkaç satıra sıkıştırır. 40 satırdan fazlasını keser.",
       "Ajanın bağlamı sınırlı; uzun bir döküm asıl işi dışarı iter.",
       [("index", "satırlar", "in"), ("out", "metin", "out")], [{"path": "scripts/architecture/draw.py", "line": 24, "symbol": "up4"}]),
    _n("cache", "Cache", "store", "Son sorguların cevabını kısa süre saklar.",
       "Aynı sorgu iki kez gelirse cevabı bellekten verir. Kayıtlar 60 saniye sonra düşer.",
       "Ajan aynı dosyayı art arda sorar; cache bunu ücretsiz yapar.",
       [("route", "bakış", "in"), ("out", "isabet", "out")], [], unverified=True),
    _n("out", "Hook output", "exit", "Ajana dönen metin.",
       "Formatter'ın metnini kancanın çıkışına yazar. Boşsa hiçbir şey yazmaz ki ajan gürültü görmesin.",
       "Çıkışın tek bir yerden gitmesi, ajanın neyi gördüğünü denetlemeyi kolaylaştırır.",
       [("fmt", "metin", "in"), ("cache", "isabet", "in")], [{"path": "scripts/architecture/template.html", "line": 1, "symbol": "template"}]),
]


def build(ctx):
    cv = Canvas(BOARD_ID)
    cx = lambda c: M + STEP_W / 2 + c * 264
    r1, r2 = M + NODE_H / 2, M + NODE_H / 2 + 150
    pos = {"hook": (0, r1), "route": (1, r1), "index": (2, r1), "fmt": (3, r1), "cache": (1, r2), "out": (3, r2)}
    for nd in NODES:
        k = nd["id"].split(":")[1]
        c, y = pos[k]
        cv.node(nd["id"], cx(c), y, STEP_W, NODE_H, nd["name"], nd["sub"], kind="focal" if k == "hook" else "store" if k in ("index", "cache") else "step")
    h = STEP_W / 2
    E = lambda a, b, pts: cv.edge(pts, src=f"{BOARD_ID}:{a}", dst=f"{BOARD_ID}:{b}")
    E("hook", "route", [(cx(0) + h, r1), (cx(1) - h, r1)])
    E("route", "index", [(cx(1) + h, r1), (cx(2) - h, r1)])
    E("index", "fmt", [(cx(2) + h, r1), (cx(3) - h, r1)])
    E("route", "cache", [(cx(1), r1 + NODE_H / 2), (cx(1), r2 - NODE_H / 2)])
    E("fmt", "out", [(cx(3), r1 + NODE_H / 2), (cx(3), r2 - NODE_H / 2)])
    E("cache", "out", [(cx(1) + h, r2), (cx(3) - h, r2)])
    lh = cv.legend(H_ - 8, W_, [("box", "Step"), ("line", "Call")])
    svg = cv.svg(W_, up4(H_ - 8 + lh + M), "Fixture: hook to output", "Six nodes with the rich keys.")
    return Board(id=BOARD_ID, group="Flows", title="Fixture: rich nodes",
                 purpose="Test board with every optional node key, to exercise the full inspector: summary, what, why, connections, code and a warning.",
                 svg=svg, nodes=NODES, entry=f"{BOARD_ID}:hook")
