"""Architecture views: the Board contract, the registry and the build context.

A view is one module views/<name>.py with `build(ctx) -> Board` (or a list of Boards for a view that makes one board per flow).
render.py is the shell: it calls collect(ctx), then draws the grouped nav, the card, zoom and pan around the boards.
How to add a view: docs/state/2026-10-10-architecture-views-design.md, section "How to add a view".
"""
import importlib, os, re, sys
from dataclasses import dataclass, field

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # scripts/architecture: draw.py, gen.py, names.py live here
if HERE not in sys.path:
    sys.path.insert(0, HERE)

BASE_GROUPS = ["Context", "Containers", "Components", "Flows", "Runtime", "Data", "Changes"]  # nav order; a group without boards is not shown
GROUPS = list(BASE_GROUPS)  # collect() rewrites it in place: agent sections first, then "Facts", when agent output exists
FACTS = "Facts"

# One line per view, in nav order inside its group. A new view adds exactly one line here (and its views/<name>.py).
REGISTRY = [
    "agent",        # agent-authored diagrams (author.py); empty without agent output. Its boards come first, every other board moves to "Facts"
    "context",      # Context: system context (extract_system.py)
    "containers",   # Containers: processes and stores
    "deployment",   # Containers: where each part runs
    "modules",   # Components: module overview
    "flows",     # Flows: one swimlane board per flow
    "layers",    # Components: modules stacked by import rank
    "nested",    # Components: directory containment
    "dependency",   # Components: fan-in badges, ranks, cycles
    "db_schema",   # Data: tables, columns, keys, indexes parsed from CREATE TABLE text
    "sequence",  # Runtime: one sequence board per flow (lifelines = modules)
    "state",     # Runtime: state machines from status/enum fields, cite-gated
    "data_flow", # Runtime: where each flow reads and writes db / fs / git
    "delta",     # Changes: before / changes / after of the module topology (architecture-delta)
]

TOKEN_CAP = 40000  # the user's ceiling for all LLM calls of the views together


@dataclass
class Board:
    id: str          # unique, [a-z0-9-]; it is the DOM id suffix (#b-<id>) and the location.hash
    group: str       # one of GROUPS
    title: str       # nav chip and header title
    purpose: str     # one line under the title (header, ellipsised)
    svg: str         # finished <svg>, colours only through the theme variables, node groups <g class="node" data-id=...>
    nodes: list = field(default_factory=list)   # [{id, name, sub, about, anchor}], id unique across ALL boards: prefix it with the board id
    legend: list = field(default_factory=list)  # [(kind, text)] keys drawn in the svg legend (kept for the checks and the report)
    notes: list = field(default_factory=list)   # plain-text notes (drawn inside the svg legend by the view)
    tokens: int = 0  # LLM tokens this build spent (also logged by ctx.budget)
    css: str = ""    # optional scoped CSS: every rule must start with "#b-<id> "
    entry: str = ""  # node id the card/opening logic may treat as the entry (optional)


class BudgetExceeded(SystemExit):
    pass


class TokenBudget:
    """Hard cap on LLM tokens for the views. charge() raises BudgetExceeded BEFORE the call is counted as allowed, so a view stops cleanly."""

    def __init__(self, cap=TOKEN_CAP):
        self.cap, self.used, self.log = cap, 0, []

    def left(self):
        return self.cap - self.used

    def charge(self, tokens, tag):
        if self.used + tokens > self.cap:
            raise BudgetExceeded(f"token budget {self.cap} exceeded by {tag}: used {self.used} + {tokens}")
        self.used += tokens
        self.log.append({"tag": tag, "tokens": tokens})


def theme_tokens():
    """CSS variables of :root in template.html as {name: value}; views read them for contrast decisions, never hard-code colours."""
    css = open(os.path.join(HERE, "template.html"), encoding="utf-8").read()
    root = re.search(r":root\{(.*?)\}", css, re.S).group(1)
    return dict(re.findall(r"(--[\w-]+):([^;]+)", root))


class Ctx:
    """What build() gets. graph is the gen.Graph (code index) and is built on first use, so a view that needs none costs nothing."""

    def __init__(self, doc, root, names=None, about=None, budget=None, arch_dir=None):
        self.doc, self.root = doc, root          # doc = the flow model (current.architecture.json)
        self.arch_dir = arch_dir or (os.path.join(root, ".architecture") if root else None)   # where the model JSON and its .prev.json live (--out)
        self.names, self.about = names or {}, about or {}   # names cache: anchor -> short name / about text (names.json)
        self.budget = budget or TokenBudget()
        self.theme = theme_tokens()
        self._graph = None

    @property
    def graph(self):
        if self._graph is None:
            import gen
            self._graph = gen.Graph(self.root)
        return self._graph


def empty_svg(message):
    """The one-line empty state of a view whose source is missing, for example "No database schema found"."""
    from draw import esc
    return (f'<svg viewBox="0 0 480 96" width="480" height="96" class="empty" data-msg="{esc(message)}" role="img" aria-label="{esc(message)}"><title>{esc(message)}</title>'
            f'<text class="lg" x="40" y="52" font-size="13">{esc(message)}</text></svg>')


def _check(b, seen_boards, seen_nodes, groups):
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", b.id):
        raise SystemExit(f"board id {b.id!r}: use [a-z0-9-]")
    if b.id in seen_boards:
        raise SystemExit(f"duplicate board id {b.id!r}")
    if b.group not in groups:
        raise SystemExit(f"board {b.id}: group {b.group!r} is not one of {groups}")
    if not b.svg.startswith("<svg"):
        raise SystemExit(f"board {b.id}: svg must start with <svg")
    for nd in b.nodes:
        if nd["id"] in seen_nodes:
            raise SystemExit(f"board {b.id}: node id {nd['id']!r} already used by board {seen_nodes[nd['id']]} (prefix ids with the board id)")
        seen_nodes[nd["id"]] = b.id
    for rule in filter(None, (r.split("{")[0].strip() for r in b.css.split("}"))):
        if not all(s.strip().startswith(f"#b-{b.id}") for s in rule.split(",")):
            raise SystemExit(f"board {b.id}: css selector {rule!r} must start with '#b-{b.id}'")
    seen_boards.add(b.id)


def collect(ctx, registry=None):
    """Build every registered view. Returns boards in nav order: group order first, registry order inside a group.
    With agent output (views/agent.py) the agent boards come first in manifest order, in the agent's own sections, and every other board
    moves to the last section "Facts". GROUPS is rewritten in place so render.py's nav follows without an edit."""
    out, seen_b, seen_n, agent_ids = [], set(), {}, set()
    names = REGISTRY if registry is None else registry
    for name in names:
        made = importlib.import_module(f"views.{name}").build(ctx)
        made = made if isinstance(made, list) else [made]
        if name == "agent":
            agent_ids |= {b.id for b in made}
        out += made
    if agent_ids:
        secs = list(dict.fromkeys(b.group for b in out if b.id in agent_ids))
        groups = secs + [FACTS]
        for b in out:
            if b.id not in agent_ids:
                b.group = FACTS
    else:
        groups = list(BASE_GROUPS)
    GROUPS[:] = groups
    for b in out:
        _check(b, seen_b, seen_n, groups)
    agent_first = [b for b in out if b.id in agent_ids]
    return agent_first + sorted([b for b in out if b.id not in agent_ids], key=lambda b: groups.index(b.group))
