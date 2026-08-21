#!/usr/bin/env python3
"""Patch PR-Agent for full DeepSeek support.

- Add DeepSeek models to SUPPORT_REASONING_EFFORT_MODELS so config.reasoning_effort
  is forwarded to DeepSeek's API (LiteLLM's deepseek transformation already
  handles it: maps to thinking mode, forwards reasoning_effort).
- Add "max" to the ReasoningEffort enum (DeepSeek's native max effort value;
  upstream enum stops at xhigh, which DeepSeek maps to high).
"""

TARGETS = [
    (
        "/app/pr_agent/algo/__init__.py",
        'SUPPORT_REASONING_EFFORT_MODELS = [\n    "o3-mini",',
        'SUPPORT_REASONING_EFFORT_MODELS = [\n'
        '    # DeepSeek v4: native reasoning_effort (low/high/max); '
        "see DeepSeek thinking-mode docs\n"
        '    "deepseek-v4-pro",\n'
        '    "deepseek-v4-flash",\n'
        '    "deepseek-chat",\n'
        '    "deepseek-reasoner",\n'
        '    "o3-mini",',
    ),
    (
        "/app/pr_agent/algo/utils.py",
        "class ReasoningEffort(str, Enum):\n    XHIGH = \"xhigh\"",
        "class ReasoningEffort(str, Enum):\n"
        '    MAX = "max"\n'
        '    XHIGH = "xhigh"',
    ),
]


def main() -> int:
    for path, old, new in TARGETS:
        with open(path, "r", encoding="utf-8") as f:
            src = f.read()
        if old not in src:
            raise SystemExit(f"patch target missing in {path!r}")
        with open(path, "w", encoding="utf-8") as f:
            f.write(src.replace(old, new, 1))
        print(f"patched {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
