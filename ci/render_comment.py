"""Render the pull request comment and inline review comments for one agent run.

    python3 -I render_comment.py <agent-out> <verify-out> <pushed-sha|-> <run-url> <diff-lines.json>

Writes <verify-out>/comment.md and <verify-out>/review.json (inline comments for
findings on lines this pull request changed). Text that came from the agent is
derived from pull request content, so it is treated as untrusted: HTML is escaped,
mentions and links are neutralised, length is capped. Test and mutation numbers come
from verify's own measurements, never from the agent's claims.
"""

import hashlib
import json
import os
import re
import sys

MARKER = "<!-- tf-test-agent:summary -->"
SEVERITY = {"high": "🔴 high", "medium": "🟠 medium", "low": "🟡 low", "info": "🔵 info"}
ORDER = {"high": 0, "medium": 1, "low": 2, "info": 3}


def safe(text, limit=800):
    """Plain text that cannot ping people, embed HTML/images or hide links."""
    text = str(text or "")[:limit]
    text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", text)
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    text = re.sub(r"@(?=[A-Za-z0-9_-])", "@​", text)        # no mentions
    text = text.replace("](", "]​(").replace("![", "!​[")  # no links/images
    text = re.sub(r"(?i)\b(https?)://", r"\1[:]//", text)             # no autolinks
    text = text.replace("|", "\\|")                                   # keep tables intact
    return text.replace("\n", " ").strip()


def code(text, limit=200):
    text = str(text or "")[:limit].replace("`", "'").replace("\n", " ")
    return f"`{text}`"


