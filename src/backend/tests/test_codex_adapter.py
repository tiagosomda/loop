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
        "repository": {"path": "/repo", "branch": "main", "usesWorktree": False},
        "assignment": {"model": "default", "effort": "high"},
    }


class CodexAdapterTests(unittest.TestCase):
    def test_command_hardcodes_full_access_and_structured_output(self):
        command = CodexAdapter().command(task(), Path("/tmp/result.json"))
        self.assertIn("--dangerously-bypass-approvals-and-sandbox", command)
        self.assertIn("--output-schema", command)
        self.assertIn('model_reasoning_effort="high"', command)
        self.assertEqual("-", command[-1])
        self.assertNotIn("--model", command)

    @mock.patch("devloop.adapters.codex.tempfile.TemporaryDirectory")
    @mock.patch("devloop.adapters.codex.subprocess.run")
    def test_success_parses_normalized_result(self, run, temporary):
        directory = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(directory))
        temporary.return_value.__enter__.return_value = directory
        Path(directory, "result.json").write_text(json.dumps({
            "outcome": "succeeded", "summary": "Done",
            "filesChanged": ["README.md"], "verification": ["tests passed"],
        }))
        run.return_value.returncode = 0
        result = CodexAdapter().run(task())
        self.assertEqual("succeeded", result.outcome)
        self.assertEqual(["README.md"], result.files_changed)
        self.assertIn('"role": "implementation-worker"', run.call_args.kwargs["input"])

    @mock.patch("devloop.adapters.codex.subprocess.run")
    def test_timeout_is_normalized(self, run):
        run.side_effect = __import__("subprocess").TimeoutExpired("codex", 1)
        result = CodexAdapter(timeout_seconds=1).run(task())
        self.assertEqual("timed-out", result.outcome)


if __name__ == "__main__":
    unittest.main()
