#!/usr/bin/env python3
"""Quote repository branch-rule evidence; never choose a branch name.

Usage: fm-branch-convention.py <repo>

Each observed passage prints source=<file:line>, quote=<text>, and optional
operator=/pattern= lines. GitHub ruleset reads use gh-axi and remain read-only.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess


def git(repo, *args):
    result = subprocess.run(["git", "-C", str(repo), *args], text=True,
                            capture_output=True, check=False)
    return result.stdout.strip()


def github_repo(repo):
    remote = git(repo, "remote", "get-url", "origin")
    match = re.fullmatch(
        r"(?:https://github\.com/|git@github\.com:)([^/]+)/([^/]+?)(?:\.git)?",
        remote,
    )
    return "/".join(match.groups()) if match else None


def axi_read(path):
    try:
        result = subprocess.run(["gh-axi", "api", "GET", path, "--full"],
                                text=True, capture_output=True, check=False, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout if result.returncode == 0 else None


def axi_protection_rules(name):
    owner, repo = name.split("/", 1)
    query = ("query($owner:String!,$repo:String!){repository(owner:$owner,name:$repo)"
             "{branchProtectionRules(first:100){nodes{pattern blocksCreations}"
             "pageInfo{hasNextPage}}}}")
    try:
        result = subprocess.run(["gh-axi", "api", "graphql", "-f", f"query={query}",
                                 "-F", f"owner={owner}", "-F", f"repo={repo}"],
                                text=True, capture_output=True, check=False, timeout=20)
        body = json.loads(result.stdout) if result.returncode == 0 else None
        if not isinstance(body, dict) or body.get("errors"):
            return [], True
        rules = body["data"]["repository"]["branchProtectionRules"]
        nodes = rules["nodes"]
        if not isinstance(nodes, list) or rules["pageInfo"]["hasNextPage"]:
            return [], True
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError, TypeError):
        return [], True
    found = []
    for node in nodes:
        if not isinstance(node, dict) or not isinstance(node.get("pattern"), str) or not isinstance(node.get("blocksCreations"), bool):
            return [], True
        found.append({"source": "GitHub classic branch protection",
                      "quote": f"pattern={node['pattern']} blocksCreations={str(node['blocksCreations']).lower()}",
                      "naming": node["blocksCreations"]})
    return found, False


def markdown_paths(repo):
    names = {"AGENTS.md", "README.md", "BRANCHING.md", ".github/CONTRIBUTING.md"}
    names.update(str(p.relative_to(repo)) for p in repo.glob("CONTRIBUTING*")
                 if p.is_file() and p.suffix in {"", ".md"})
    names.update(str(p.relative_to(repo)) for p in (repo / "docs").rglob("*.md") if p.is_file())
    # Only tracked wiki material is part of a vault's committed knowledge.
    # The path shape excludes every raw/ subtree even if a local file exists.
    for name in git(repo, "ls-files", "--", "_vaults").splitlines():
        parts = Path(name).parts
        if len(parts) >= 4 and parts[0] == "_vaults" and parts[2] == "wiki" and name.endswith(".md"):
            names.add(name)
    return [repo / name for name in sorted(names, key=lambda name: ("_vaults/workspace/wiki/" not in name, name))]


def doc_evidence(repo):
    found = []
    for path in markdown_paths(repo):
        if not path.is_file():
            continue
        workflow_level = 0
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            if line.strip() == "---":
                workflow_level = 0
                continue
            heading = re.match(r"^\s{0,3}(#{1,6})\s+(.+)", line)
            if heading:
                level = len(heading.group(1))
                if workflow_level and level <= workflow_level:
                    workflow_level = 0
                if re.search(r"\bbranch\w*\b|\bgit workflow\b", heading.group(2), re.I):
                    workflow_level = level
                continue
            stripped = line.strip()
            if not stripped or re.search(r"\bgit\s+checkout\s+-b\s+", line):
                continue
            pattern_line = re.search(r"\bbranch\w*\b.{0,50}\b(?:prefix|pattern|format|must\s+(?:start|begin)|should\s+(?:start|begin))\b", line, re.I)
            label_line = re.search(r"\bbranch(?:es|ing| names| name| naming| rule)?\s*[:=]\s*\S+", line, re.I)
            template = re.search(r"\b[A-Za-z][A-Za-z0-9_-]*/[^\s`|]*<[^>]+>", line)
            if not (workflow_level or pattern_line or label_line or template):
                continue
            item = {"source": f"{path.relative_to(repo)}:{number}", "quote": stripped}
            prefix = re.search(
                r"\bbranch(?:es| names| naming)?\s*(?:prefix\s*[:=]?|(?:must|should)\s+(?:start|begin)\s+with\s+)[`\"']?([A-Za-z][A-Za-z0-9_-]*/)",
                line, re.I,
            )
            if prefix and not re.search(r"<[^>]+>", line):
                item.update(operator="starts_with", pattern=prefix.group(1))
            found.append(item)
    return found


def ruleset_evidence(repo):
    name = github_repo(repo)
    if not name:
        return [], False
    body = axi_read(f"/repos/{name}/rulesets?includes_parents=true")
    if body is None:
        return [], True
    try:
        summaries = json.loads(body)
    except ValueError:
        return [], True
    if not isinstance(summaries, list):
        return [], True
    found = []
    unavailable = False
    for entry in summaries:
        if not isinstance(entry, dict) or entry.get("enforcement") != "active" or entry.get("target") != "branch":
            continue
        rule_id = entry.get("id")
        if not isinstance(rule_id, int):
            unavailable = True
            continue
        body = axi_read(f"/repos/{name}/rulesets/{rule_id}")
        try:
            detail = json.loads(body) if body is not None else None
        except ValueError:
            detail = None
        if not isinstance(detail, dict):
            unavailable = True
            continue
        source = f"GitHub ruleset {rule_id}"
        conditions = detail.get("conditions")
        if not isinstance(conditions, dict):
            conditions = {}
        ref_name = conditions.get("ref_name") or {}
        if not isinstance(ref_name, dict):
            ref_name = {}
        includes = ref_name.get("include") or []
        excludes = ref_name.get("exclude") or []
        if includes or excludes:
            item = {"source": source, "quote": f"ref_name include={includes} exclude={excludes}"}
            found.append(item)
        for rule in detail.get("rules") or []:
            if not isinstance(rule, dict) or rule.get("type") not in {"branch_name_pattern", "creation"}:
                continue
            if rule["type"] == "creation":
                found.append({"source": source, "quote": "creation restriction", "naming": True})
                continue
            params = rule.get("parameters") or {}
            if not isinstance(params, dict):
                params = {}
            item = {"source": source, "quote": f"branch_name_pattern {json.dumps(params, sort_keys=True)}", "naming": True}
            if isinstance(params.get("pattern"), str) and params.get("operator") in {"regex", "starts_with", "fnmatch"} and not params.get("negate"):
                item.update(operator=params["operator"], pattern=params["pattern"])
            found.append(item)
    return found, unavailable


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo", type=Path)
    args = parser.parse_args()
    repo = args.repo.resolve()
    if not (repo / ".git").exists():
        parser.error("repository has no .git")
    docs = doc_evidence(repo)
    rulesets, unavailable = ruleset_evidence(repo)
    github_name = github_repo(repo)
    protection, protection_unavailable = axi_protection_rules(github_name) if github_name else ([], False)
    unavailable = unavailable or protection_unavailable
    if unavailable:
        print("status=unavailable\nsource=GitHub branch settings\nquote=branch settings could not be read")
    for item in docs + rulesets + protection:
        print(f"source={item['source']}\nquote={item['quote']}")
        if "pattern" in item:
            print(f"operator={item['operator']}\npattern={item['pattern']}")
        print()
    if not docs and not any(item.get("naming") for item in rulesets + protection) and not unavailable:
        print("status=no-rule")


if __name__ == "__main__":
    main()
