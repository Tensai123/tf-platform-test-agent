"""Generate and apply single-point mutations of a Terraform module.

    python3 -I mutate.py list  <module-dir>                 -> JSON list of mutants
    python3 -I mutate.py apply <module-dir> <mutant-json>    -> rewrites one file

A mutant changes one thing the module promises: a literal setting, a default, a
validation rule, a for_each, a name template. If every test still passes against
the mutant, no test notices that promise being broken. That is the signal; the
operators are deliberately simple and line based so a reader can audit them.
"""

import json
import os
import re
import sys

SKIP_FILES = {"versions.tf", "provider.tf", "backend.tf"}
# Attributes whose literal value is documentation or wiring, not behaviour.
SKIP_ATTRS = {"description", "error_message", "source", "version", "required_version",
              "sensitive", "nullable"}

ATTR = re.compile(r'^(?P<indent>\s*)(?P<key>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?P<value>.+?)\s*$')
BOOL = re.compile(r'^(true|false)$')
NUMBER = re.compile(r'^-?\d+$')
PLAIN_STRING = re.compile(r'^"([^"$%\\]*)"$')
TEMPLATE_STRING = re.compile(r'^"([^"\\]*\$\{[^"\\]*)"$')
BLOCK_START = re.compile(r'^\s*(validation|lifecycle|precondition|postcondition)\s*\{\s*$')


def module_files(module):
    for name in sorted(os.listdir(module)):
        if name.endswith(".tf") and name not in SKIP_FILES:
            yield name


def block_end(lines, start):
    """Index of the line closing the block opened on `start` (brace counting)."""
    depth = 0
    for i in range(start, len(lines)):
        depth += lines[i].count("{") - lines[i].count("}")
        if depth == 0:
            return i
    return None


def mutants_for(module, name):
    with open(os.path.join(module, name), encoding="utf-8") as fh:
        lines = fh.read().split("\n")

    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith(("#", "//")):
            continue

        block = BLOCK_START.match(line)
        if block and block.group(1) == "validation":
            end = block_end(lines, i)
            if end is not None:
                yield {"operator": "remove_validation", "file": name, "line": i + 1,
                       "end_line": end + 1, "original": stripped, "mutated": "<removed>"}
            continue

        attr = ATTR.match(line)
        if not attr or attr.group("key") in SKIP_ATTRS:
            continue
        key, value, indent = attr.group("key"), attr.group("value"), attr.group("indent")

        def mutant(operator, new_value):
            return {"operator": operator, "file": name, "line": i + 1, "end_line": i + 1,
                    "original": stripped, "mutated": f"{key} = {new_value}",
                    "replacement": f"{indent}{key} = {new_value}"}

        if key == "for_each":
            if value not in ("{}", "[]"):
                yield mutant("empty_for_each", "{}")
        elif BOOL.match(value):
            yield mutant("flip_bool", "false" if value == "true" else "true")
        elif NUMBER.match(value):
            yield mutant("change_number", str(int(value) + 1))
        elif PLAIN_STRING.match(value):
            yield mutant("change_string", f'"{PLAIN_STRING.match(value).group(1)}_mutated"')
        elif TEMPLATE_STRING.match(value):
            yield mutant("change_template", f'"mutated-{TEMPLATE_STRING.match(value).group(1)}"')


def list_mutants(module):
    found = []
    for name in module_files(module):
        found.extend(mutants_for(module, name))
    for n, m in enumerate(found, 1):
        m["id"] = n
    return found


def apply_mutant(module, mutant):
    path = os.path.join(module, mutant["file"])
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    start, end = mutant["line"] - 1, mutant["end_line"] - 1
    if mutant["operator"] == "remove_validation":
        lines[start:end + 1] = []
    else:
        lines[start] = mutant["replacement"]
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))


def main():
    command, module = sys.argv[1], sys.argv[2]
    if command == "list":
        json.dump(list_mutants(module), sys.stdout, indent=2)
        print()
    elif command == "apply":
        apply_mutant(module, json.loads(sys.argv[3]))
    else:
        sys.exit(f"unknown command: {command}")


if __name__ == "__main__":
    main()
