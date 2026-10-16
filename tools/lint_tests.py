"""Static checks on *.tftest.hcl files, run before any test executes.

    python3 -I lint_tests.py <repo-root> <module-dir>...   -> JSON, exit 1 on problems

The rules target the ways a generated test can look green while proving nothing,
or reach outside the sandbox's intent:
  run-without-checks     a run block with neither assert nor expect_failures
  trivial-condition      condition = true, or comparing an expression with itself
  unmocked-provider      a provider the module needs is not mocked in the file
                         (only random, null and time may run for real)
  unmocked-external      a module data "external" source runs for real in the test
  provider-block         a real provider block in a test file
  remote-helper-module   a run uses a module that is not a local path

This is a line/brace scanner, not an HCL parser: it is strict on purpose and a
rule it cannot apply cleanly reports a problem rather than passing silently.
"""

import glob
import json
import os
import re
import sys

REAL_PROVIDERS_ALLOWED = {"random", "null", "time"}
BLOCK = re.compile(r'^\s*(run|mock_provider|provider|override_data|override_resource|'
                   r'override_module|module|assert|variables)\b\s*(?:"([^"]+)")?\s*\{')
REQUIRED_PROVIDER = re.compile(r'^\s*([a-z0-9_-]+)\s*=\s*\{\s*$')
DATA_EXTERNAL = re.compile(r'^\s*data\s+"external"\s+"([^"]+)"')
CONDITION = re.compile(r'^\s*condition\s*=\s*(.+?)\s*$')
SOURCE = re.compile(r'^\s*source\s*=\s*"([^"]*)"')
TARGET = re.compile(r'^\s*target\s*=\s*(\S+)')


def strip_comments(text):
    out = []
    for line in text.split("\n"):
        line = re.sub(r'(^|\s)(#|//).*$', "", line)
        out.append(line)
    return out


def blocks(lines):
    """Yield (kind, label, start_line, body_lines) for top-level and nested blocks."""
    stack = []
    for i, line in enumerate(lines):
        match = BLOCK.match(line)
        if match:
            stack.append([match.group(1), match.group(2), i + 1, [], 0])
        for frame in stack:
            frame[3].append(line)
        delta = line.count("{") - line.count("}")
        for frame in stack:
            frame[4] += delta
        while stack and stack[-1][4] <= 0 and stack[-1][3]:
            kind, label, start, body, _ = stack.pop()
            yield kind, label, start, body


def module_facts(module):
    providers, externals = set(), []
    for tf in glob.glob(os.path.join(module, "*.tf")):
        with open(tf, encoding="utf-8") as fh:
            lines = strip_comments(fh.read())
        in_required = False
        depth = 0
        for line in lines:
            if re.match(r'^\s*required_providers\s*\{', line):
                in_required, depth = True, 0
            if in_required:
                depth += line.count("{") - line.count("}")
                match = REQUIRED_PROVIDER.match(line)
                if match and depth == 2:
                    providers.add(match.group(1))
                if depth <= 0:
                    in_required = False
            match = DATA_EXTERNAL.match(line)
            if match:
                externals.append(match.group(1))
    return providers, externals


def trivial(condition):
    expr = condition.strip()
    if expr in ("true", "!false", "(true)"):
        return True
    match = re.match(r'^(.+?)\s*==\s*(.+)$', expr)
    return bool(match and match.group(1).strip() == match.group(2).strip())


def lint_file(path, rel, providers, externals):
    problems = []

    def problem(line, rule, message):
        problems.append({"file": rel, "line": line, "rule": rule, "message": message})

    with open(path, encoding="utf-8") as fh:
        lines = strip_comments(fh.read())

    mocked, overridden_data = set(), set()
    for kind, label, start, body in blocks(lines):
        if kind == "mock_provider" and label:
            mocked.add(label.split(".")[0])
        elif kind == "provider":
            problem(start, "provider-block",
                    f'provider "{label}" in a test runs the real provider; use mock_provider')
        elif kind == "override_data":
            for line in body:
                target = TARGET.match(line)
                if target:
                    overridden_data.add(target.group(1))
        elif kind == "run":
            has_assert = any(BLOCK.match(l) and BLOCK.match(l).group(1) == "assert" for l in body)
            has_expect = any(re.match(r'^\s*expect_failures\s*=', l) for l in body)
            if not (has_assert or has_expect):
                problem(start, "run-without-checks",
                        f'run "{label}" has no assert and no expect_failures; it proves nothing')
            for offset, line in enumerate(body):
                cond = CONDITION.match(line)
                if cond and trivial(cond.group(1)):
                    problem(start + offset, "trivial-condition",
                            f"condition `{cond.group(1)}` is always true")
        elif kind == "module":
            for line in body:
                src = SOURCE.match(line)
                if src and not src.group(1).startswith(("./", "../")):
                    problem(start, "remote-helper-module",
                            f'helper module source "{src.group(1)}" is not a local path')

    for provider in sorted(providers - mocked - REAL_PROVIDERS_ALLOWED):
        if provider == "external":
            continue  # reported per data source below, with the exact fix
        problem(1, "unmocked-provider",
                f'the module requires provider "{provider}" but this file does not mock it')
    if "external" not in mocked:
        for name in externals:
            if f"data.external.{name}" not in overridden_data:
                problem(1, "unmocked-external",
                        f'data.external.{name} would run its program during the test; '
                        f'add mock_provider "external" or override_data for it')
    return problems


def main():
    root, modules = sys.argv[1], sys.argv[2:]
    problems, checked = [], []
    for module in modules:
        providers, externals = module_facts(os.path.join(root, module))
        for path in sorted(glob.glob(os.path.join(root, module, "tests", "*.tftest.hcl"))):
            rel = os.path.relpath(path, root)
            checked.append(rel)
            problems.extend(lint_file(path, rel, providers, externals))
    json.dump({"ok": not problems, "checked": checked, "problems": problems},
              sys.stdout, indent=2)
    print()
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
