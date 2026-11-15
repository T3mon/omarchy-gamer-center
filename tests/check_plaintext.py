#!/usr/bin/env python3
"""Every QML Text in the plugin must render as plain text.

GPU names, display names and helper output end up in Text items; a Text
left on the default AutoText would read markup-shaped input as rich text.
Exits 1 and lists each Text block that does not set Text.PlainText.
"""

import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OPENING = re.compile(r"(?:^|[\s:])Text\s*\{")
RICH = re.compile(r"Text\.(?:RichText|StyledText|MarkdownText|AutoText)")


def block_at(text, start):
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return text[start:]


def own_text(block):
    """The block's own properties, without the bodies of nested objects."""
    depth, kept = 0, []
    for ch in block:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        elif depth == 1:
            kept.append(ch)
    return "".join(kept)


def problems(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    found = []
    for match in OPENING.finditer(text):
        brace = text.index("{", match.start())
        block = block_at(text, brace)
        if "textFormat: Text.PlainText" not in own_text(block):
            line = text.count("\n", 0, brace) + 1
            found.append("%s:%d: Text without textFormat: Text.PlainText" % (path, line))
    for match in RICH.finditer(text):
        line = text.count("\n", 0, match.start()) + 1
        found.append("%s:%d: %s" % (path, line, match.group(0)))
    return found


def main():
    found = []
    for directory, dirs, files in os.walk(ROOT):
        dirs[:] = sorted(d for d in dirs if d not in (".git", "__pycache__"))
        for name in sorted(files):
            if name.endswith(".qml"):
                found += problems(os.path.relpath(os.path.join(directory, name)))
    for problem in found:
        print(problem)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
