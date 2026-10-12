"""Citation gate and cache of extract_system.py.  python3 -m unittest test_extract_system   (from scripts/architecture; 0 tokens, fake llm)"""
import json, os, tempfile, unittest
import extract_system as ex


class Gate(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        open(os.path.join(self.d, "README.md"), "w").write("# demo\nThe Daemon writes the Journal to disk.\nA user runs the CLI.\n")
        self.cache = tempfile.mkdtemp()
        self.calls = 0

    def llm(self, prompt, model, tag):
        self.calls += 1
        n = lambda i, name, kind, cite, term: {"id": i, "name": name, "kind": kind, "host": "", "sub": "", "about": "", "cite": cite, "term": term}
        raw = {"nodes": [n("daemon", "Daemon", "daemon", "README.md:2", "daemon"),          # real cite
                         n("journal", "Journal", "store", "README.md:2", "JOURNAL"),         # real, case-folded
                         n("ghost", "Ghost", "process", "README.md:2", "ghostly"),          # term not on the line
                         n("far", "Far", "process", "README.md:99", "daemon"),              # line does not exist
                         n("esc", "Esc", "file", "../etc/passwd:1", "root")],               # outside the repo
               "edges": [{"from": "daemon", "to": "journal", "label": "writes", "io": "write", "cite": "README.md:2", "term": "writes"},
                         {"from": "daemon", "to": "journal", "label": "dup", "io": "write", "cite": "README.md:2", "term": "writes"},
                         {"from": "daemon", "to": "ghost", "label": "x", "io": "call", "cite": "README.md:2", "term": "daemon"}]}
        return raw, {"tokens_in": 100, "tokens_out": 20}

    def test_gate_and_cache(self):
        r = ex.extract(self.d, llm=self.llm, cache=self.cache, settings="/nonexistent")
        self.assertEqual([x["id"] for x in r["nodes"]], ["daemon", "journal"])          # fabricated cites dropped, real kept
        self.assertEqual(r["stats"]["nodes_dropped"], 3)
        self.assertEqual(len(r["edges"]), 1)                                            # edge to a dropped node is dropped
        self.assertFalse(r["edges"][0]["inferred"])
        self.assertEqual(r["tokens"], 120)
        r2 = ex.extract(self.d, llm=self.llm, cache=self.cache, settings="/nonexistent")
        self.assertEqual((self.calls, r2["tokens"]), (1, 0))                            # cached: no second call, 0 tokens
        self.assertEqual(r2["nodes"], r["nodes"])

    def test_bad_edge_cite_is_dashed(self):
        src = ex.sources(self.d, "/nonexistent")
        raw = {"nodes": [{"id": "a", "name": "A", "kind": "process", "cite": "README.md:2", "term": "daemon"},
                         {"id": "b", "name": "B", "kind": "store", "cite": "README.md:2", "term": "journal"}],
               "edges": [{"from": "a", "to": "b", "cite": "README.md:3", "term": "journal"}]}
        g = ex.gate(raw, self.d, src)
        self.assertTrue(g["edges"][0]["inferred"])

    def test_reversed_edge_is_inferred(self):
        open(os.path.join(self.d, "README.md"), "a").write("Claude Code fires the my-index hook.\n")
        src = ex.sources(self.d, "/nonexistent")
        n = lambda i, t: {"id": i, "name": i, "kind": "external", "cite": "README.md:4", "term": t}
        raw = {"nodes": [n("claude", "claude code"), n("hm", "my-index")],
               "edges": [{"from": "claude", "to": "hm", "cite": "README.md:4", "term": "fires"},
                         {"from": "hm", "to": "claude", "cite": "README.md:4", "term": "fires"}]}
        g = {(e["from"], e["to"]): e["inferred"] for e in ex.gate(raw, self.d, src)["edges"]}
        self.assertEqual(g, {("claude", "hm"): False, ("hm", "claude"): True})

    def test_no_sources_is_empty_without_a_call(self):
        e = tempfile.mkdtemp()
        r = ex.extract(e, llm=self.llm, cache=self.cache, settings="/nonexistent")
        self.assertTrue(r["empty"]); self.assertEqual(self.calls, 0)

class Seeds(unittest.TestCase):
    """Deterministic seeds: host tool, Developer and the indexed repo come from the hook config and README, whatever the model says."""

    def setUp(self):
        self.d = tempfile.mkdtemp()
        open(os.path.join(self.d, "README.md"), "w").write("# demo\nIt indexes a repo and answers queries.\n")
        self.cache = tempfile.mkdtemp()
        cfg = os.path.join(tempfile.mkdtemp(), ".claude")
        os.makedirs(cfg)
        self.settings = os.path.join(cfg, "settings.json")
        json.dump({"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"command": os.path.join(self.d, "bin", "demo") + " hook go"}]}]}}, open(self.settings, "w"))

    def run_with(self, raw, cache=None):
        return ex.extract(self.d, llm=lambda p, m, t: (raw, {"tokens_in": 1, "tokens_out": 1}), cache=cache or tempfile.mkdtemp(), settings=self.settings)

    def test_seeds_do_not_depend_on_the_model(self):
        n = lambda i, name, kind: {"id": i, "name": name, "kind": kind, "cite": "README.md:2", "term": "indexes"}
        runs = [{"nodes": []}, {"nodes": [n("claude", "Claude Code", "external"), n("sub", "Subagent", "external")]},
                {"nodes": [n("user", "User", "person"), n("claude_code_cli", "Claude Code", "external")]}]
        seeded = []
        for raw in runs:
            r = self.run_with(raw)
            by = {x["id"]: x for x in r["nodes"]}
            seeded.append({k: by[k] for k in ("claude_code", "developer", "indexed_repo")})
            self.assertEqual(by["developer"]["kind"], "person")
            self.assertEqual(by["developer"]["sub"], "implied by hook config")
            self.assertTrue(by["claude_code"]["cite"].startswith("hook-config:"))
            self.assertEqual(by["indexed_repo"]["cite"], "README.md:2")
            self.assertEqual(sum(x["name"] == "Claude Code" for x in r["nodes"]), 1)      # the model's duplicate is merged
            self.assertEqual(sum(x["kind"] == "person" for x in r["nodes"]), 1)
            ids = {x["id"] for x in r["nodes"]} | {"system"}
            self.assertTrue(all(e["from"] in ids and e["to"] in ids for e in r["edges"]))
        self.assertEqual(seeded[0], seeded[1]); self.assertEqual(seeded[1], seeded[2])    # same seeds in every run

    def test_no_hook_config_no_host_and_no_developer(self):
        r = ex.extract(self.d, llm=lambda p, m, t: ({"nodes": []}, {}), cache=tempfile.mkdtemp(), settings="/nonexistent")
        self.assertEqual([x["id"] for x in r["nodes"]], ["indexed_repo"])


if __name__ == "__main__":
    unittest.main()
