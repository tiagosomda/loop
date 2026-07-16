from __future__ import annotations

import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest import mock

from devloop import self_healing


@contextmanager
def no_lock():
    yield


class SelfHealingTests(unittest.TestCase):
    def test_collect_evidence_keeps_failures_and_tracebacks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run_log = root / "runs.log"
            error_log = root / "errors.log"
            run_log.write_text(
                "run finished: no items touched\n"
                "run finished: failed: DispatchError: boom\n"
            )
            error_log.write_text(
                "warning\nTraceback (most recent call last):\n  File x\nValueError: boom\n"
            )
            with mock.patch.object(self_healing.runlog, "LOG_FILE", run_log), \
                    mock.patch.object(self_healing, "ERROR_LOG", error_log):
                evidence, state = self_healing.collect_evidence({})
            run_size = run_log.stat().st_size
        self.assertIn("DispatchError: boom", evidence)
        self.assertIn("ValueError: boom", evidence)
        self.assertEqual(run_size, state["runLogOffset"])

    @mock.patch("devloop.self_healing.schedule.mark_self_healing")
    @mock.patch("devloop.self_healing.runlog.log")
    @mock.patch("devloop.self_healing.single_instance", return_value=no_lock())
    def test_no_errors_does_not_create_board_item(self, _lock, _log, mark):
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(self_healing, "STATE_FILE", Path(directory) / "state.json"), \
                mock.patch("devloop.self_healing.collect_evidence", return_value=("", {})), \
                mock.patch("devloop.self_healing.items.create_item") as create:
            result = self_healing.execute()
        self.assertFalse(result["created"])
        create.assert_not_called()
        self.assertEqual("finished", mark.call_args_list[-1].args[0])

    @mock.patch("devloop.self_healing.schedule.mark_self_healing")
    @mock.patch("devloop.self_healing.runlog.log")
    @mock.patch("devloop.self_healing.single_instance", return_value=no_lock())
    def test_failed_repair_is_written_back_and_left_for_review(
        self, _lock, _log, _mark
    ):
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(self_healing, "STATE_FILE", Path(directory) / "state.json"), \
                mock.patch("devloop.self_healing.collect_evidence", return_value=("boom", {})), \
                mock.patch("devloop.self_healing.items.create_item", return_value="item-1"), \
                mock.patch("devloop.self_healing.items.post_message") as post, \
                mock.patch("devloop.self_healing.items.set_status") as status, \
                mock.patch("devloop.self_healing._decision", side_effect=RuntimeError("unclear")):
            result = self_healing.execute()
        self.assertTrue(result["created"])
        post.assert_called_once()
        status.assert_called_once_with("item-1", "needs-review")


if __name__ == "__main__":
    unittest.main()
