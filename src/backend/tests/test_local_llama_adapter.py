from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from devloop.adapters import for_target
from devloop.adapters.local_llama import (
    LocalLlamaAdapter,
    _normalize_patch,
    _safe_path,
    _validate_check_command,
    _validate_patch,
)


def task(path: str = "/repo") -> dict:
    return {
        "itemId": "item-1",
        "runId": "run1",
        "title": "Small documentation task",
        "request": [{"author": "user", "text": "Inspect and report."}],
        "repository": {"path": path, "branch": "main", "status": []},
        "assignment": {"model": "gemma-3-4b-it", "effort": "low"},
    }


def action(**overrides) -> dict:
    value = {
        "action": "finish",
        "path": "",
        "lineStart": 1,
        "lineCount": 100,
        "query": "",
        "patch": "",
        "command": [],
        "outcome": "succeeded",
        "summary": "The small task is complete.",
        "verification": ["Inspected repository files"],
    }
    value.update(overrides)
    return value


class LocalLlamaAdapterTests(unittest.TestCase):
    @mock.patch("devloop.adapters.local_llama.requests.post")
    def test_chat_completion_finish_is_normalized(self, post):
        post.return_value.json.return_value = {
            "choices": [{"message": {"content": json.dumps(action())}}]
        }
        with tempfile.TemporaryDirectory() as directory:
            result = LocalLlamaAdapter("http://127.0.0.1:8080").run(task(directory))

        self.assertEqual("succeeded", result.outcome)
        self.assertEqual("local-run1", result.provider_reference)
        self.assertEqual(1, result.metadata["turnCount"])
        payload = post.call_args.kwargs["json"]
        self.assertEqual("gemma-3-4b-it", payload["model"])
        self.assertEqual("json_schema", payload["response_format"]["type"])

    def test_target_factory_builds_local_adapter(self):
        adapter = for_target({
            "adapter": "local-agent",
            "endpoint": "http://127.0.0.1:8080",
        })
        self.assertIsInstance(adapter, LocalLlamaAdapter)

    def test_endpoint_must_be_loopback(self):
        with self.assertRaisesRegex(ValueError, "127.0.0.1"):
            LocalLlamaAdapter("http://localhost:8080")

    def test_path_escape_and_general_shell_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            with self.assertRaisesRegex(ValueError, "escapes"):
                _safe_path(repo, "../secret")
        with self.assertRaisesRegex(ValueError, "not allowed"):
            _validate_check_command(["sh", "-c", "rm -rf ."])
        with self.assertRaisesRegex(ValueError, "git status"):
            _validate_check_command(["git", "push"])

    def test_validated_patch_is_applied_inside_repository(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            source = repo / "README.md"
            source.write_text("before\n")
            patch = (
                "diff --git a/README.md b/README.md\n"
                "--- a/README.md\n"
                "+++ b/README.md\n"
                "@@ -1 +1 @@\n"
                "-before\n"
                "+after\n"
            )
            paths: set[str] = set()
            result = LocalLlamaAdapter("http://127.0.0.1:8080")._execute(
                "patch", action(action="patch", patch=patch), repo, paths
            )
            self.assertEqual("after\n", source.read_text())
            self.assertEqual({"README.md"}, paths)
            self.assertIn("README.md", result)

    def test_patch_cannot_modify_git_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            patch = "--- /dev/null\n+++ b/.git/config\n@@ -0,0 +1 @@\n+x\n"
            with self.assertRaisesRegex(ValueError, "cannot modify .git"):
                _validate_patch(repo, patch)

    def test_gemma_single_line_shorthand_becomes_a_valid_patch(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            (repo / "README.md").write_text("# Before\nBody\n")
            normalized = _normalize_patch(
                repo, "a/README.md:1:# Before\nb/README.md:1:# After"
            )
            self.assertIn("--- a/README.md", normalized)
            self.assertIn("-# Before", normalized)
            self.assertIn("+# After", normalized)

    def test_gemma_unified_diff_repairs_a_preserved_prefix(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            (repo / "README.md").write_text("# dev-loop\n")
            normalized = _normalize_patch(
                repo,
                "--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n"
                "-dev-loop\n+dev-loop local",
            )
            self.assertIn("-# dev-loop", normalized)
            self.assertIn("+# dev-loop local", normalized)

    def test_gemma_bare_replacement_uses_structured_action_context(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            (repo / "README.md").write_text("# dev-loop\n")
            normalized = _normalize_patch(repo, "## dev-loop local\n", {
                "path": "README.md", "lineStart": 1, "query": "# dev-loop",
            })
            self.assertIn("-# dev-loop", normalized)
            self.assertIn("+# dev-loop local", normalized)


if __name__ == "__main__":
    unittest.main()
