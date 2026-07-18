"""Trusted provider adapters selected only from validated catalog targets."""

from .claude import ClaudeAdapter
from .codex import CodexAdapter
from .local_llama import LocalLlamaAdapter


def for_target(target):
    adapter = target["adapter"]
    if adapter == "codex":
        return CodexAdapter(target.get("executable", "codex"))
    if adapter == "claude-code":
        if not target.get("enabled"):
            raise RuntimeError("Claude target is disabled by configuration")
        return ClaudeAdapter(target.get("executable", "claude"))
    if adapter == "local-agent":
        return LocalLlamaAdapter(target["endpoint"])
    raise RuntimeError(f"unsupported provider adapter {adapter!r}")
