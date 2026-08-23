#!/usr/bin/env python3
"""PPS shared evidence engine — one implementation for every platform.

Both verify_gate and validate_project (PowerShell and Bash editions) call this
module for everything that must mean the same thing everywhere: run-record
checks, Git lineage, and Verification parsing. The shell scripts deliberately
do not carry their own copies of these rules.

Every subcommand prints a single machine token on stdout (or a short list) and
exits 0. It exits non-zero only when the invocation itself is malformed; the
verdict is always the printed token, so callers compare tokens, not prose.
"""
import json
import os
import re
import subprocess
import sys

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SCHEMA_PATH = os.path.join(_SCRIPT_DIR, os.pardir, "references", "state-machine.json")
if not os.path.isfile(SCHEMA_PATH):
    # Installed projects carry the schema next to the scripts.
    SCHEMA_PATH = os.path.join(_SCRIPT_DIR, "state-machine.json")


def _word_list(key, default):
    """Read a word list from the single source (state-machine.json); the
    hardcoded defaults exist only for a missing schema, so editing the JSON
    edits the rule and editing the rule means editing the JSON."""
    try:
        with open(SCHEMA_PATH, encoding="utf-8") as fh:
            data = json.load(fh)
        value = data.get(key)
        if isinstance(value, list):
            return [str(x) for x in value]
    except Exception:
        pass
    return list(default)


_DEFAULT_NEGATIVE = [
    "fail", "failed", "failing", "failure", "error", "errors", "aborted",
    "deny", "denied", "denies", "denying", "revoke", "revoked",
    "reject", "rejected", "rejects", "not authorized", "not authorize",
    "does not authorize", "do not create", "never create", "does not exist",
    "unavailable", "cannot", "forbid", "forbidden", "refuse", "refused",
]
_DEFAULT_POSITIVE_OUTCOME = ["pass", "passed", "passes", "ok", "success", "succeeded", "green"]
_DEFAULT_EVENT_TYPES = [
    "merged", "integrated", "validated", "verified", "landed", "shipped",
    "closed", "completed", "approved", "package_created", "package_activated",
    "package_closed", "handoff_recorded", "migration_authorized",
    "integrate", "validate", "verify",
]
_DEFAULT_GATE_NAMES = ["verify_gate", "readiness_check", "validate_project", "asset_check", "boundary_check"]

NEGATIVE_WORDS = _word_list("negative_outcome_words", _DEFAULT_NEGATIVE)
POSITIVE_OUTCOME_WORDS = _word_list("positive_outcome_words", _DEFAULT_POSITIVE_OUTCOME)
POSITIVE_EVENT_TYPES = _word_list("positive_event_types", _DEFAULT_EVENT_TYPES)
GATE_NAMES = _word_list("verification_gate_names", _DEFAULT_GATE_NAMES)
MANIFEST_PATH = ".pps/verify-manifest.txt"
RUN_RECORD_PATH = ".pps/verify-run.json"


