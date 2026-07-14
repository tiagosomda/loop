from __future__ import annotations

import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest import mock

from devloop import autonomous
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
            end_run=lambda: events.append("end"),
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
            end_run=lambda: events.append("end"),
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
        with self.assertRaisesRegex(RuntimeError, "router down"):
            autonomous.execute(
                start_run=lambda: events.append("start"),
                next_item=lambda: {"id": "item-1", "status": "open"},
                end_run=lambda: events.append("end"),
                build_context=lambda _: {},
                choose=lambda _: (_ for _ in ()).throw(RuntimeError("router down")),
                lock=no_lock,
            )
        self.assertEqual(["start", "end"], events)

    def test_overlapping_lock_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run.lock"
            with autonomous.single_instance(path):
                with self.assertRaises(autonomous.AlreadyRunning):
                    with autonomous.single_instance(path):
                        pass


if __name__ == "__main__":
    unittest.main()
