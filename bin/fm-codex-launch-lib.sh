# shellcheck shell=bash
# Firstmate-owned Codex launch profile: the one owner of the values every
# canonical Codex launch carries beyond its resolved profile.
# Sourced by bin/fm-spawn.sh (crewmate, scout, and secondmate launches) and by
# bin/fm-strategy.sh (which prints the matching flags for a Codex primary, whose
# launcher lives outside this repository).
#
# Fallback profile: a canonical Codex launch always names its model and effort.
# When nothing resolved them - no dispatch profile, no config/secondmate-harness
# token, no --model/--effort, or the literal "default" - fm-spawn uses these
# values instead of letting Codex fall back to the operator's ~/.codex/config.toml
# default, which may be a top-cost model at maximum reasoning effort. An explicit
# model or effort always wins; the fallback only fills an empty axis.
# shellcheck disable=SC2034 # Read by the sourcing caller.
FM_CODEX_FALLBACK_MODEL=gpt-6-sol
# shellcheck disable=SC2034 # Read by the sourcing caller.
FM_CODEX_FALLBACK_EFFORT=high
#
# Project-doc budget: Codex loads only the first 32 KiB of a repository's
# AGENTS.md chain by default (project_doc_max_bytes = 32768), and Firstmate's own
# AGENTS.md is larger, so a Codex agent in this repository would otherwise run on
# a contract cut off mid-file. Every canonical Codex launch raises the budget
# per launch with -c project_doc_max_bytes=<value>, without touching the
# operator's Codex config. This is a stopgap until AGENTS.md fits under 32 KiB;
# the override is then removed.
# shellcheck disable=SC2034 # Read by the sourcing caller.
FM_CODEX_PROJECT_DOC_MAX_BYTES=131072
