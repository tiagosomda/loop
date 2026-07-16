from __future__ import annotations

import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path

from devloop import autonomous, router
from devloop.adapters.base import WorkerResult


@contextmanager
def no_lock():
    yield


class AutonomousTests(unittest.TestCase):
    def test_idle_run_starts_and_ends(self):
        events = []
        result = autonomous.execute(
            start_run=lambda: events.append("start"),
            next_item=lambda _blocked: None,
            end_run=lambda **_kwargs: events.append("end"),
            lock=no_lock,
        )
        self.assertEqual(["start", "end"], events)
        self.assertEqual(0, result["count"])

    def test_one_item_routes_dispatches_and_finalizes_run(self):
        queue = [{"id": "item-1", "status": "open"}, None]
        events = []
        result = autonomous.execute(
            start_run=lambda: events.append("start"),
            next_item=lambda _blocked: queue.pop(0),
            end_run=lambda **_kwargs: events.append("end"),
            build_context=lambda _: {"context": True},
            choose=lambda _: {"targetId": "codex-standard"},
            load_catalog=lambda: {
                "targets": [{"targetId": "codex-standard", "enabled": True}]
            },
            adapter_factory=lambda _: object(),
            dispatch=lambda *a, **k: (
                "run-1", WorkerResult(outcome="succeeded", summary="done")
            ),
            lock=no_lock,
        )
        self.assertEqual(1, result["count"])
        self.assertEqual(["start", "end"], events)

    def test_failure_blocks_only_its_repo_and_run_continues(self):
        events = []
        finished = []
        items = [
            {"id": "item-1", "status": "open", "repoId": "repo-a"},
            {"id": "item-2", "status": "open", "repoId": "repo-a"},
            {"id": "item-3", "status": "open", "repoId": "repo-b"},
        ]

        def next_item(blocked):
            return next((item for item in items if item["repoId"] not in blocked), None)

        def context(item_id):
            items[:] = [item for item in items if item["id"] != item_id]
            if item_id == "item-1":
                raise RuntimeError("router down")
            return {}

        result = autonomous.execute(
            start_run=lambda: events.append("start"),
            next_item=next_item,
            end_run=lambda **kwargs: (
                events.append("end"), finished.append(kwargs)
            ),
            build_context=context,
            choose=lambda _: {"targetId": "codex-standard"},
            load_catalog=lambda: {
                "targets": [{"targetId": "codex-standard", "enabled": True}]
            },
            adapter_factory=lambda _: object(),
            dispatch=lambda *a, **k: (
                "run-3", WorkerResult(outcome="succeeded", summary="done")
            ),
            lock=no_lock,
        )
        self.assertEqual(["start", "end"], events)
        self.assertIn("repository work skipped", finished[0]["note"])
        self.assertIn("repo-a", result["blockedRepositories"])
        self.assertEqual(["item-1", "item-3"], [p["itemId"] for p in result["processed"]])

    def test_bootstrap_failure_still_ends_run(self):
        events = []

        def fail_start():
            events.append("start")
            raise RuntimeError("firebase unavailable")

        with self.assertRaisesRegex(RuntimeError, "firebase unavailable"):
            autonomous.execute(
                start_run=fail_start,
                end_run=lambda **_kwargs: events.append("end"),
                lock=no_lock,
            )
        self.assertEqual(["start", "end"], events)

    def test_stale_item_is_paused_and_queue_continues(self):
        queue = [
            {"id": "stale", "status": "in-progress"},
            {"id": "open", "status": "open"},
            None,
        ]
        recovered = []
        result = autonomous.execute(
            start_run=lambda: None,
            next_item=lambda _blocked: queue.pop(0),
            end_run=lambda **_kwargs: None,
            recover=lambda item: recovered.append(item["id"]) or {
                "itemId": item["id"], "outcome": "needs-human-recovery"
            },
            build_context=lambda _: {},
            choose=lambda _: {"targetId": "codex-standard"},
            load_catalog=lambda: {
                "targets": [{"targetId": "codex-standard", "enabled": True}]
            },
            adapter_factory=lambda _: object(),
            dispatch=lambda *a, **k: (
                "run-open", WorkerResult(outcome="succeeded", summary="done")
            ),
            lock=no_lock,
        )
        self.assertEqual(["stale"], recovered)
        self.assertEqual(2, result["count"])
        self.assertEqual("open", result["processed"][1]["itemId"])

    def test_router_abstention_uses_configured_fallback_and_queue_continues(self):
        queue = [
            {"id": "uncertain", "status": "open"},
            {"id": "clear", "status": "open"},
            None,
        ]
        dispatched = []

        def choose(context):
            if context["item"]["id"] == "uncertain":
                raise router.RoutingError(
                    "needs-human-routing: router confidence is too low"
                )
            return {"targetId": "codex-standard"}

        result = autonomous.execute(
            start_run=lambda: None,
            next_item=lambda _blocked: queue.pop(0),
            end_run=lambda **_kwargs: None,
            build_context=lambda item_id: {
                "item": {"id": item_id},
                "requested": {"provider": None, "model": None, "effort": None},
                "allowedTargets": [{
                    "targetId": "codex-standard",
                    "adapter": "codex",
                    "models": ["gpt-5.6-sol"],
                    "effortLevels": ["high"],
                }],
            },
            choose=choose,
            load_catalog=lambda: {
                "fallbackAssignment": {
                    "targetId": "codex-standard", "provider": "codex",
                    "model": "gpt-5.6-sol", "effort": "high",
                },
                "targets": [{"targetId": "codex-standard", "enabled": True}],
            },
            adapter_factory=lambda _: object(),
            dispatch=lambda _item_id, decision, *_args, **_kwargs: (
                dispatched.append(decision) or "run",
                WorkerResult(outcome="succeeded", summary="done"),
            ),
            lock=no_lock,
        )
        self.assertEqual(2, result["count"])
        self.assertEqual("gpt-5.6-sol", dispatched[0]["model"])
        self.assertEqual("high", dispatched[0]["effort"])
        self.assertEqual("clear", result["processed"][1]["itemId"])

    def test_router_abstention_pauses_when_fallback_is_not_allowed(self):
        paused = []
        result = autonomous.execute(
            start_run=lambda: None,
            next_item=lambda _blocked, iterator=iter([
                {"id": "item-1", "status": "open"}, None
            ]): next(iterator),
            end_run=lambda **_kwargs: None,
            build_context=lambda item_id: {
                "item": {"id": item_id}, "allowedTargets": [],
            },
            choose=lambda _: (_ for _ in ()).throw(router.RoutingError(
                "needs-human-routing: no enabled available worker target"
            )),
            pause_routing=lambda item, reason: paused.append(reason) or {
                "itemId": item["id"], "outcome": "needs-human-routing",
            },
            load_catalog=lambda: {
                "fallbackAssignment": {
                    "targetId": "codex-standard", "provider": "codex",
                    "model": "gpt-5.6-sol", "effort": "high",
                },
                "targets": [],
            },
            lock=no_lock,
        )
        self.assertEqual(1, result["count"])
        self.assertIn("no enabled", paused[0])

    def test_overlapping_lock_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run.lock"
            with autonomous.single_instance(path):
                with self.assertRaises(autonomous.AlreadyRunning):
                    with autonomous.single_instance(path):
                        pass


if __name__ == "__main__":
    unittest.main()