def load(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def finding_key(f):
    raw = f"{f.get('file')}|{f.get('title')}|{f.get('rule_id', '')}"
    return hashlib.sha256(raw.encode()).hexdigest()[:12]


def main():
    agent_dir, verify_dir, pushed, run_url, diff_lines_path = sys.argv[1:6]
    report = load(os.path.join(agent_dir, "report.json"), None)
    meta = load(os.path.join(agent_dir, "run-meta.json"), {})
    verified = load(os.path.join(verify_dir, "verified.json"), {})
    diff_lines = load(diff_lines_path, {})
    report_ok = bool(report) and verified.get("report", {}).get("valid", False)

    tests = {t.get("module"): t for t in verified.get("tests", [])}
    mutation = {m.get("module"): m for m in verified.get("mutation", [])}
    out = [MARKER, "## Terraform test agent", ""]

    # Headline: what happened, from measurements.
    if not report:
        out.append("⚠️ **The agent did not produce a report**, so no tests were changed. "
                   "Deterministic checks (`terraform-checks`) are unaffected.")
    elif pushed != "-":
        out.append(f"✅ **Tests added or updated and verified**, pushed as {code(pushed[:12])}.")
    elif verified.get("patch", {}).get("files"):
        out.append("⚠️ **Tests were written but not pushed: independent verification failed.** "
                   "Details below.")
    elif not verified.get("ok", False):
        out.append("❌ **Tests of the changed modules fail.** No test changes were made; details below.")
    else:
        out.append("ℹ️ **No test changes were needed** for this change.")
    out.append("")
    if report_ok:
        out += [safe(report.get("summary"), 1500), ""]

    # Modules.
    if report_ok and report.get("modules"):
        out += ["### Modules", "",
                "| Module | Decision | Verified tests | Mutations caught |", "|---|---|---|---|"]
        for m in report["modules"]:
            t = tests.get(m["path"])
            if t is None:
                tests_cell = "—"
            elif t.get("status") == "pass":
                tests_cell = f"✅ {t.get('passed', 0)} passed"
            else:
                tests_cell = f"❌ {t.get('status')}: {t.get('failed') or 0} failed, {t.get('errored') or 0} errored"
            mu = mutation.get(m["path"])
            mu_cell = "—" if not mu or mu.get("score") is None else \
                f"{mu.get('killed')}/{mu.get('killed', 0) + mu.get('survived', 0)} ({mu.get('score')}%)"
            out.append(f"| {code(m['path'])} | **{m['decision']}**: {safe(m.get('reason'), 300)} "
                       f"| {tests_cell} | {mu_cell} |")
        out.append("")
        runs = [(m["path"], r) for m in report["modules"] for r in m.get("runs", [])]
        if runs:
            out += ["<details><summary>Test runs added or changed</summary>", ""]
            out += [f"- {code(p)} {code(r['name'])} ({r['change']}): {safe(r['checks'], 300)}" for p, r in runs]
            out += ["", "</details>", ""]

    # Findings.
    findings = sorted(report.get("findings", []) if report_ok else [],
                      key=lambda f: ORDER.get(f.get("severity"), 9))
    review = []
    if findings:
        out += [f"### Findings for reviewers ({len(findings)})", "",
                "The agent does not change infrastructure code; these are for you to decide.", ""]
        for f in findings:
            source = "agent" if f["source"] == "agent" else f"scanner {code(f.get('rule_id', ''))}"
            where = f"{code(f['file'] + ':' + str(f['line']))}"
            out.append(f"- **{SEVERITY.get(f['severity'], f['severity'])}**: {safe(f['title'], 140)} "
                       f"({where}, {source})")
            out.append(f"  - Why: {safe(f['why'])}")
            out.append(f"  - Suggestion: {safe(f['recommendation'], 600)}")
            if f.get("evidence"):
                out.append(f"  - Evidence: {safe(f['evidence'], 600)}")
            lines = set(diff_lines.get(f["file"], []))
            if f["line"] in lines:
                key = finding_key(f)
                review.append({
                    "path": f["file"], "line": f["line"], "side": "RIGHT", "key": key,
                    "body": (f"<!-- tf-test-agent:finding:{key} -->\n"
                             f"**{SEVERITY.get(f['severity'], f['severity'])}**: {safe(f['title'], 140)}\n\n"
                             f"{safe(f['why'])}\n\n**Suggestion:** {safe(f['recommendation'], 600)}"),
                })
        out.append("")

    # Behaviour no test protects (measured by verify).
    survivors = [(m["module"], s) for m in verified.get("mutation", []) for s in m.get("survivors", [])]
    if survivors:
        out += ["<details><summary>Behaviour no test catches yet (surviving mutations)</summary>", "",
                "Changing these lines did not make any test fail:", ""]
        out += [f"- {code(s['file'] if '/' in s['file'] else m + '/' + s['file'])}:{s['line']} "
                f"{code(s['original'], 120)} → {code(s['mutated'], 120)}" for m, s in survivors[:40]]
        out += ["", "</details>", ""]

    # Things CI enforced, independent of the agent.
    if verified.get("removed_config"):
        out += ["### ⚠️ Agent configuration changed in this pull request", "",
                "These files configure or run the review agent. They were **not used** for this run "
                "(the base branch's versions were); review them as code that runs in CI:", ""]
        out += [f"- {code(p)}" for p in verified["removed_config"][:30]] + [""]
    if verified.get("rejected_files"):
        out += ["### Discarded agent changes", "",
                "The agent changed files outside `tests/`; CI discarded them:", ""]
        out += [f"- {code(p)}" for p in verified["rejected_files"][:30]] + [""]
    problems = (verified.get("patch", {}).get("problems", [])
                + [f"lint {p.get('rule')}: {p.get('file')}:{p.get('line')} {p.get('message')}"
                   for p in verified.get("lint", {}).get("problems", [])]
                + verified.get("report", {}).get("problems", [])
                + verified.get("report", {}).get("mismatches", []))
    if problems:
        out += ["### Verification problems", ""] + [f"- {safe(p, 300)}" for p in problems[:30]] + [""]

    # Footer: limits of what this shows, and the run.
    cost = meta.get("total_cost_usd")
    out += ["---",
            "<sub>Tests run against mocked providers in a sandbox without network or credentials. "
            "They show what the configuration plans and how inputs are validated and wired; "
            "they cannot show that Azure accepts it or that the deployed system works. "
            f"Run: [workflow log]({run_url})"
            + (f" · {meta.get('num_turns')} turns" if meta.get("num_turns") else "")
            + (f" · ${cost:.2f}" if isinstance(cost, (int, float)) else "")
            + ".</sub>"]

    with open(os.path.join(verify_dir, "comment.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")
    with open(os.path.join(verify_dir, "review.json"), "w", encoding="utf-8") as fh:
        json.dump(review, fh, indent=2)


if __name__ == "__main__":
    main()
