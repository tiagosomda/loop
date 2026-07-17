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

    def test_decision_schema_constrains_targetid_provider_to_catalog(self):
        schema = router._decision_schema(context())
        props = schema["properties"]
        self.assertEqual(["codex-standard"], props["targetId"]["enum"])
        self.assertEqual(["codex"], props["provider"]["enum"])
        self.assertEqual(["default"], props["model"]["enum"])
        self.assertEqual(["high", "low", "max", "medium"], props["effort"]["enum"])
        # The module-level schema must not be mutated by the per-request copy.
        self.assertEqual(
            {"type": "string", "minLength": 1},
            router.DECISION_SCHEMA["properties"]["targetId"],
        )

    def test_decision_schema_pins_hard_requested_values(self):
        value = context()
        value["requested"]["effort"] = "high"
        schema = router._decision_schema(value)
        self.assertEqual(["high"], schema["properties"]["effort"]["enum"])

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

    def test_low_confidence_abstains(self):
        value = decision()
        value["confidence"] = "low"
        with self.assertRaisesRegex(router.RoutingError, "needs-human-routing"):
            router.validate_decision(context(), value)

    def test_configured_fallback_resolves_to_codex_sol_high(self):
        value = context()
        value["allowedTargets"][0]["models"] = ["gpt-5.6-sol"]
        fallback = router.fallback_decision(value, {
            "fallbackAssignment": {
                "targetId": "codex-standard",
                "provider": "codex",
                "model": "gpt-5.6-sol",
                "effort": "high",
            },
        })
        self.assertEqual("codex-standard", fallback["targetId"])
        self.assertEqual("gpt-5.6-sol", fallback["model"])
        self.assertEqual("high", fallback["effort"])
        self.assertIn("router-abstained", fallback["reasonCodes"])

    def test_configured_fallback_does_not_override_request_constraints(self):
        value = context()
        value["allowedTargets"][0]["models"] = ["gpt-5.6-sol"]
        value["requested"]["effort"] = "low"
        self.assertIsNone(router.fallback_decision(value, {
            "fallbackAssignment": {
                "targetId": "codex-standard",
                "provider": "codex",
                "model": "gpt-5.6-sol",
                "effort": "high",
            },
        }))

    def test_invalid_reason_code_is_rejected(self):
        value = decision()
        value["reasonCodes"] = ["private reasoning"]
        with self.assertRaisesRegex(router.RoutingError, "invalid reasonCodes"):
            router.validate_decision(context(), value)

    def test_request_constraints_filter_targets_before_inference(self):
        self.assertTrue(router._matches_request(
            context()["allowedTargets"][0],
            {"provider": "codex", "model": "default", "effort": "high"},
        ))
        self.assertFalse(router._matches_request(
            context()["allowedTargets"][0],
            {"provider": "claude-code", "model": None, "effort": None},
        ))

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
