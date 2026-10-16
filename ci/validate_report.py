"""Validate the agent's report against ci/report.schema.json and against reality.

    python3 -I validate_report.py <schema> <report> <pr-dir> <verify-tests.json>

Prints JSON { valid, problems: [..], mismatches: [..] }. Only the JSON Schema
keywords the report schema uses are implemented, deliberately: no third-party
dependency on the runner, and an unknown keyword is an error rather than ignored.

`mismatches` compare what the agent claims with what verify measured: a test status
that differs, a test file that does not exist, a finding pointing at a line that is
not there. The report is rendered for people, so claims are checked, not trusted.
"""

import json
import os
import re
import sys

KNOWN = {"title", "type", "additionalProperties", "required", "properties", "items",
         "enum", "pattern", "maxLength", "maxItems", "minimum"}


def validate(schema, value, path, problems):
    unknown = set(schema) - KNOWN
    if unknown:
        problems.append(f"{path}: schema uses unsupported keywords {sorted(unknown)}")
        return
    kind = schema.get("type")
    checks = {
        "object": lambda v: isinstance(v, dict),
        "array": lambda v: isinstance(v, list),
        "string": lambda v: isinstance(v, str),
        "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
        "boolean": lambda v: isinstance(v, bool),
    }
    if kind and not checks[kind](value):
        problems.append(f"{path}: expected {kind}")
        return
    if "enum" in schema and value not in schema["enum"]:
        problems.append(f"{path}: {value!r} not one of {schema['enum']}")
    if isinstance(value, str):
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            problems.append(f"{path}: longer than {schema['maxLength']}")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            problems.append(f"{path}: does not match {schema['pattern']}")
    if isinstance(value, int) and "minimum" in schema and value < schema["minimum"]:
        problems.append(f"{path}: below {schema['minimum']}")
    if isinstance(value, list):
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            problems.append(f"{path}: more than {schema['maxItems']} items")
        for i, item in enumerate(value):
            validate(schema.get("items", {}), item, f"{path}[{i}]", problems)
    if isinstance(value, dict):
        props = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                problems.append(f"{path}: missing {key}")
        for key, item in value.items():
            if key in props:
                validate(props[key], item, f"{path}.{key}", problems)
            elif schema.get("additionalProperties") is False:
                problems.append(f"{path}: unexpected property {key}")


def line_count(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return sum(1 for _ in fh)


def main():
    schema_path, report_path, pr_dir, tests_path = sys.argv[1:5]
    with open(schema_path) as fh:
        schema = json.load(fh)
    problems, mismatches = [], []
    try:
        with open(report_path) as fh:
            report = json.load(fh)
    except (OSError, ValueError) as err:
        print(json.dumps({"valid": False, "problems": [f"report unreadable: {err}"], "mismatches": []}))
        return
    validate(schema, report, "$", problems)

    measured = {}
    if os.path.exists(tests_path):
        with open(tests_path) as fh:
            for summary in json.load(fh):
                measured[summary["module"]] = summary.get("status")

    # Claims vs measurements; tolerant of a malformed report so every problem shows.
    modules = report.get("modules") if isinstance(report, dict) else None
    for module in modules if isinstance(modules, list) else []:
        if not isinstance(module, dict):
            continue
        path, claimed = module.get("path"), module.get("test_status")
        actual = measured.get(path)
        if actual and claimed not in (None, "not_run") and claimed != actual:
            mismatches.append(f"{path}: agent reported tests {claimed}, verify measured {actual}")
        for test_file in module.get("test_files") or []:
            if isinstance(test_file, str) and not os.path.isfile(os.path.join(pr_dir, test_file)):
                mismatches.append(f"{path}: reported test file {test_file} does not exist")
    findings = report.get("findings") if isinstance(report, dict) else None
    root = os.path.abspath(pr_dir)
    for i, finding in enumerate(findings if isinstance(findings, list) else []):
        if not isinstance(finding, dict) or not isinstance(finding.get("file"), str):
            continue
        target = os.path.abspath(os.path.join(root, finding["file"]))
        line = finding.get("line")
        if not target.startswith(root + os.sep):
            mismatches.append(f"findings[{i}]: {finding['file']} is outside the repository")
        elif not os.path.isfile(target):
            mismatches.append(f"findings[{i}]: {finding['file']} does not exist")
        elif isinstance(line, int) and line > line_count(target):
            mismatches.append(f"findings[{i}]: {finding['file']} has no line {line}")

    print(json.dumps({"valid": not problems, "problems": problems[:50], "mismatches": mismatches[:50]}))


if __name__ == "__main__":
    main()
