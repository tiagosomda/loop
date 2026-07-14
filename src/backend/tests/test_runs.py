from __future__ import annotations

import unittest
from unittest import mock

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
        self.assertEqual(
            "routing-run-1-assigned",
            runs.routing_event_id("run-1", "assigned"),
        )

    @mock.patch("devloop.runs.runlog.log")
    @mock.patch("devloop.runs.firestore.transactional", side_effect=lambda fn: fn)
    @mock.patch("devloop.runs.fs.db")
    def test_assignment_and_claim_are_one_transaction(self, db, _decorator, log):
        item_ref = db.return_value.collection.return_value.document.return_value
        run_ref = item_ref.collection.return_value.document.return_value
        item_ref.get.return_value = mock.Mock(
            exists=True, to_dict=lambda: {"status": "open"}
        )
        tx = db.return_value.transaction.return_value

        run_id = runs.create_claimed_assignment(
            "item-1",
            self.decision,
            catalog_version="v1",
            router_model="gemma",
            checkout={"path": "/repo", "startingRevision": "abc"},
        )

        self.assertEqual(32, len(run_id))
        tx.set.assert_called_once()
        self.assertIs(run_ref, tx.set.call_args.args[0])
        self.assertEqual("running", tx.set.call_args.args[1]["state"])
        tx.update.assert_called_once()
        self.assertEqual("in-progress", tx.update.call_args.args[1]["status"])
        log.assert_called_once()

    @mock.patch("devloop.runs.firestore.transactional", side_effect=lambda fn: fn)
    @mock.patch("devloop.runs.fs.db")
    def test_transaction_rechecks_item_eligibility(self, db, _decorator):
        item_ref = db.return_value.collection.return_value.document.return_value
        item_ref.get.return_value = mock.Mock(
            exists=True, to_dict=lambda: {"status": "in-progress"}
        )
        with self.assertRaisesRegex(runs.RunConflict, "in-progress"):
            runs.create_claimed_assignment(
                "item-1",
                self.decision,
                catalog_version="v1",
                router_model="gemma",
                checkout={"path": "/repo"},
            )
        db.return_value.transaction.return_value.set.assert_not_called()


if __name__ == "__main__":
    unittest.main()
