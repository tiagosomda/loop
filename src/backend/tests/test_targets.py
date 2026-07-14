from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from devloop import targets


class TargetCatalogTests(unittest.TestCase):
    def _catalog_file(self, catalog: dict) -> Path:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "targets.json"
        path.write_text(json.dumps(catalog))
        return path

    def test_repository_catalog_is_valid(self):
        catalog = targets.load()
        self.assertEqual(1, catalog["schemaVersion"])

    def test_duplicate_target_is_rejected(self):
        catalog = targets.load()
        catalog["targets"].append(dict(catalog["targets"][0]))
        with self.assertRaisesRegex(targets.CatalogError, "duplicate targetId"):
            targets.load(self._catalog_file(catalog))

    def test_invalid_effort_is_rejected(self):
        catalog = targets.load()
        catalog["targets"][0]["effortLevels"] = ["enormous"]
        with self.assertRaisesRegex(targets.CatalogError, "invalid effortLevels"):
            targets.load(self._catalog_file(catalog))

    @mock.patch("devloop.targets.subprocess.run")
    @mock.patch("devloop.targets.shutil.which", return_value="/usr/bin/codex")
    def test_enabled_worker_projection_excludes_disabled_claude(self, _which, run):
        run.return_value.returncode = 0
        projection = targets.safe_projection(role="worker", enabled_only=True)
        self.assertEqual(["codex-standard"],
                         [target["targetId"] for target in projection["targets"]])
        self.assertNotIn("executable", projection["targets"][0])
        self.assertNotIn("endpoint", projection["targets"][0])

    @mock.patch("devloop.targets.subprocess.run")
    @mock.patch("devloop.targets.shutil.which", return_value="/usr/bin/claude")
    def test_enabling_claude_in_data_makes_it_visible(self, _which, run):
        run.return_value.returncode = 0
        catalog = targets.load()
        claude = next(target for target in catalog["targets"]
                      if target["targetId"] == "claude-standard")
        claude["enabled"] = True
        projection = targets.safe_projection(
            role="worker", enabled_only=True, path=self._catalog_file(catalog))
        self.assertEqual(
            ["codex-standard", "claude-standard"],
            [target["targetId"] for target in projection["targets"]],
        )

    @mock.patch("devloop.targets.requests.get")
    def test_router_health_probe(self, get):
        get.return_value.json.return_value = {"status": "ok"}
        router = targets.load()["targets"][0]
        self.assertEqual({"available": True, "reason": "healthy"},
                         targets.probe(router))
        get.assert_called_once_with("http://127.0.0.1:8080/health", timeout=1.0)

    def test_disabled_target_is_not_probed(self):
        claude = targets.load()["targets"][2]
        self.assertEqual(
            {"available": False, "reason": "disabled-by-configuration"},
            targets.probe(claude),
        )

    @mock.patch("devloop.targets.subprocess.run")
    @mock.patch("devloop.targets.shutil.which", return_value="/usr/bin/provider")
    def test_frontend_projection_is_selectable_and_data_driven(self, _which, run):
        run.return_value.returncode = 0
        projection = targets.frontend_projection()
        self.assertEqual(["codex-standard"],
                         [target["targetId"] for target in projection["targets"]])
        self.assertNotIn("availability", projection["targets"][0])

    @mock.patch("devloop.targets.subprocess.run")
    @mock.patch("devloop.targets.shutil.which", return_value="/usr/bin/codex")
    def test_codex_must_be_authenticated_to_be_available(self, _which, run):
        run.return_value.returncode = 1
        codex = targets.load()["targets"][1]
        self.assertEqual(
            {"available": False, "reason": "not-authenticated"},
            targets.probe(codex),
        )
        run.assert_called_once_with(
            ["/usr/bin/codex", "login", "status"],
            text=True,
            capture_output=True,
            timeout=1.0,
        )


if __name__ == "__main__":
    unittest.main()
