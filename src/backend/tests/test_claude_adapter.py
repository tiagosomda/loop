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
        prompt = run.call_args.kwargs["input"]
        self.assertIn("Do not access dev-loop credentials", prompt)
        self.assertIn("Return `succeeded` when the requested work is complete", prompt)
        self.assertIn("Do not use it merely to invite optional review", prompt)

    @mock.patch("devloop.adapters.claude.subprocess.run")
    def test_fenced_result_envelope_is_normalized(self, run):
        # The real `claude --print --output-format json` envelope: the worker
        # result is fenced JSON inside `result`, with no `structured_output`.
        run.return_value = mock.Mock(
            returncode=0, stderr="",
            stdout=json.dumps({
                "type": "result", "subtype": "success", "is_error": False,
                "session_id": "sess-9",
                "result": "```json\n" + json.dumps({
                    "outcome": "succeeded", "summary": "Renamed the game",
                    "filesChanged": ["pubspec.yaml"],
                    "verification": ["flutter test"],
                    "providerReference": None, "metadata": {},
                }) + "\n```",
            }),
        )
        result = ClaudeAdapter().run(task())
        self.assertEqual("succeeded", result.outcome)
        self.assertEqual("Renamed the game", result.summary)
        self.assertEqual(["pubspec.yaml"], result.files_changed)
        # The envelope session id becomes the provider reference by default.
        self.assertEqual("sess-9", result.provider_reference)

    @mock.patch("devloop.adapters.claude.subprocess.run")
    def test_error_envelope_is_failure(self, run):
        run.return_value = mock.Mock(
            returncode=0, stderr="",
            stdout=json.dumps({"type": "result", "subtype": "error_max_turns",
                               "is_error": True, "result": ""}),
        )
        result = ClaudeAdapter().run(task())
        self.assertEqual("failed", result.outcome)
        self.assertIn("error_max_turns", result.summary)

    @mock.patch("devloop.adapters.claude.subprocess.run")
    def test_unstructured_result_is_failure(self, run):
        run.return_value = mock.Mock(
            returncode=0, stderr="",
            stdout=json.dumps({"type": "result", "subtype": "success",
                               "is_error": False,
                               "result": "I could not complete the task."}),
        )
        result = ClaudeAdapter().run(task())
        self.assertEqual("failed", result.outcome)
        self.assertIn("did not return a structured worker result", result.summary)

    @mock.patch("devloop.adapters.claude.subprocess.run")
    def test_timeout_is_normalized(self, run):
        run.side_effect = subprocess.TimeoutExpired("claude", 1)
        result = ClaudeAdapter(timeout_seconds=1).run(task())
        self.assertEqual("timed-out", result.outcome)


if __name__ == "__main__":
    unittest.main()
