"""Tests for db.replace_future_classes — verifies it invokes the atomic
replace_future_classes Postgres function (RPC) with the correct arguments, including
the covered-through window that prevents a partial scrape from erasing later-dated rows.

db.py imports supabase and dotenv at module load; we stub them (and the client) so this
runs with only the standard library.
"""
import sys
import types
import unittest
from datetime import date, timedelta


# --- stub third-party imports before importing db ----------------------------
_sb = types.ModuleType("supabase")
_sb.create_client = lambda *a, **k: None
_sb.Client = object
sys.modules["supabase"] = _sb

_dotenv = types.ModuleType("dotenv")
_dotenv.load_dotenv = lambda *a, **k: None
sys.modules["dotenv"] = _dotenv

# Another test module (test_normalizers) stubs a FAKE `db` in sys.modules; evict it so
# we import the real db.py here regardless of test execution order.
sys.modules.pop("db", None)
import db  # noqa: E402

# Guard against the fake sneaking through: the real module must expose get_client.
assert hasattr(db, "get_client"), "imported a stubbed 'db', not the real module"


class FakeRPC:
    def __init__(self, log):
        self.log = log

    def execute(self):
        self.log.append(("execute",)); return self


class FakeClient:
    """Records rpc() invocations so the test can assert on function name + params."""
    def __init__(self, log):
        self.log = log

    def rpc(self, fn, params):
        self.log.append(("rpc", fn, params))
        return FakeRPC(self.log)


class TestReplaceFutureClasses(unittest.TestCase):
    def setUp(self):
        self.log = []
        self._orig = db.get_client
        db.get_client = lambda: FakeClient(self.log)

    def tearDown(self):
        db.get_client = self._orig

    def _rpc_call(self):
        calls = [e for e in self.log if e[0] == "rpc"]
        self.assertEqual(len(calls), 1, "expected exactly one rpc() call")
        return calls[0]

    def test_calls_rpc_with_covered_window(self):
        today = date.today().isoformat()
        covered = (date.today() + timedelta(days=7)).isoformat()
        classes = [{"id": "a", "date": covered}]
        db.replace_future_classes("studio-1", classes, covered_through=covered)

        _, fn, params = self._rpc_call()
        self.assertEqual(fn, "replace_future_classes")
        self.assertEqual(params["p_studio_id"], "studio-1")
        self.assertEqual(params["p_today"], today)
        self.assertEqual(params["p_covered_through"], covered)
        self.assertEqual(params["p_classes"], classes)
        # The function must have executed (not just been built).
        self.assertIn(("execute",), self.log)

    def test_empty_classes_still_calls_rpc(self):
        covered = (date.today() + timedelta(days=14)).isoformat()
        db.replace_future_classes("studio-1", [], covered_through=covered)

        _, fn, params = self._rpc_call()
        self.assertEqual(fn, "replace_future_classes")
        # Empty list is passed through (the SQL function clears the covered range).
        self.assertEqual(params["p_classes"], [])
        self.assertEqual(params["p_covered_through"], covered)


if __name__ == "__main__":
    unittest.main()
