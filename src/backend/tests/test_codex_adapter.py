from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from devloop.adapters.codex import CodexAdapter


def task():
    return {
        "itemId": "item-1",
        "runId": "run1",
        "repository": {"path": "/repo", "branch": "main", "usesWorktree": False},
        "assignment": {"model": "default", "effort": "high"},
        "attachments": [],
    }


class CodexAdapterTests(unittest.TestCase):
    def test_command_hardcodes_full_access_and_structured_output(self):
        command = CodexAdapter().command(task(), Path("/tmp/result.json"))
        self.assertIn("--ignore-user-config", command)
        self.assertIn("--dangerously-bypass-approvals-and-sandbox", command)
        self.assertIn("--output-schema", command)
        self.assertIn('model_reasoning_effort="high"', command)
        self.assertEqual("-", command[-1])
        self.assertNotIn("--model", command)

    def test_image_attachment_is_passed_to_codex(self):
        image_task = {
            **task(),
            "attachments": [{
                "path": "/tmp/reference.jpeg",
                "contentType": "application/octet-stream",
            }],
        }
        command = CodexAdapter().command(image_task, Path("/tmp/result.json"))
        self.assertEqual(
            "/tmp/reference.jpeg",
            command[command.index("--image") + 1],
        )

    @mock.patch("devloop.adapters.codex.subprocess.run")
    def test_success_parses_normalized_result_and_keeps_provider_events(self, run):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)

        def execute(command, **_kwargs):
            output = Path(command[command.index("--output-last-message") + 1])
            output.write_text(json.dumps({
                "outcome": "succeeded", "summary": "Done",
                "filesChanged": ["README.md"], "verification": ["tests passed"],
                "providerReference": None, "metadata": {},
            }))
            return mock.Mock(
                returncode=0,
                stdout='{"type":"thread.started","thread_id":"thread-1"}\n',
                stderr="",
            )

        run.side_effect = execute
        with mock.patch("devloop.adapters.codex.config.DATA_DIR", Path(directory.name)):
            result = CodexAdapter().run(task())
            events = Path(directory.name, "agent-runs", "runs", "run1",
                          "provider-events.jsonl")
            self.assertTrue(events.is_file())
            self.assertIn("thread.started", events.read_text())
        self.assertEqual("succeeded", result.outcome)
        self.assertEqual(["README.md"], result.files_changed)
        self.assertEqual("thread-1", result.provider_reference)
        self.assertEqual(1, result.metadata["providerEventCount"])
        self.assertIn('"role": "implementation-worker"', run.call_args.kwargs["input"])
        self.assertIn("Do not access dev-loop board credentials", run.call_args.kwargs["input"])
        prompt = run.call_args.kwargs["input"]
        self.assertIn("Commit all verified repository changes", prompt)
        self.assertIn("Push the commit to the configured upstream", prompt)

    @mock.patch("devloop.adapters.codex.subprocess.run")
    def test_timeout_is_normalized(self, run):
        run.side_effect = __import__("subprocess").TimeoutExpired(
            "codex", 1, output=b'{"type":"partial"}\n'
        )
        with tempfile.TemporaryDirectory() as directory, mock.patch(
            "devloop.adapters.codex.config.DATA_DIR", Path(directory)
        ):
            result = CodexAdapter(timeout_seconds=1).run(task())
            events = Path(directory, "agent-runs", "runs", "run1",
                          "provider-events.jsonl")
            self.assertIn("partial", events.read_text())
        self.assertEqual("timed-out", result.outcome)

    def test_untrusted_run_id_is_rejected_before_subprocess(self):
        bad_task = {**task(), "runId": "../escape"}
        with mock.patch("devloop.adapters.codex.subprocess.run") as run:
            result = CodexAdapter().run(bad_task)
        self.assertEqual("failed", result.outcome)
        run.assert_not_called()

    @mock.patch("devloop.adapters.codex.subprocess.run")
    def test_jsonl_error_is_reported_when_stderr_is_empty(self, run):
        run.return_value = mock.Mock(
            returncode=1,
            stdout='{"type":"error","message":"schema rejected"}\n',
            stderr="",
        )
        with tempfile.TemporaryDirectory() as directory, mock.patch(
            "devloop.adapters.codex.config.DATA_DIR", Path(directory)
        ):
            result = CodexAdapter().run(task())
        self.assertIn("schema rejected", result.summary)


if __name__ == "__main__":
    unittest.main()
