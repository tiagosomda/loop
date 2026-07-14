from __future__ import annotations

import json
import unittest
from unittest import mock

from devloop import router


def context():
    return {
        "item": {"id": "item-1"},
        "requested": {"provider": None, "model": None, "effort": None},
        "allowedTargets": [{
            "targetId": "codex-standard",
            "adapter": "codex",
            "models": ["default"],
            "effortLevels": ["low", "medium", "high", "max"],
        }],
    }


def decision():
    return {
        "schemaVersion": 1,
        "itemId": "item-1",
        "targetId": "codex-standard",
        "provider": "codex",
        "model": "default",
        "effort": "medium",
        "reasonCodes": ["code-change"],
        "confidence": "high",
    }


class RouterTests(unittest.TestCase):
    def test_no_available_target_abstains_before_inference(self):
        value = context()
        value["allowedTargets"] = []
        with self.assertRaisesRegex(router.RoutingError, "needs-human-routing"):
            router.decide(value)

    def test_valid_decision(self):
        router.validate_decision(context(), decision())

    def test_unknown_target_is_rejected(self):
        value = decision()
        value["targetId"] = "invented"
        with self.assertRaisesRegex(router.RoutingError, "not currently allowed"):
            router.validate_decision(context(), value)

    def test_override_violation_is_rejected(self):
        value = context()
        value["requested"]["effort"] = "high"
        with self.assertRaisesRegex(router.RoutingError, "requested effort"):
            router.validate_decision(value, decision())

    def test_extra_command_field_is_rejected(self):
        value = decision()
        value["command"] = "rm -rf /"
        with self.assertRaisesRegex(router.RoutingError, "unexpected fields"):
            router.validate_decision(context(), value)

    @mock.patch("devloop.router._router_target")
    @mock.patch("devloop.router.requests.post")
    def test_decide_uses_schema_constrained_local_endpoint(self, post, target):
        target.return_value = {
            "endpoint": "http://127.0.0.1:8080",
            "models": ["gemma-3-4b-it"],
        }
        post.return_value.json.return_value = {
            "choices": [{"message": {"content": json.dumps(decision())}}],
        }

        self.assertEqual(decision(), router.decide(context()))

        call = post.call_args
        self.assertEqual("http://127.0.0.1:8080/v1/chat/completions", call.args[0])
        self.assertEqual("json_schema", call.kwargs["json"]["response_format"]["type"])
        self.assertEqual(0, call.kwargs["json"]["temperature"])

    @mock.patch("devloop.router._router_target")
    @mock.patch("devloop.router.requests.post")
    def test_malformed_output_is_rejected(self, post, target):
        target.return_value = {"endpoint": "http://127.0.0.1:8080", "models": ["x"]}
        post.return_value.json.return_value = {
            "choices": [{"message": {"content": "not-json"}}],
        }
        with self.assertRaisesRegex(router.RoutingError, "local router failed"):
            router.decide(context())


if __name__ == "__main__":
    unittest.main()
