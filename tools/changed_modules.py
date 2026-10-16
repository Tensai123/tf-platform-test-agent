"""Group `git diff --name-status` lines by Terraform module. See changed-modules.sh."""

import glob
import json
import os
import re
import sys

MODULE_PATH = re.compile(r"^((?:modules|stacks)/[^/]+)/(.*)$")
MODULE_SOURCE = re.compile(r'source\s*=\s*"(?:\.\./)+(modules/[^"/]+)"')


def module_consumers():
    """Map modules/<name> -> stacks that use it through a relative source."""
    consumers = {}
    for tf in glob.glob("stacks/*/*.tf"):
        with open(tf, encoding="utf-8") as fh:
            for module in MODULE_SOURCE.findall(fh.read()):
                consumers.setdefault(module, set()).add(os.path.dirname(tf))
    return consumers


def main():
    mode, base, head = sys.argv[1:4]
    consumers = module_consumers()
    modules, other = {}, []

    for line in sys.stdin:
        line = line.rstrip("\n")
        if not line:
            continue
        status, path = line.split("\t", 1)
        match = MODULE_PATH.match(path)
        if not match:
            other.append({"path": path, "status": status})
            continue
        module, rest = match.groups()
        entry = modules.setdefault(module, {
            "path": module,
            "files": [],
            "touches": {"code": False, "tests": False, "other": False},
        })
        if mode == "all":
            entry["touches"]["code"] = True
            continue
        entry["files"].append({"path": path, "status": status})
        if rest.endswith(".tf") and "/" not in rest:
            entry["touches"]["code"] = True
        elif rest.startswith("tests/"):
            entry["touches"]["tests"] = True
        else:
            entry["touches"]["other"] = True

    for module, entry in modules.items():
        entry["exists"] = os.path.isdir(module)
        entry["has_tests"] = bool(glob.glob(os.path.join(module, "tests", "*.tftest.hcl")))
        entry["used_by"] = sorted(consumers.get(module, ()))

    json.dump({
        "base": base or None,
        "head": head or None,
        "mode": mode,
        "modules": sorted(modules.values(), key=lambda e: e["path"]),
        "other_files": other,
    }, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
