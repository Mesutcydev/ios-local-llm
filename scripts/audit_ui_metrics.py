#!/usr/bin/env python3
"""Fail when SwiftUI layout literals bypass the design scale.

Spacing, radii, square tile sizes, font sizes and letter-spacing come from the
tokens in IOSLocalLLM/Views/AppDesignSystem.swift (Space, Radius, Size,
TextScale). Allowed literals: 0, 0.5 and 1 pt optical gaps, insets above 48 pt,
radii of 4 pt or less (thin bars) and capsule radii, and negative tracking on
display titles.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "IOSLocalLLM"
SKIP = {"AppDesignSystem.swift", "FirstLightSplashView.swift", "PlumDuskSplashView.swift",
        "LensDebugOverlay.swift"}
NUM = r"(\d+(?:\.\d+)?)"

RULES = [
    ("spacing", re.compile(r"\.padding\(\s*(?:\.[a-zA-Z]+\s*,\s*|\[[^\]\n]*\]\s*,\s*)?" + NUM + r"\s*\)"),
     lambda v: v > 1 and v <= 48, "use a Space token"),
    ("spacing", re.compile(r"\bspacing:\s*" + NUM + r"(?=\s*[,)])"),
     lambda v: v > 1 and v <= 48, "use a Space token"),
    ("spacing", re.compile(r"\b(?:spacing|padding):\s*[^,)\n?]*\?\s*" + NUM),
     lambda v: v > 1 and v <= 48, "use Space tokens in both branches"),
    ("radius", re.compile(r"\bcornerRadius:\s*" + NUM + r"(?=\s*[,)])"),
     lambda v: 4 < v < 999, "use a Radius token"),
    ("font", re.compile(r"\.system\(size:\s*" + NUM),
     lambda v: True, "use a text style (TextScale)"),
    ("square", re.compile(r"\.frame\(width:\s*" + NUM + r",\s*height:\s*\1\s*\)"),
     lambda v: 16 <= v <= 56, "use a Size token"),
    ("tracking", re.compile(r"\.tracking\(\s*" + NUM + r"\s*\)"),
     lambda v: v > 0, "caps use TextScale.capsTracking; mixed case uses none"),
]


def main() -> int:
    problems = []
    for path in sorted(SOURCES.rglob("*.swift")):
        if path.name in SKIP:
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for kind, pattern, off_scale, hint in RULES:
                for match in pattern.finditer(line):
                    value = float(match.group(1))
                    if off_scale(value):
                        rel = path.relative_to(ROOT)
                        problems.append(f"{rel}:{number}: {kind} {match.group(1)} is off the scale; {hint}")
    if problems:
        print("UI metrics check failed:", file=sys.stderr)
        print("\n".join(problems), file=sys.stderr)
        return 1
    print("UI metrics: every spacing, radius, tile size, font size and caps tracking is on the scale.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
