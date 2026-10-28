#!/usr/bin/env python3
"""Propose only a simple, validated repository ship-branch prefix.

Usage: fm-branch-convention.py <repo> [--task-id ID --title TITLE]

Print kind=prefix, value, source, and branch for one unambiguous prefix. Print
status=needs-decision with the observed rule when evidence is complex or
conflicting. Print nothing when there is no evidence of a repository rule.
"""

import argparse
import fnmatch
import json
from pathlib import Path
import re
import subprocess


DOCS = ("AGENTS.md", "CONTRIBUTING.md", "README.md", "BRANCHING.md", ".github/CONTRIBUTING.md")
SKIP_BRANCHES = {"main", "master", "develop", "development", "dev", "release", "beta", "staging"}
SKIP_PREFIXES = {"fm", "dependabot", "renovate"}


def git(repo, *args):
    result = subprocess.run(["git", "-C", str(repo), *args], text=True,
                            capture_output=True, check=False)
    return result.stdout.strip()


def github_repo(repo):
    remote = git(repo, "remote", "get-url", "origin")
    match = re.fullmatch(
        r"(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+)/([^/]+?)(?:\.git)?",
        remote,
    )
    return "/".join(match.groups()) if match else None


def axi_read(path):
    try:
        result = subprocess.run(["gh-axi", "api", "GET", path, "--full"],
                                text=True, capture_output=True, check=False, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout if result.returncode == 0 else ""


def doc_evidence(repo):
    paths = [repo / name for name in DOCS]
    if (repo / "docs").is_dir():
        paths.extend(sorted((repo / "docs").glob("*branch*.md")))
    vault_paths = []
    for name in git(repo, "ls-files", "--", "_vaults").splitlines():
        parts = Path(name).parts
        if len(parts) >= 4 and parts[0] == "_vaults" and parts[2] == "wiki" and name.endswith(".md"):
            vault_paths.append(repo / name)
    # A workspace context note is the natural entry point for a workspace-wide
    # Git rule. Search it before app-specific wiki notes when reporting evidence.
    paths = sorted(vault_paths, key=lambda path: ("/workspace/wiki/" not in str(path), str(path))) + paths
    found = []
    for path in paths:
        if not path.is_file():
            continue
        is_vault = "_vaults" in path.parts
        for line in path.read_text(errors="replace").splitlines():
            branch_context = "branch" in line.lower()
            # A vault may show concrete branch templates in a fenced Git
            # workflow example. Require a branch-family name at line start so
            # unrelated HTML components and type parameters are ignored.
            vault_template = is_vault and re.match(
                r"^\s*(?:[-*]\s*)?(?:`)?(?:feature|feat|fix|bugfix|hotfix)/[^\s`]*<[^>]+>",
                line, re.I,
            )
            if not branch_context and not vault_template:
                continue
            source = str(path.relative_to(repo))
            prefix = re.search(
                r"branch(?:es| naming| name)?\s*(?:prefix|must (?:start|begin) with|should (?:start|begin) with)\s*[:=]?\s*[`\"']?([A-Za-z][A-Za-z0-9_-]*/)",
                line, re.I,
            )
            if prefix:
                found.append(("prefix", prefix.group(1), source))
            elif vault_template or (branch_context and re.search(
                r"<ticket>|<type>|ticket-description|type/ticket-description|\b(?:feature|feat|fix|bugfix|hotfix)/[^\s`]*<[^>]+>",
                line, re.I,
            )):
                found.append(("complex", line.strip(), source))
    return found


def ruleset_evidence(repo):
    name = github_repo(repo)
    if not name:
        return []
    try:
        summaries = json.loads(axi_read(f"/repos/{name}/rulesets?includes_parents=true"))
    except ValueError:
        return []
    if not isinstance(summaries, list):
        return []
    found = []
    for entry in summaries:
        if not isinstance(entry, dict) or entry.get("enforcement") != "active":
            continue
        if entry.get("target") != "branch" or not isinstance(entry.get("id"), int):
            continue
        source = f"GitHub ruleset {entry['id']}"
        try:
            detail = json.loads(axi_read(f"/repos/{name}/rulesets/{entry['id']}"))
        except ValueError:
            found.append(("complex", "unreadable ruleset", source))
            continue
        if not isinstance(detail, dict):
            found.append(("complex", "unreadable ruleset", source))
            continue
        conditions = detail.get("conditions") or {}
        ref_name = conditions.get("ref_name") or {}
        includes = ref_name.get("include", [])
        excludes = ref_name.get("exclude", [])
        if excludes:
            found.append(("complex", f"ref exclusions: {excludes}", source))
        if len(includes) == 1:
            protected = re.fullmatch(r"(?:refs/heads/)?([A-Za-z][A-Za-z0-9_-]*)/\*", includes[0])
            if protected:
                found.append(("prefix", protected.group(1) + "/", source))
        elif len(includes) > 1:
            found.append(("complex", f"ref includes: {includes}", source))
        for rule in detail.get("rules") or []:
            if rule.get("type") != "branch_name_pattern":
                continue
            params = rule.get("parameters", {})
            pattern = params.get("pattern", "")
            operator = params.get("operator")
            if params.get("negate") or not isinstance(pattern, str):
                found.append(("complex", f"branch name pattern: {params}", source))
                continue
            if operator == "starts_with" and re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*/", pattern):
                found.append(("prefix", pattern, source, (operator, pattern)))
                continue
            if operator == "fnmatch" and re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*/\*", pattern):
                found.append(("prefix", pattern[:-1], source, (operator, pattern)))
                continue
            if operator != "regex":
                found.append(("complex", f"branch name pattern: {params}", source))
                continue
            try:
                re.compile(pattern)
            except re.error:
                found.append(("complex", "invalid branch name pattern", source))
                continue
            # Only a literal prefix followed by a conventional slug class is
            # inferred. Alternations, ticket groups, and unknown regex syntax
            # stay decisions for the coordinator.
            simple = re.fullmatch(r"\^([A-Za-z][A-Za-z0-9_-]*/|[A-Za-z][A-Za-z0-9_-]*\\/)(?:\[a-z0-9-\]\+|\[A-Za-z0-9-\]\+|\.\+)\$", pattern)
            if simple:
                found.append(("prefix", simple.group(1).replace("\\/", "/"), source, (operator, pattern)))
            else:
                found.append(("complex", pattern, source))
    return found


def history_evidence(repo):
    remote = git(repo, "for-each-ref", "--count=120", "--sort=-committerdate",
                 "--format=%(refname:short)", "refs/remotes/origin").splitlines()
    local = git(repo, "for-each-ref", "--count=120", "--sort=-committerdate",
                "--format=%(refname:short)", "refs/heads").splitlines()
    topics = []
    for name in remote + local:
        name = name.removeprefix("origin/")
        if name in SKIP_BRANCHES or "/" not in name:
            continue
        if name.split("/", 1)[0] in SKIP_PREFIXES:
            continue
        topics.append(name)
    return sorted(set(topics))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo", type=Path)
    parser.add_argument("--task-id")
    parser.add_argument("--title", default="")
    args = parser.parse_args()
    repo = args.repo.resolve()
    if not (repo / ".git").exists():
        parser.error("repository has no .git")
    documents = doc_evidence(repo)
    rulesets = ruleset_evidence(repo)
    evidence = documents + rulesets
    complex_rules = [item for item in evidence if item[0] == "complex"]
    prefixes = {item[1] for item in evidence if item[0] == "prefix"}
    topics = history_evidence(repo)
    if complex_rules or len(prefixes) > 1:
        observed = "; ".join(f"{item[2]}: {item[1]}" for item in evidence[:5])
        if len(evidence) > 5:
            observed += f"; ... ({len(evidence) - 5} more observations)"
        print(f"status=needs-decision\nrule={observed}\nproposed-branch=fm/{args.task_id or 'task-id'}")
        return
    if len(prefixes) == 1:
        prefix = next(iter(prefixes))
        branch = prefix + (args.task_id or "task-id")
        if args.task_id and subprocess.run(["git", "check-ref-format", "--branch", branch], capture_output=True).returncode:
            print(f"status=needs-decision\nrule={prefix}\nproposed-branch={branch}")
            return
        for item in rulesets:
            if item[0] == "prefix" and len(item) > 3:
                operator, pattern = item[3]
                valid = (re.fullmatch(pattern, branch) is not None if operator == "regex" else
                         branch.startswith(pattern) if operator == "starts_with" else
                         fnmatch.fnmatchcase(branch, pattern))
                if not valid:
                    print(f"status=needs-decision\nrule={pattern}\nproposed-branch={branch}")
                    return
        source = ", ".join(item[2] for item in evidence if item[0] == "prefix")
        print(f"kind=prefix\nvalue={prefix}\nsource={source}")
        if args.task_id:
            print(f"branch={branch}")
        return
    if topics:
        print(f"status=needs-decision\nrule=branch history: {', '.join(topics[:5])}\nproposed-branch=fm/{args.task_id or 'task-id'}")


if __name__ == "__main__":
    main()
