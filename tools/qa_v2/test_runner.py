#!/usr/bin/env python3
"""Verify fail-closed result collection independently of the app tests."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

import run as runner


class ResultCollectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def xml(self, *, assertions=1, failures=0, name="a", skipped=False,
            summary_passed=1, summary_failed=0):
        path = self.root / "report.xml"
        path.write_text(f'''<doctest><TestSuite>
          <TestCase name="{name}" skipped="{str(skipped).lower()}">
          <OverallResultsAsserts successes="{assertions}" failures="{failures}"
            test_case_success="{str(failures == 0).lower()}"/></TestCase></TestSuite>
          <OverallResultsTestCases successes="{summary_passed}" failures="{summary_failed}" skipped="0"/>
          </doctest>''')
        return runner.validate_core_report(path, {"a"})

    def test_real_assertion_pass_is_collected(self):
        self.assertEqual(self.xml()["status"], "PASS")

    def test_application_failure_is_not_collection_failure(self):
        result = self.xml(assertions=1, failures=1, summary_passed=0, summary_failed=1)
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["cases"][0]["status"], "FAIL")

    def test_zero_assertions_is_error(self):
        self.assertEqual(self.xml(assertions=0)["status"], "ERROR")

    def test_skipped_required_case_is_error(self):
        self.assertEqual(self.xml(skipped=True)["status"], "ERROR")

    def test_wrong_name_cannot_replace_required_case(self):
        self.assertEqual(self.xml(name="unrelated")["status"], "ERROR")

    def test_inconsistent_summary_is_error(self):
        self.assertEqual(self.xml(summary_passed=0)["status"], "ERROR")

    def test_missing_report_is_error(self):
        self.assertEqual(runner.validate_core_report(self.root / "missing", {"a"})["status"], "ERROR")

    def rows(self, rows):
        path = self.root / "report.json"
        path.write_text(json.dumps({"results": rows}))
        return runner.read_cases(path, {"a", "b"}, "example")[0]["status"]

    def test_duplicate_case_cannot_inflate_count(self):
        self.assertEqual(self.rows([{"id": "a", "status": "PASS"}] * 2), "ERROR")

    def test_not_run_cannot_become_a_pass(self):
        self.assertEqual(self.rows([{"id": "a", "status": "PASS"}, {"id": "b", "status": "NOT_RUN"}]), "ERROR")

    def test_missing_case_is_error(self):
        self.assertEqual(self.rows([]), "ERROR")

    def test_blocked_is_retained_not_replaced_with_pass(self):
        path = self.root / "blocked.json"
        path.write_text(json.dumps({"results": [{"id": "a", "status": "BLOCKED"}]}))
        metadata, rows = runner.read_cases(path, {"a"}, "example")
        self.assertEqual(metadata["status"], "PASS")
        self.assertEqual(rows[0]["status"], "BLOCKED")

    def test_nonzero_process_is_failure(self):
        result = runner.execute("nonzero", [sys.executable, "-c", "raise SystemExit(3)"], self.root, 5)
        self.assertEqual(result["status"], "FAIL")

    def test_missing_executable_is_blocked(self):
        result = runner.execute("missing", [str(self.root / "missing-tool")], self.root, 5)
        self.assertEqual(result["status"], "BLOCKED")

    def test_hung_process_is_timeout(self):
        result = runner.execute("hang", [sys.executable, "-c", "import time; time.sleep(60)"], self.root, 1)
        self.assertEqual(result["status"], "TIMEOUT")


if __name__ == "__main__":
    unittest.main(verbosity=2)
