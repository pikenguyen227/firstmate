#!/usr/bin/env python3
"""Quote repository branch-rule evidence; never choose a branch name.

Usage: fm-branch-convention.py <repo>

Each observed passage prints source=<file:line>, quote=<text>, and optional
operator=/pattern= lines. GitHub reads use gh-axi (read-only); an empty
list of rules is a successful read, while a failed call is reported as unreadable.
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


def axi_lines(*args):
    """Run gh-axi and return the lines of its api_response body, or None if unreadable.

    gh-axi re-encodes JSON objects into its own text format, so each read asks jq
    for plain lines instead. An empty body is a successful read of nothing.
    """
    try:
        result = subprocess.run(["gh-axi", "api", *args, "--full"],
                                text=True, capture_output=True, check=False, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    match = re.search(r"^\s*body:[ \t]*(.*)$", result.stdout, re.M)
    if not match:
        return None
    raw = match.group(1).strip()
    if raw.startswith('"'):
        try:
            raw = json.loads(raw)
        except ValueError:
            return None
    return raw.splitlines()


PROTECTION_JQ = ('.data.repository.branchProtectionRules | "more=\\(.pageInfo.hasNextPage)", '
                 '(.nodes[] | "rule=\\(.pattern|tojson)\\t\\(.blocksCreations)")')
SUMMARY_JQ = '.[] | "ruleset=\\(.id)\\t\\(.enforcement)\\t\\(.target)"'
DETAIL_JQ = ('(.conditions.ref_name // {}) as $r | "ref_include=\\($r.include // [] | tojson)", '
             '"ref_exclude=\\($r.exclude // [] | tojson)", '
             '(.rules // [] | .[] | select(.type=="branch_name_pattern" or .type=="creation") | "rule=\\(tojson)")')
PROTECTION_QUERY = ("query($owner:String!,$repo:String!){repository(owner:$owner,name:$repo)"
                    "{branchProtectionRules(first:100){nodes{pattern blocksCreations}"
                    "pageInfo{hasNextPage}}}}")


def axi_protection_rules(name):
    owner, repo = name.split("/", 1)
    lines = axi_lines("POST", "graphql", "--field", f"query={PROTECTION_QUERY}",
                      "--field", f"owner={owner}", "--field", f"repo={repo}",
                      "--jq", PROTECTION_JQ)
    if lines is None or not lines or lines[0] != "more=false":
        return [], True
    found = []
    for line in lines[1:]:
        match = re.fullmatch(r"rule=(\".*\")\t(true|false)", line)
        if not match:
            return [], True
        try:
            pattern = json.loads(match.group(1))
        except ValueError:
            return [], True
        found.append({"source": "GitHub classic branch protection",
                      "quote": f"pattern={pattern} blocksCreations={match.group(2)}"})
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
        naming_level = 0
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            stripped = line.strip()
            heading = re.match(r"^\s{0,3}(#{1,6})\s+(.+)", line)
            if heading:
                level = len(heading.group(1))
                if naming_level and level <= naming_level:
                    naming_level = 0
                if re.search(r"\bbranch(?:es|ing)?\b|\bgit workflow\b", heading.group(2), re.I):
                    naming_level = level
            content = heading.group(2).strip() if heading else stripped
            if not content or content == "---" or re.search(r"\bgit\s+checkout\s+-b\s+", content):
                continue
            shape = re.search(
                r"(?<![\w/])[A-Za-z][\w-]*/(?:(?:<[^>]+>|[A-Za-z0-9][\w.-]*)(?:/(?:<[^>]+>|[A-Za-z0-9][\w.-]*))*)?|<type>/<scope>",
                content,
            )
            directive = re.search(
                r"\bbranch(?:es|ing|\s+names?|\s+naming|\s+prefix|\s+pattern|\s+format)?\b.{0,60}(?:\b(?:must|should|shall|start|begin|use|named|match|regex|pattern|format|prefix)\b|[:=])",
                content, re.I,
            )
            contextual = bool(shape and naming_level and "<" in shape.group() and
                              (re.fullmatch(r"\s*(?:[-*]\s*)?`?", content[:shape.start()]) or content.lstrip().startswith("|")))
            use_shape = bool(shape and "<" in shape.group() and
                             re.search(r"\buse\s+[`\"']?" + re.escape(shape.group()), content, re.I))
            regex_rule = bool(re.search(r"\bregex\s*[:=]\s*`?\S+", content, re.I) and
                              (directive or naming_level))
            if not ((shape and (directive or contextual or use_shape)) or regex_rule):
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
    summaries = axi_lines(f"/repos/{name}/rulesets?includes_parents=true", "--jq", SUMMARY_JQ)
    if summaries is None:
        return [], True
    found = []
    unavailable = False
    for line in summaries:
        match = re.fullmatch(r"ruleset=(\d+)\t(\S*)\t(\S*)", line)
        if not match:
            unavailable = True
            continue
        rule_id, enforcement, target = match.groups()
        if enforcement != "active" or target != "branch":
            continue
        detail = axi_lines(f"/repos/{name}/rulesets/{rule_id}", "--jq", DETAIL_JQ)
        if detail is None:
            unavailable = True
            continue
        source = f"GitHub ruleset {rule_id}"
        includes = excludes = []
        for entry in detail:
            key, _, value = entry.partition("=")
            try:
                parsed = json.loads(value)
            except ValueError:
                unavailable = True
                continue
            if key == "ref_include" and isinstance(parsed, list):
                includes = parsed
            elif key == "ref_exclude" and isinstance(parsed, list):
                excludes = parsed
        if includes or excludes:
            found.append({"source": source, "quote": f"ref_name include={includes} exclude={excludes}"})
        for entry in detail:
            key, _, value = entry.partition("=")
            if key != "rule":
                continue
            try:
                rule = json.loads(value)
            except ValueError:
                continue
            if not isinstance(rule, dict):
                continue
            if rule.get("type") == "creation":
                found.append({"source": source, "quote": "creation restriction"})
                continue
            params = rule.get("parameters") or {}
            if not isinstance(params, dict):
                params = {}
            item = {"source": source, "quote": f"branch_name_pattern {json.dumps(params, sort_keys=True)}"}
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
        print("source=GitHub branch settings\nquote=branch settings could not be read\n")
    for item in docs + rulesets + protection:
        print(f"source={item['source']}\nquote={item['quote']}")
        if "pattern" in item:
            print(f"operator={item['operator']}\npattern={item['pattern']}")
        print()


if __name__ == "__main__":
    main()
