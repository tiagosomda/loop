from __future__ import annotations

import unittest
from unittest import mock

from devloop import items


class ItemRoutingRequestTests(unittest.TestCase):
    @mock.patch("devloop.items.post_message")
    @mock.patch("devloop.items._next_order", return_value=1000.0)
    @mock.patch("devloop.items._items")
    def test_create_allows_all_routing_requests_to_be_null(
        self, item_collection, _next_order, post_message
    ):
        ref = item_collection.return_value.document.return_value
        ref.id = "item-id"

        result = items.create_item("Title", "repo", None, None, None)

        self.assertEqual("item-id", result)
        payload = ref.set.call_args.args[0]
        self.assertIsNone(payload["requestedProvider"])
        self.assertIsNone(payload["requestedModel"])
        self.assertIsNone(payload["requestedEffort"])
        self.assertNotIn("model", payload)
        self.assertNotIn("effortLevel", payload)
        post_message.assert_not_called()

    @mock.patch("devloop.items.post_message")
    @mock.patch("devloop.items._next_order", return_value=1000.0)
    @mock.patch("devloop.items._items")
    def test_create_preserves_partial_routing_request(
        self, item_collection, _next_order, _post_message
    ):
        ref = item_collection.return_value.document.return_value
        ref.id = "item-id"

        items.create_item("Title", "repo", "Do it", None, "high", "codex-standard")

        payload = ref.set.call_args.args[0]
        self.assertEqual("codex-standard", payload["requestedProvider"])
        self.assertIsNone(payload["requestedModel"])
        self.assertEqual("high", payload["requestedEffort"])

    @mock.patch("devloop.items.runlog.log")
    @mock.patch("devloop.items.fs.db")
    @mock.patch("devloop.items._items")
    def test_pause_for_review_commits_message_and_status_together(
        self, item_collection, db, log
    ):
        batch = db.return_value.batch.return_value
        items.pause_for_review("item-1", "Routing needs review")
        batch.set.assert_called_once()
        batch.update.assert_called_once()
        self.assertEqual("needs-review", batch.update.call_args.args[1]["status"])
        batch.commit.assert_called_once()
        log.assert_called_once_with("item item-1 -> needs-review")
        item_collection.return_value.document.assert_called_once_with("item-1")


if __name__ == "__main__":
    unittest.main()
