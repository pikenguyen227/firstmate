#!/usr/bin/env python3
"""Propose a ship branch from a repository's documented or observed convention.

Usage: fm-branch-convention.py <repo> [--task-id ID --title TITLE] [--template RULE]

Output is key=value lines: kind (prefix|rule), value, source, and branch when
a task id is supplied. An unresolved rule reports status=needs-decision instead
of a branch. An empty result means no sufficiently clear convention.
This never writes a repository or its registry; project add and task intake own
the decision to record or use a proposal.
"""

import argparse
import base64
from collections import Counter
import json
from pathlib import Path
import re
import subprocess
import sys


TYPES = ("feature", "feat", "bugfix", "hotfix", "fix", "chore")
DEFAULTS = {"main", "master", "develop", "development", "dev", "release", "beta", "staging"}


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], text=True,
                          capture_output=True, check=False).stdout.strip()


def github_repo(repo):
    remote = git(repo, "remote", "get-url", "origin")
    match = re.fullmatch(r"(?:https://github\.com/|git@github\.com:)([^/]+)/([^/]+?)(?:\.git)?", remote)
    return "/".join(match.groups()) if match else None


def axi_read(path):
    try:
        result = subprocess.run(["gh-axi", "api", "GET", path, "--full"],
                                text=True, capture_output=True, check=False, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout if result.returncode == 0 else ""


def rulesets(repo):
    name = github_repo(repo)
    if not name:
        return []
    summaries = axi_read(f"/repos/{name}/rulesets?includes_parents=true")
    found = []
    for entry in re.split(r"(?=^  - id:)", summaries, flags=re.MULTILINE):
        number = re.search(r"^  - id:\s*(\d+)", entry, re.MULTILINE)
        if not number or not re.search(r"^\s*enforcement:\s*active$", entry, re.MULTILINE):
            continue
        if not re.search(r"^\s*target:\s*branch$", entry, re.MULTILINE):
            continue
        detail = axi_read(f"/repos/{name}/rulesets/{number.group(1)}")
        # gh-axi presents an API object as labeled text, not raw JSON.
        # Read only the branch-name rule fields and leave an unknown shape alone.
        match = re.search(r'^\s*pattern:\s*(".*")$', detail, re.MULTILINE)
        if "type: branch_name_pattern" not in detail or not match:
            continue
        try:
            pattern = json.loads(match.group(1))
        except ValueError:
            continue
        found.append({"id": int(number.group(1)), "rules": [{"type": "branch_name_pattern",
                      "parameters": {"operator": "regex", "pattern": pattern,
                                     "negate": bool(re.search(r"^\s*negate:\s*true$", detail, re.MULTILINE))}}]})
    return found


def from_docs(repo):
    paths = [repo / name for name in ("AGENTS.md", "CONTRIBUTING.md", "README.md", "BRANCHING.md", ".github/CONTRIBUTING.md")]
    paths += list((repo / "docs").glob("*branch*.md")) if (repo / "docs").is_dir() else []
    for path in paths:
        if not path.is_file():
            continue
        for line in path.read_text(errors="replace").splitlines():
            if not re.search(r"branch", line, re.I):
                continue
            # Generic directions to discover conventions carry no name to use.
            match = re.search(r"branch(?:es| naming| name)?\s*(?:prefix|must (?:start|begin) with|should (?:start|begin) with)\s*[:=]?\s*[`\"']?([A-Za-z][A-Za-z0-9_-]*/)", line, re.I)
            if match:
                return "prefix", match.group(1), str(path.relative_to(repo))
            for template in ("type/ticket-description", "ticket-description"):
                if template in re.sub(r"[<>]", "", line.lower()):
                    return "rule", template, str(path.relative_to(repo))
    return None


def from_rulesets(repo):
    for ruleset in rulesets(repo):
        for rule in ruleset.get("rules", []):
            if rule.get("type") != "branch_name_pattern":
                continue
            params = rule.get("parameters", {})
            if params.get("negate") or params.get("operator") != "regex":
                continue
            pattern = params.get("pattern", "")
            if not isinstance(pattern, str):
                continue
            # A constrained type/slug regex is a naming rule. A protection
            # pattern for main or release branches alone is not one.
            head = re.match(r"^\^(?:\((?P<choices>[a-z|]+)\)|(?P<single>[a-z]+))(?:/|\\/)(?:.+)\$$", pattern)
            if head and all(kind in TYPES for kind in (head.group("choices") or head.group("single")).split("|")):
                source = f"GitHub ruleset {ruleset.get('id', ruleset.get('name', 'unknown'))}"
                encoded = base64.urlsafe_b64encode(pattern.encode()).decode().rstrip("=")
                return "rule", "regex64:" + encoded, source
    return None


def from_history(repo):
    names = git(repo, "for-each-ref", "--count=120", "--sort=-committerdate",
                "--format=%(refname:short)", "refs/remotes/origin").splitlines()
    prefixes = []
    multi_segment = False
    for name in names:
        name = name.removeprefix("origin/")
        if "/" not in name or name in DEFAULTS:
            continue
        if name.count("/") != 1:
            multi_segment = True
            continue
        prefix = name.split("/", 1)[0]
        if prefix in ("fm", "dependabot", "renovate", "release"):
            continue
        prefixes.append(prefix)
    if len(prefixes) < 4:
        if multi_segment:
            print("note: multi-segment branch history has no complete prefix proposal", file=sys.stderr)
        return None
    counts = Counter(prefixes)
    prefix, count = counts.most_common(1)[0]
    if count * 10 < len(prefixes) * 7:
        if multi_segment:
            print("note: multi-segment branch history has no complete prefix proposal", file=sys.stderr)
        return None
    return "prefix", prefix + "/", f"origin history ({count}/{len(prefixes)} recent topic branches)"


def branch_for(kind, value, task_id, title):
    if kind == "prefix":
        return value + task_id
    lower = title.lower()
    is_fix = bool(re.search(r"\b(bug|fix|broken|regression)\b", lower))
    ticket = re.search(r"\b[A-Z][A-Z0-9]+-\d+\b", title + " " + task_id)
    description = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")[:60].strip("-") or "change"
    if value in ("type/ticket-description", "ticket-description"):
        branch_type = "bugfix" if is_fix else "feature"
        proposed = f"{branch_type}/{description}-{task_id}" if value.startswith("type/") else f"{description}-{task_id}"
        if not ticket:
            return None, proposed, value
        tail = f"{ticket.group()}-{description}"
        branch = f"{branch_type}/{tail}" if value.startswith("type/") else tail
        return branch, branch, value
    if not value.startswith("regex64:"):
        return None, f"feature/{description}-{task_id}", value
    try:
        encoded = value.removeprefix("regex64:")
        pattern = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)).decode()
        head = re.match(r"^\^(?:\((?P<choices>[a-z|]+)\)|(?P<single>[a-z]+))(?:/|\\/)(?:.+)\$$", pattern)
        choices = (head.group("choices") or head.group("single")).split("|") if head else []
        if not choices or any(choice not in TYPES for choice in choices):
            raise ValueError("unsupported rule")
        preferred = ("fix", "bugfix", "hotfix", "feat", "feature", "chore") if is_fix else ("feat", "feature", "chore", "fix", "bugfix", "hotfix")
        branch_type = next(choice for choice in preferred if choice in choices)
        tails = ([f"{ticket.group()}-{description}", f"{ticket.group().lower()}-{description}"] if ticket else []) + [f"{description}-{task_id}"]
        for tail in tails:
            branch = f"{branch_type}/{tail}"
            if re.fullmatch(pattern, branch):
                return branch, branch, pattern
        return None, f"{branch_type}/{tails[0]}", pattern
    except (ValueError, UnicodeError, re.error, StopIteration):
        return None, f"feature/{description}-{task_id}", value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo", type=Path)
    parser.add_argument("--task-id")
    parser.add_argument("--title", default="")
    parser.add_argument("--template")
    args = parser.parse_args()
    repo = args.repo.resolve()
    if not (repo / ".git").exists():
        parser.error("repository has no .git")
    result = (("rule", args.template, "registered branch rule") if args.template else
              from_docs(repo) or from_rulesets(repo) or from_history(repo))
    if not result:
        return
    kind, value, source = result
    print(f"kind={kind}\nvalue={value}\nsource={source}")
    if args.task_id:
        if kind == "prefix":
            branch = branch_for(kind, value, args.task_id, args.title)
            proposed, rule = branch, value
        else:
            branch, proposed, rule = branch_for(kind, value, args.task_id, args.title)
        if branch and subprocess.run(["git", "check-ref-format", "--branch", branch], capture_output=True).returncode == 0:
            print(f"branch={branch}")
        else:
            print(f"status=needs-decision\nrule={rule}\nproposed-branch={proposed}")


if __name__ == "__main__":
    main()
