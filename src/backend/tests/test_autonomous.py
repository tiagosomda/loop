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
            next_item=lambda: None,
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
            next_item=lambda: queue.pop(0),
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

    def test_failure_still_ends_run(self):
        events = []
        finished = []
        with self.assertRaisesRegex(RuntimeError, "router down"):
            autonomous.execute(
                start_run=lambda: events.append("start"),
                next_item=lambda: {"id": "item-1", "status": "open"},
                end_run=lambda **kwargs: (
                    events.append("end"), finished.append(kwargs)
                ),
                build_context=lambda _: {},
                choose=lambda _: (_ for _ in ()).throw(RuntimeError("router down")),
                lock=no_lock,
            )
        self.assertEqual(["start", "end"], events)
        self.assertEqual("failed", finished[0]["outcome"])
        self.assertIn("router down", finished[0]["note"])

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
            next_item=lambda: queue.pop(0),
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

    def test_router_abstention_pauses_item_and_queue_continues(self):
        queue = [
            {"id": "uncertain", "status": "open"},
            {"id": "clear", "status": "open"},
            None,
        ]
        paused = []

        def choose(context):
            if context["itemId"] == "uncertain":
                raise router.RoutingError(
                    "needs-human-routing: router confidence is too low"
                )
            return {"targetId": "codex-standard"}

        result = autonomous.execute(
            start_run=lambda: None,
            next_item=lambda: queue.pop(0),
            end_run=lambda **_kwargs: None,
            build_context=lambda item_id: {"itemId": item_id},
            choose=choose,
            pause_routing=lambda item, reason: paused.append(
                (item["id"], reason)
            ) or {"itemId": item["id"], "outcome": "needs-human-routing"},
            load_catalog=lambda: {
                "targets": [{"targetId": "codex-standard", "enabled": True}]
            },
            adapter_factory=lambda _: object(),
            dispatch=lambda *a, **k: (
                "run-clear", WorkerResult(outcome="succeeded", summary="done")
            ),
            lock=no_lock,
        )
        self.assertEqual("uncertain", paused[0][0])
        self.assertIn("confidence", paused[0][1])
        self.assertEqual(2, result["count"])
        self.assertEqual("clear", result["processed"][1]["itemId"])

    def test_overlapping_lock_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run.lock"
            with autonomous.single_instance(path):
                with self.assertRaises(autonomous.AlreadyRunning):
                    with autonomous.single_instance(path):
                        pass


if __name__ == "__main__":
    unittest.main()
