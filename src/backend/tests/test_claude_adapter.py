from __future__ import annotations

import json
import subprocess
import unittest
from unittest import mock

from devloop.adapters.claude import ClaudeAdapter


def task():
    return {
        "itemId": "item-1",
        "runId": "run1",
        "repository": {"path": "/repo", "branch": "main"},
        "assignment": {"model": "sonnet", "effort": "high"},
    }


class ClaudeAdapterContractTests(unittest.TestCase):
    def test_command_is_full_access_and_schema_constrained(self):
        command = ClaudeAdapter().command(task())
        self.assertIn("--dangerously-skip-permissions", command)
        self.assertIn("--json-schema", command)
        self.assertEqual("sonnet", command[command.index("--model") + 1])
        self.assertEqual("high", command[command.index("--effort") + 1])

    @mock.patch("devloop.adapters.claude.subprocess.run")
    def test_structured_envelope_is_normalized(self, run):
        run.return_value = mock.Mock(
            returncode=0,
            stderr="",
            stdout=json.dumps({"structured_output": {
                "outcome": "succeeded",
                "summary": "Done",
                "filesChanged": ["README.md"],
                "verification": ["tests passed"],
                "providerReference": "session-1",
                "metadata": {},
            }}),
        )
        result = ClaudeAdapter().run(task())
        self.assertEqual("succeeded", result.outcome)
        self.assertEqual("session-1", result.provider_reference)
        self.assertIn("Do not access dev-loop credentials", run.call_args.kwargs["input"])

    @mock.patch("devloop.adapters.claude.subprocess.run")
    def test_timeout_is_normalized(self, run):
        run.side_effect = subprocess.TimeoutExpired("claude", 1)
        result = ClaudeAdapter(timeout_seconds=1).run(task())
        self.assertEqual("timed-out", result.outcome)


if __name__ == "__main__":
    unittest.main()
