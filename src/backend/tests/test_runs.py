from __future__ import annotations

import unittest

from devloop import runs


class RunRecordTests(unittest.TestCase):
    def setUp(self):
        self.decision = {
            "targetId": "codex-standard",
            "provider": "codex",
            "model": "default",
            "effort": "high",
            "reasonCodes": ["code-change"],
            "confidence": "high",
        }

    def test_run_assignment_is_separate_from_request_fields(self):
        payload = runs.run_payload(
            self.decision, catalog_version="v1", router_model="gemma"
        )
        self.assertEqual("codex-standard", payload["targetId"])
        self.assertNotIn("requestedProvider", payload)
        self.assertNotIn("requestedModel", payload)
        self.assertNotIn("requestedEffort", payload)

    def test_routing_event_has_stable_identity_inputs(self):
        assignment = runs.run_payload(
            self.decision, catalog_version="v1", router_model="gemma"
        )
        event = runs.routing_event_payload("run-1", assignment)
        self.assertEqual("routing", event["kind"])
        self.assertEqual("run-1", event["runId"])
        self.assertEqual("assigned", event["state"])
        self.assertEqual("codex", event["provider"])


if __name__ == "__main__":
    unittest.main()
