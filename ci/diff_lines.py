"""Lines of the pull request head that GitHub accepts inline review comments on.

    gh api --paginate repos/R/pulls/N/files | python3 -I diff_lines.py > lines.json

Output: {"path": [line, ...]} with every added or context line of each hunk, on the
new side. A comment on any other line is rejected by the API.
"""

import json
import re
import sys

HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def lines_of(patch):
    result, line = [], None
    for row in patch.split("\n"):
        match = HUNK.match(row)
        if match:
            line = int(match.group(1))
            continue
        if line is None or row.startswith("\\"):
            continue
        if row.startswith("-"):
            continue
        result.append(line)
        line += 1
    return result


def main():
    text = sys.stdin.read()
    # --paginate concatenates one JSON array per page.
    files = []
    decoder, pos = json.JSONDecoder(), 0
    while pos < len(text):
        while pos < len(text) and text[pos].isspace():
            pos += 1
        if pos >= len(text):
            break
        page, pos = decoder.raw_decode(text, pos)
        files.extend(page)
    print(json.dumps({f["filename"]: lines_of(f.get("patch", "")) for f in files
                      if f.get("status") != "removed"}))


if __name__ == "__main__":
    main()
