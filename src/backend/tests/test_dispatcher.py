from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from devloop import dispatcher
from devloop.adapters.base import WorkerResult
from devloop.adapters.fake import FakeAdapter


class DispatcherTests(unittest.TestCase):
    def setUp(self):
        self.item = {
            "id": "item-1", "title": "Task", "status": "open", "repoId": "repo",
            "messages": [{"author": "user", "text": "Do it"}],
            "requestedProvider": None, "requestedModel": None, "requestedEffort": None,
        }
        self.decision = {
            "schemaVersion": 1, "itemId": "item-1", "targetId": "codex-standard",
            "provider": "codex", "model": "default", "effort": "low",
            "reasonCodes": ["small-change"], "confidence": "high",
        }

    def test_lifecycle_order_and_normalized_result(self):
        events = []
        adapter = FakeAdapter()
        run_id, result = dispatcher.start(
            "item-1", self.decision, adapter,
            load_item=lambda _: self.item,
            load_repo=lambda _: {"path": "ignored"},
            preflight=lambda _: {"path": "/repo", "branch": "main", "usesWorktree": False},
            create_run=lambda *a, **k: events.append("record-and-claim") or "run-1",
            post_event=lambda *a, **k: events.append("event") or "event-1",
            finalize=lambda *a: events.append("finalize"),
        )
        self.assertEqual(["record-and-claim", "event", "finalize"], events)
        self.assertEqual("run-1", run_id)
        self.assertEqual("succeeded", result.outcome)
        self.assertFalse(adapter.tasks[0]["repository"]["usesWorktree"])

    def test_ineligible_item_stops_before_assignment(self):
        create_run = mock.Mock()
        item = {**self.item, "status": "in-progress"}
        with self.assertRaisesRegex(dispatcher.DispatchError, "no longer eligible"):
            dispatcher.start("item-1", self.decision, FakeAdapter(),
                             load_item=lambda _: item, create_run=create_run)
        create_run.assert_not_called()

    @mock.patch("devloop.dispatcher.subprocess.run")
    def test_dirty_checkout_is_rejected(self, run):
        run.side_effect = [
            mock.Mock(returncode=0, stdout="main\n", stderr=""),
            mock.Mock(returncode=0, stdout="abc123\n", stderr=""),
            mock.Mock(returncode=0, stdout=" M user-file\n", stderr=""),
        ]
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(dispatcher.DispatchError, "uncommitted changes"):
                dispatcher.checkout_preflight(Path(directory))

    @mock.patch("devloop.dispatcher.subprocess.run")
    def test_non_main_checkout_is_rejected(self, run):
        run.return_value = mock.Mock(returncode=0, stdout="feature\n", stderr="")
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(dispatcher.DispatchError, "not main"):
                dispatcher.checkout_preflight(Path(directory))

    def test_worker_exception_becomes_normalized_failure(self):
        adapter = mock.Mock()
        adapter.run.side_effect = RuntimeError("boom")
        finalized = []
        _, result = dispatcher.start(
            "item-1", self.decision, adapter,
            load_item=lambda _: self.item,
            load_repo=lambda _: {"path": "ignored"},
            preflight=lambda _: {"path": "/repo", "branch": "main", "usesWorktree": False},
            create_run=lambda *a, **k: "run-1",
            post_event=lambda *a, **k: "event", finalize=lambda *a: finalized.append(a),
        )
        self.assertEqual("failed", result.outcome)
        self.assertIn("boom", result.summary)
        self.assertEqual(1, len(finalized))

    @mock.patch("devloop.dispatcher.items.post_message")
    @mock.patch("devloop.dispatcher.items._items")
    @mock.patch("devloop.dispatcher.items.fs.db")
    @mock.patch("devloop.dispatcher.items.runlog.log")
    def test_finalization_is_durable_before_message_writeback(
        self, _log, db, item_collection, post_message
    ):
        batch = db.return_value.batch.return_value

        def verify_committed(*_args, **_kwargs):
            self.assertTrue(batch.commit.called)

        post_message.side_effect = verify_committed
        dispatcher._finalize(
            "item-1",
            "run-1",
            WorkerResult(
                outcome="succeeded",
                summary="done",
                files_changed=["README.md"],
                verification=["tests passed"],
            ),
        )
        self.assertEqual(2, batch.update.call_count)
        post_message.assert_called_once()
        item_collection.return_value.document.assert_called_with("item-1")


if __name__ == "__main__":
    unittest.main()
