from __future__ import annotations

from datetime import datetime, timezone
import plistlib
import unittest
from unittest import mock

from devloop import config, schedule


class ScheduleTests(unittest.TestCase):
    def test_launchd_calendar_matches_published_schedule(self):
        plist_path = config.REPO_ROOT / "ops/launchd/com.devloop.orchestrator.plist"
        launchd = plistlib.loads(plist_path.read_bytes())
        actual = tuple(
            f"{entry['Hour']:02d}:{entry['Minute']:02d}"
            for entry in launchd["StartCalendarInterval"]
        )
        self.assertEqual(config.SCHEDULE_TIMES, actual)

    def test_upcoming_runs_are_utc_instants_from_scheduler_timezone(self):
        now = datetime(2026, 7, 15, 4, 0, tzinfo=timezone.utc)
        actual = schedule.upcoming_runs(now=now, count=3)
        self.assertEqual([
            datetime(2026, 7, 15, 4, 15, tzinfo=timezone.utc),
            datetime(2026, 7, 15, 5, 30, tzinfo=timezone.utc),
            datetime(2026, 7, 15, 9, 15, tzinfo=timezone.utc),
        ], actual)

    def test_upcoming_runs_apply_daylight_saving_offset(self):
        before_change = datetime(2026, 3, 7, 23, 0, tzinfo=timezone.utc)
        actual = schedule.upcoming_runs(now=before_change, count=4)
        self.assertEqual(
            datetime(2026, 3, 8, 9, 15, tzinfo=timezone.utc),
            actual[3],
        )

    @mock.patch("devloop.schedule.upcoming_runs")
    @mock.patch("devloop.schedule.fs.db")
    def test_update_publishes_timezone_and_concrete_next_runs(self, db, upcoming):
        next_run = datetime(2026, 7, 15, 4, 15, tzinfo=timezone.utc)
        upcoming.return_value = [next_run]
        result = schedule.update()
        payload = db.return_value.document.return_value.set.call_args.args[0]
        self.assertEqual(config.SCHEDULE_TIMEZONE, payload["timezone"])
        self.assertEqual([next_run], payload["nextRunsAt"])
        self.assertEqual([next_run.isoformat()], result["nextRunsAt"])

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
