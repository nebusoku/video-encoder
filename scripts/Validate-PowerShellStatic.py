#!/usr/bin/env python3
"""Static sanity checks for PowerShell scripts without requiring PowerShell runtime."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]


@dataclass
class Issue:
    path: Path
    line: int
    col: int
    message: str


def line_col(text: str, index: int) -> tuple[int, int]:
    line = text.count("\n", 0, index) + 1
    line_start = text.rfind("\n", 0, index)
    if line_start == -1:
        line_start = -1
    col = index - line_start
    return line, col


def balance_scan(path: Path, text: str) -> list[Issue]:
    issues: list[Issue] = []
    pairs = {"{": "}", "(": ")", "[": "]"}
    closers = {v: k for k, v in pairs.items()}
    stack: list[tuple[str, int]] = []

    i = 0
    n = len(text)
    state = "code"  # code, dquote, squote, linecomment, blockcomment
    while i < n:
        ch = text[i]

        if state == "linecomment":
            if ch == "\n":
                state = "code"
            i += 1
            continue

        if state == "blockcomment":
            if ch == "#" and i + 1 < n and text[i + 1] == ">":
                state = "code"
                i += 2
                continue
            i += 1
            continue

        if state == "dquote":
            if ch == "`" and i + 1 < n:
                i += 2
                continue
            if ch == '"':
                state = "code"
            i += 1
            continue

        if state == "squote":
            if ch == "'":
                if i + 1 < n and text[i + 1] == "'":
                    i += 2
                    continue
                state = "code"
            i += 1
            continue

        # code
        if ch == "<" and i + 1 < n and text[i + 1] == "#":
            state = "blockcomment"
            i += 2
            continue
        if ch == "#":
            state = "linecomment"
            i += 1
            continue
        if ch == '"':
            state = "dquote"
            i += 1
            continue
        if ch == "'":
            state = "squote"
            i += 1
            continue

        if ch in pairs:
            stack.append((ch, i))
        elif ch in closers:
            if not stack or stack[-1][0] != closers[ch]:
                line, col = line_col(text, i)
                issues.append(Issue(path, line, col, f"Unexpected closing token '{ch}'."))
            else:
                stack.pop()

        i += 1

    for opener, idx in stack:
        line, col = line_col(text, idx)
        issues.append(Issue(path, line, col, f"Missing closing token for '{opener}'."))

    if state in {"dquote", "squote"}:
        line, col = line_col(text, n - 1 if n else 0)
        issues.append(Issue(path, line, col, f"Unterminated string literal ({state})."))

    return issues


def check_file(path: Path) -> list[Issue]:
    text = path.read_text(encoding="utf-8")
    issues: list[Issue] = []

    for marker in ("<<<<<<<", "=======", ">>>>>>>"):
        idx = text.find(marker)
        if idx != -1:
            line, col = line_col(text, idx)
            issues.append(Issue(path, line, col, f"Merge marker '{marker}' found."))

    rel = path.relative_to(ROOT).as_posix()
    wrapper_limits = {
        "video-convert.ps1": 80,
        "scripts/Test-PowerShellSyntax.ps1": 80,
        "scripts/Ensure-Dependencies.ps1": 80,
    }
    if rel in wrapper_limits:
        line_count = text.count("\n") + (0 if text.endswith("\n") else 1)
        if line_count > wrapper_limits[rel]:
            issues.append(Issue(path, 1, 1, "Compatibility wrapper unexpectedly large; possible accidental script concatenation."))
        if "& $core @args" not in text:
            issues.append(Issue(path, 1, 1, "Compatibility wrapper must forward with '& $core @args'."))
    if rel in {"video-convert.ps1", "scripts/Test-PowerShellSyntax.ps1", "scripts/Ensure-Dependencies.ps1"}:
        lowered = text.lower()
        for token in ("[cmdletbinding", "\nparam("):
            idx = lowered.find(token)
            if idx != -1:
                line, col = line_col(text, idx)
                issues.append(Issue(path, line, col, "Compatibility wrapper should not contain advanced param blocks."))

    issues.extend(balance_scan(path, text))
    return issues


def main() -> int:
    files = sorted(ROOT.glob("*.ps1")) + sorted((ROOT / "scripts").glob("*.ps1"))
    all_issues: list[Issue] = []

    for path in files:
        file_issues = check_file(path)
        all_issues.extend(file_issues)
        tag = "FAIL" if file_issues else "OK"
        print(f"[{tag}] {path.relative_to(ROOT)}")
        for issue in file_issues:
            print(f"  - line {issue.line}, col {issue.col}: {issue.message}")

    if all_issues:
        print("\nStatic PowerShell sanity checks found issues.")
        return 1

    print("\nStatic PowerShell sanity checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
