from __future__ import annotations

import unittest
from unittest import mock

from devloop import schedule


class ScheduleTests(unittest.TestCase):
    @mock.patch("devloop.targets.safe_projection")
    @mock.patch("devloop.schedule.fs.db")
    def test_finish_publishes_health_and_provider_state(self, db, projection):
        projection.return_value = {
            "targets": [
                {
                    "targetId": "router",
                    "role": "router",
                    "adapter": "llama-cpp",
                    "enabled": True,
                    "availability": {"available": True, "reason": "healthy"},
                },
                {
                    "targetId": "codex",
                    "role": "worker",
                    "adapter": "codex",
                    "enabled": True,
                    "availability": {"available": True, "reason": "authenticated"},
                },
            ]
        }
        schedule.finish("finished", "one item")
        payload = db.return_value.document.return_value.set.call_args.args[0]
        self.assertEqual("finished", payload["lastOutcome"])
        self.assertTrue(payload["routerHealth"]["available"])
        self.assertEqual("codex", payload["providers"][0]["adapter"])
        self.assertTrue(db.return_value.document.return_value.set.call_args.kwargs["merge"])


if __name__ == "__main__":
    unittest.main()
