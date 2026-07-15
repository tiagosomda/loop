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
            "provider": "codex", "model": "gpt-5.6-terra", "effort": "low",
            "reasonCodes": ["small-change"], "confidence": "high",
        }
        self.clean_postflight = lambda _: {
            "endingBranch": "main",
            "endingRevision": "abc123",
            "newCommitCount": 0,
            "dirty": False,
            "upstream": "origin/main",
            "unpushedCommitCount": 0,
        }

    def test_lifecycle_order_and_normalized_result(self):
        events = []
        adapter = FakeAdapter()
        run_id, result = dispatcher.start(
            "item-1", self.decision, adapter,
            load_item=lambda _: self.item,
            load_repo=lambda _: {"path": "ignored"},
            preflight=lambda _: {"path": "/repo", "branch": "main", "usesWorktree": False},
            postflight=self.clean_postflight,
            create_run=lambda *a, **k: events.append("record-and-claim") or "run-1",
            post_event=lambda *a, **k: events.append("event") or "event-1",
            finalize=lambda *a: events.append("finalize"),
        )
        self.assertEqual(["record-and-claim", "event", "finalize"], events)
        self.assertEqual("run-1", run_id)
        self.assertEqual("succeeded", result.outcome)
        self.assertFalse(adapter.tasks[0]["repository"]["usesWorktree"])

    def test_attachments_are_materialized_before_worker_invocation(self):
        item = {
            **self.item,
            "messages": [{
                "author": "user",
                "text": "Match this screenshot",
                "attachments": [{
                    "name": "reference.jpeg",
                    "contentType": "application/octet-stream",
                    "size": 10,
                }],
            }],
        }
        adapter = FakeAdapter()
        materialized = [{
            "name": "reference.jpeg",
            "contentType": "application/octet-stream",
            "size": 10,
            "path": "/trusted/reference.jpeg",
        }]
        dispatcher.start(
            "item-1", self.decision, adapter,
            load_item=lambda _: item,
            load_repo=lambda _: {"path": "ignored"},
            preflight=lambda _: {
                "path": "/repo", "branch": "main", "usesWorktree": False
            },
            postflight=self.clean_postflight,
            materialize_attachments=lambda item_id, loaded: materialized,
            create_run=lambda *a, **k: "run-1",
            post_event=lambda *a, **k: "event",
            finalize=lambda *a: None,
        )
        self.assertEqual(materialized, adapter.tasks[0]["attachments"])

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
        run.side_effect = [
            mock.Mock(returncode=0, stdout="feature\n", stderr=""),
            mock.Mock(returncode=0, stdout="origin/main\n", stderr=""),
        ]
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(dispatcher.DispatchError, "default branch"):
                dispatcher.checkout_preflight(Path(directory))

    @mock.patch("devloop.dispatcher.subprocess.run")
    def test_remote_default_master_checkout_is_allowed(self, run):
        run.side_effect = [
            mock.Mock(returncode=0, stdout="master\n", stderr=""),
            mock.Mock(returncode=0, stdout="origin/master\n", stderr=""),
            mock.Mock(returncode=0, stdout="abc123\n", stderr=""),
            mock.Mock(returncode=0, stdout="", stderr=""),
        ]
        with tempfile.TemporaryDirectory() as directory:
            checkout = dispatcher.checkout_preflight(Path(directory))
        self.assertEqual("master", checkout["branch"])
        self.assertEqual("existing-checkout-default-branch", checkout["gitPolicy"])

    @mock.patch("devloop.dispatcher.subprocess.run")
    def test_postflight_records_commit_and_push_evidence(self, run):
        run.side_effect = [
            mock.Mock(returncode=0, stdout="main\n", stderr=""),
            mock.Mock(returncode=0, stdout="def456\n", stderr=""),
            mock.Mock(returncode=0, stdout="", stderr=""),
            mock.Mock(returncode=0, stdout="1\n", stderr=""),
            mock.Mock(returncode=0, stdout="origin/main\n", stderr=""),
            mock.Mock(returncode=0, stdout="0\n", stderr=""),
        ]
        evidence = dispatcher.checkout_postflight({
            "path": "/repo", "startingRevision": "abc123",
        })
        self.assertEqual(1, evidence["newCommitCount"])
        self.assertEqual("main", evidence["endingBranch"])
        self.assertEqual("origin/main", evidence["upstream"])
        self.assertEqual(0, evidence["unpushedCommitCount"])

    def test_incomplete_git_delivery_cannot_finalize_as_success(self):
        finalized = []
        adapter = FakeAdapter(WorkerResult(
            outcome="succeeded",
            summary="Implemented the change.",
            files_changed=["README.md"],
        ))
        _, result = dispatcher.start(
            "item-1", self.decision, adapter,
            load_item=lambda _: self.item,
            load_repo=lambda _: {"path": "ignored"},
            preflight=lambda _: {
                "path": "/repo", "branch": "main", "usesWorktree": False,
                "startingRevision": "abc123",
            },
            postflight=lambda _: {
                "endingBranch": "main", "endingRevision": "abc123",
                "newCommitCount": 0,
                "dirty": True, "upstream": "origin/main",
                "unpushedCommitCount": 0,
            },
            create_run=lambda *a, **k: "run-1",
            post_event=lambda *a, **k: "event",
            finalize=lambda *args: finalized.append(args),
        )
        self.assertEqual("needs-review", result.outcome)
        self.assertIn("uncommitted changes", result.summary)
        self.assertIn("no new commit", result.summary)
        self.assertTrue(result.metadata["gitPostflight"]["dirty"])
        self.assertEqual(1, len(finalized))

    def test_worker_exception_becomes_normalized_failure(self):
        adapter = mock.Mock()
        adapter.run.side_effect = RuntimeError("boom")
        finalized = []
        _, result = dispatcher.start(
            "item-1", self.decision, adapter,
            load_item=lambda _: self.item,
            load_repo=lambda _: {"path": "ignored"},
            preflight=lambda _: {"path": "/repo", "branch": "main", "usesWorktree": False},
            postflight=self.clean_postflight,
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
        self.assertEqual("completed", batch.update.call_args_list[1].args[1]["status"])
        post_message.assert_called_once()
        item_collection.return_value.document.assert_called_with("item-1")

    @mock.patch("devloop.dispatcher.items.post_message")
    @mock.patch("devloop.dispatcher.items._items")
    @mock.patch("devloop.dispatcher.items.fs.db")
    @mock.patch("devloop.dispatcher.items.runlog.log")
    def test_explicit_review_outcome_remains_needs_review(
        self, _log, db, _item_collection, _post_message
    ):
        dispatcher._finalize(
            "item-1", "run-1",
            WorkerResult(outcome="needs-review", summary="review this"),
        )
        batch = db.return_value.batch.return_value
        self.assertEqual(
            "needs-review", batch.update.call_args_list[1].args[1]["status"]
        )


if __name__ == "__main__":
    unittest.main()
