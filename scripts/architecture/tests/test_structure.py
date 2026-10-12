"""Stage 1 B: schema parser, cycle detection, layer order. Run: python3 -m unittest discover -s tests   (from scripts/architecture)"""
import os, sys, unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from views import _struct, db_schema

DDL = '''
db.executescript("""
CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE);
CREATE TABLE orders(
  id INTEGER PRIMARY KEY,
  user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  note TEXT -- trailing comment, with comma
);
CREATE TABLE order_items(order_id INT, sku TEXT, qty INT DEFAULT (1),
  PRIMARY KEY(order_id, sku),
  FOREIGN KEY(order_id) REFERENCES orders(id) ON DELETE RESTRICT);
CREATE INDEX IF NOT EXISTS orders_user ON orders(user_id);
CREATE UNIQUE INDEX uq_items ON order_items(order_id, sku);
CREATE VIRTUAL TABLE ix USING fts5(path, body);
""")
'''


class Schema(unittest.TestCase):
    def setUp(self):
        self.t, self.ix = db_schema.parse_schema(DDL)
        self.by = {t["name"]: t for t in self.t}

    def test_tables(self):
        self.assertEqual([t["name"] for t in self.t], ["users", "orders", "order_items"])  # virtual table skipped

    def test_columns_and_inline_fk(self):
        o = self.by["orders"]
        self.assertEqual([c["name"] for c in o["columns"]], ["id", "user_id", "note"])
        uid = o["columns"][1]
        self.assertEqual(uid["fk"], ("users", "id", "ON DELETE CASCADE"))
        self.assertTrue(uid["nn"])
        self.assertTrue(o["columns"][0]["pk"])
        self.assertTrue(self.by["users"]["columns"][1]["uq"])

    def test_composite_pk_and_table_fk(self):
        it = self.by["order_items"]
        self.assertEqual(it["pk"], ["order_id", "sku"])
        self.assertTrue(all(c["pk"] for c in it["columns"][:2]) and not it["columns"][2]["pk"])
        self.assertEqual(it["columns"][0]["fk"], ("orders", "id", "ON DELETE RESTRICT"))
        self.assertEqual(it["columns"][2]["type"], "INT")

    def test_indexes(self):
        self.assertEqual(self.ix, [{"name": "orders_user", "table": "orders", "cols": ["user_id"], "unique": False},
                                   {"name": "uq_items", "table": "order_items", "cols": ["order_id", "sku"], "unique": True}])

    def test_no_schema(self):
        self.assertEqual(db_schema.parse_schema("print('hi')"), ([], []))


class Graph(unittest.TestCase):
    def test_three_cycle(self):
        nodes, edges = list("abcd"), [("a", "b"), ("b", "c"), ("c", "a"), ("c", "d")]
        cyc = _struct.find_cycles(nodes, edges)
        self.assertEqual(len(cyc), 1)
        self.assertEqual(sorted(cyc[0]), ["a", "b", "c"])
        fwd, back = _struct.split_back(nodes, edges)
        self.assertEqual(back, [("c", "a")])
        self.assertEqual(len(fwd), 3)

    def test_acyclic_has_no_cycle(self):
        self.assertEqual(_struct.find_cycles(list("abc"), [("a", "b"), ("b", "c"), ("a", "c")]), [])

    def test_layer_order(self):
        # a -> b -> c, a -> c, d -> c ; c is the foundation (bottom), a the top
        nodes, edges = list("abcd"), [("a", "b"), ("b", "c"), ("a", "c"), ("d", "c")]
        L = _struct.layers(nodes, edges)
        self.assertEqual(L["c"], max(L.values()))             # foundation is the last (bottom) row
        self.assertLess(L["a"], L["b"]); self.assertLess(L["b"], L["c"])
        self.assertEqual(L["d"], L["b"])                       # d sits just above c, level with b
        for a, b in edges:
            self.assertLess(L[a], L[b])                        # every import points to a lower row

    def test_layers_ignore_back_edge(self):
        L = _struct.layers(list("abc"), [("a", "b"), ("b", "c"), ("c", "a")])
        self.assertEqual([L[x] for x in "abc"], [0, 1, 2])


if __name__ == "__main__":
    unittest.main()