def die(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(2)


def read_schema():
    with open(SCHEMA_PATH, encoding="utf-8") as fh:
        return json.load(fh)


def word_hit(text, words):
    lowered = text.lower()
    for w in words:
        if w in lowered:
            return w
    return None


def git(root, *args):
    try:
        proc = subprocess.run(
            ["git", "-C", root] + list(args),
            capture_output=True, text=True)
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except FileNotFoundError:
        return 127, "", "git not found"


def safe_resolve(root, rel):
    """Resolve rel inside root; return None on escape or absolute input."""
    rel = rel.replace("\\", "/")
    if rel.startswith("/") or re.match(r"^[A-Za-z]:", rel):
        return None
    candidate = os.path.realpath(os.path.join(root, rel))
    root_real = os.path.realpath(root)
    if not (candidate == root_real or candidate.startswith(root_real + os.sep)):
        return None
    return candidate


def parse_manifest(root):
    """Return list of dicts; skip comments/blanks; columns are TAB-separated."""
    path = os.path.join(root, MANIFEST_PATH)
    if not os.path.isfile(path):
        return None
    items = []
    with open(path, encoding="utf-8") as fh:
        for line_no, raw in enumerate(fh, 1):
            line = raw.rstrip("\n").rstrip("\r")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 6:
                die("manifest line %d has %d columns, need >= 6" % (line_no, len(parts)))
            items.append({
                "check_id": parts[0].strip(),
                "platform": parts[1].strip(),
                "cwd": parts[2].strip() or ".",
                "timeout_s": parts[3].strip(),
                "expected_exit": parts[4].strip(),
                "command": parts[5].strip(),
                "note": parts[6].strip() if len(parts) > 6 else "",
            })
    return items


def load_run_record(root):
    path = os.path.join(root, RUN_RECORD_PATH)
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except ValueError:
        return None


def run_item_state(record, check_id):
    if not record or record.get("schema_version") != 1:
        return "missing"
    for item in record.get("items", []):
        if item.get("id") == check_id:
            return "ok" if item.get("ok") else "fail"
    return "missing"


# ---------------------------------------------------------------- subcommands

def cmd_schema_lookup(dotted):
    schema = read_schema()
    node = schema
    for part in dotted.split("."):
        if isinstance(node, dict) and part in node:
            node = node[part]
        else:
            die("schema path not found: %s" % dotted)
    if isinstance(node, list):
        print("\n".join(str(x) for x in node))
    elif isinstance(node, bool):
        print("true" if node else "false")
    else:
        print(str(node))


def cmd_role_allows(role, relation):
    schema = read_schema()
    allowed = schema["role_relation_allowed"].get(role, [])
    print("true" if relation in allowed else "false")


def cmd_run_ok(root, check_id):
    record = load_run_record(root)
    state = run_item_state(record, check_id)
    if state == "missing":
        print("missing")
    else:
        item = next((i for i in record["items"] if i.get("id") == check_id), None)
        print("%s\t%s" % (state, item.get("exit_code", "") if item else ""))


SEG_SEP_RE = re.compile(r"[;&|(\n]")
SEG_CALL_RE = re.compile(
    r"^(?:bash|sh|zsh)(?:\s+[-\w]+)*\s*[\"']?$"
    r"|^(?:pwsh|powershell)(?:\s+[-\w]+)*\s*(?:-File\s*)?[\"']?$"
    r"|^(?:python3?|node|npm|npx|deno|ruby|perl)(?:\s+[-\w]+)*\s*[\"']?$"
    r"|^(?:source|\.)\s*[\"']?$")
BARE_PATH_PREFIX_RE = re.compile(r"^[./\\]*$")
INTERP_QUOTE_RE = re.compile(
    r"(?:bash|sh|zsh|pwsh|powershell|python3?|node|npm|npx|deno|ruby|perl)"
    r"(?:\s+[-\w]+)*\s+[\"']$"
    r"|(?:source|\.)\s+[\"']$"
    r"|&\s*[\"']$")
EVAL_FLAG_RE = re.compile(r"(?<![\w])-(?:c|Command)\b")


def looks_like_call(before, token):
    """The token is called, not printed or mentioned.

    A token counts as a call only when, since the last statement separator,
    it sits in the command position: nothing before it, an interpreter with
    flags (bash/pwsh -File/python...), the call operator, or a bare path
    prefix. `echo PATH` and `Write-Host PATH` put the token in an argument
    position and never count. Eval flags (`bash -c`, `-Command`) evaluate
    strings and never count either.
    """
    if EVAL_FLAG_RE.search(before):
        return False
    singles = before.count("'")
    doubles = before.count('"')
    if (singles % 2 == 1 or doubles % 2 == 1) and not INTERP_QUOTE_RE.search(before):
        return False
    segment = SEG_SEP_RE.split(before)[-1].strip()
    if not segment:
        return True
    if segment.endswith("="):
        return False
    if BARE_PATH_PREFIX_RE.match(segment):
        return True
    return bool(SEG_CALL_RE.match(segment))


def cmd_run_has_path(root, path_token):
    """Does any executed item's command reference the path AS A CALL?
    ok/missing/fail. A quoted string or an echo of the path is not a call."""
    record = load_run_record(root)
    if not record or record.get("schema_version") != 1:
        print("missing")
        return
    for item in record.get("items", []):
        if not item.get("ok"):
            continue
        command = item.get("command", "")
        idx = 0
        while True:
            i = command.find(path_token, idx)
            if i < 0:
                break
            before = command[:i]
            if looks_like_call(before, path_token):
                print("ok")
                return
            idx = i + 1
    print("fail")


def cmd_resolve_commit(root, sha):
    code, out, _ = git(root, "cat-file", "-t", sha + "^{commit}")
    if code == 0 and out == "commit":
        print("commit")
    else:
        print("not-commit")


def cmd_ancestor(root, base, result):
    base_ok = (git(root, "cat-file", "-t", base + "^{commit}")[0] == 0)
    result_ok = (git(root, "cat-file", "-t", result + "^{commit}")[0] == 0)
    if not (base_ok and result_ok):
        print("unresolvable")
        return
    code, _, _ = git(root, "merge-base", "--is-ancestor", base, result)
    print("ancestor" if code == 0 else "not-ancestor")


def cmd_tree_diff(root, base, result):
    _, base_tree, _ = git(root, "rev-parse", base + "^{tree}")
    _, result_tree, _ = git(root, "rev-parse", result + "^{tree}")
    if not base_tree or not result_tree:
        print("unresolvable")
        return
    print("same" if base_tree == result_tree else "different")


def cmd_in_commit(root, commit, relpath):
    if relpath.startswith("/") or ".." in relpath.split("/"):
        print("invalid-path")
        return
    code, _, _ = git(root, "cat-file", "-e", "%s:%s" % (commit, relpath))
    print("present" if code == 0 else "absent")


def cmd_verification_parse(root, verification, merge_id):
    """Verdict tokens: ok | fail:<reason>."""
    text = verification.strip()
    if not text or text.lower() == "none":
        print("fail:empty")
        return

    neg = word_hit(text, NEGATIVE_WORDS)
    if neg:
        print("fail:negative-word-%s" % neg)
        return

    # Typed form 1: gate_result: <check id>
    m = re.match(r"^gate_result\s*:\s*(\S+)", text)
    if m:
        record = load_run_record(root)
        state = run_item_state(record, m.group(1))
        if state == "ok":
            print("ok")
        else:
            print("fail:gate-result-%s" % state)
        return

    # Typed form 2: file_evidence: <rel path> [@<sha256>]
    m = re.match(r"^file_evidence\s*:\s*(\S+)", text)
    if m:
        target = m.group(1)
        resolved = safe_resolve(root, target)
        if resolved is None:
            print("fail:path-escape")
        elif not os.path.isfile(resolved):
            print("fail:file-missing")
        else:
            print("ok")
        return

    # Typed form 3: event: <mergeId>  or  event: <date>:<mergeId>
    m = re.match(r"^event\s*:\s*(\S+?)\s*$", text)
    if m:
        token = m.group(1)
        if ":" in token:
            date_part, merge_part = token.split(":", 1)
        else:
            date_part, merge_part = None, token
        events_path = os.path.join(root, "EVENTS.md")
        if not os.path.isfile(events_path):
            print("fail:no-events")
            return
        with open(events_path, encoding="utf-8") as fh:
            lines = fh.readlines()
        for line in lines:
            if merge_part not in line:
                continue
            if date_part and date_part not in line:
                continue
            positive = word_hit(line, POSITIVE_EVENT_TYPES)
            negative = word_hit(line, NEGATIVE_WORDS)
            if positive and not negative:
                print("ok")
                return
        print("fail:event-not-evidence")
        return

    # Legacy form: <gate> <outcome> — outcome must be positive, never
    # fail/failed. (The 0.4.9 parser accepted fail/failed; this is the fix.)
    gate_hit = word_hit(text, GATE_NAMES)
    if gate_hit:
        outcome = word_hit(text, POSITIVE_OUTCOME_WORDS)
        if outcome:
            print("ok")
        else:
            print("fail:no-positive-outcome")
        return

    # Legacy form: an existing docs/ or .pps/ evidence path (regular file).
    m = re.search(r"(docs/|\.pps/)\S+", text)
    if m:
        resolved = safe_resolve(root, m.group(0))
        if resolved is None:
            print("fail:path-escape")
        elif not os.path.isfile(resolved):
            print("fail:file-missing")
        else:
            print("ok")
        return

    print("fail:unresolvable")


def cmd_manifest_has(root, check_id):
    items = parse_manifest(root)
    if items is None:
        print("missing")
        return
    for it in items:
        if it["check_id"] == check_id:
            print("ok")
            return
    print("fail")


def cmd_event_positive(root, token):
    """Is there an EVENTS.md line that records the identity token (e.g. a
    PKG-* or MERGE-* id) in a positive, non-negated way? A line saying 'do
    not create this package' must not create the package."""
    events_path = os.path.join(root, "EVENTS.md")
    if not os.path.isfile(events_path):
        print("fail")
        return
    event_line = re.compile(r"^\s*-\s+\d{4}-\d{2}-\d{2}:")
    with open(events_path, encoding="utf-8") as fh:
        for line in fh:
            if ("[%s]" % token) not in line and token not in line:
                continue
            if not event_line.match(line):
                # an ID in a comment or heading proves nothing
                continue
            if word_hit(line, NEGATIVE_WORDS):
                continue
            print("ok")
            return
    print("fail")


def cmd_write_run(root, platform, tsv_path):
    """Generate .pps/verify-run.json from an executed-item TSV.

    Columns (TAB-separated, command must not contain TAB):
    id, platform, cwd, timeout_s, expected_exit, command, exit_code, ok,
    started_at, finished_at
    """
    import datetime
    items = []
    result = "pass"
    with open(tsv_path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n").rstrip("\r")
            if not line.strip():
                continue
            parts = line.split("\t")
            if len(parts) < 10:
                die("run tsv line malformed: %d columns" % len(parts))
            exit_code = parts[6].strip()
            ok = (parts[7].strip().lower() in ("true", "1", "yes"))
            if not ok:
                result = "fail"
            items.append({
                "id": parts[0].strip(),
                "platform": parts[1].strip(),
                "cwd": parts[2].strip() or ".",
                "timeout_s": parts[3].strip() or "0",
                "expected_exit": int(parts[4].strip()) if parts[4].strip().isdigit() else parts[4].strip(),
                "command": parts[5].strip(),
                "exit_code": int(exit_code) if exit_code.lstrip("-").isdigit() else exit_code,
                "ok": ok,
                "started_at": parts[8].strip(),
                "finished_at": parts[9].strip(),
            })
    if not items:
        die("run tsv has no items; refusing to write an empty run record")
    record = {
        "schema_version": 1,
        "gate": "verify_gate",
        "platform": platform,
        "started_at": items[0]["started_at"],
        "finished_at": items[-1]["finished_at"],
        "result": result,
        "items": items,
    }
    path = os.path.join(root, RUN_RECORD_PATH)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(record, fh, indent=2, sort_keys=True)
    print("ok" if result == "pass" else "fail")


def main():
    args = sys.argv[1:]
    if not args:
        die("usage: pps_evidence.py <subcommand> ...")
    sub = args[0]
    try:
        if sub == "schema-lookup":
            cmd_schema_lookup(args[1])
        elif sub == "role-allows":
            cmd_role_allows(args[1], args[2])
        elif sub == "run-ok":
            cmd_run_ok(args[1], args[2])
        elif sub == "run-has-path":
            cmd_run_has_path(args[1], args[2])
        elif sub == "resolve-commit":
            cmd_resolve_commit(args[1], args[2])
        elif sub == "ancestor":
            cmd_ancestor(args[1], args[2], args[3])
        elif sub == "tree-diff":
            cmd_tree_diff(args[1], args[2], args[3])
        elif sub == "in-commit":
            cmd_in_commit(args[1], args[2], args[3])
        elif sub == "verification-parse":
            cmd_verification_parse(args[1], args[2], args[3])
        elif sub == "manifest-has":
            cmd_manifest_has(args[1], args[2])
        elif sub == "event-positive":
            cmd_event_positive(args[1], args[2])
        elif sub == "write-run":
            cmd_write_run(args[1], args[2], args[3])
        else:
            die("unknown subcommand: %s" % sub)
    except Exception as exc:  # never leak tracebacks into gate output
        die("pps_evidence error: %s" % exc)


if __name__ == "__main__":
    main()
