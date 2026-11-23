# Round-4 live OpenCode 2.3.2 lab (commit d00eb7e8)
Setup: @opencode/cli 2.3.2 in disposable dir; lab FM_HOME via bin/fm-lab-home.sh; primary = disposable clone of the gate commit (main checkout);
disposable HOME/XDG; local OpenAI-compatible mock (lab-mock-openai-endpoint.py, port 18764); TUI driven through lab-ptydrv.py (150x45 pty). tmux absent on host.

| Scenario | Result | Evidence |
|---|---|---|
| First launch, no --auto: no trust dialog | pass | r4-tui-first-launch-no-trust-dialog.txt |
| Session-start digest, session.created only | pass (one FIRSTMATE_OP session-start, model ran bin/fm-session-start.sh once) | r4-tui-session-start-digest.txt |
| Lock anchored by real fm-session-start.sh via OC2 shell tool | pass (lock = opencode.exe serve; opencode-pty daemon is its child) | r4-lock-anchor.txt |
| Watcher arm + actionable wake | pass (arm child of serve; reason=actionable-signal successor=started; signal: prompt in TUI) | r4-watch-cycle-exits.log, r4-tui-actionable-wake.txt |
| Pretool deny | pass (deny returned, sentinel absent) | r4-pretool-deny-model-view.txt, r4-tui-pretool-deny.txt |
| /exit + --continue resume | FAIL: same session id, no trust dialog, but lock still names dead pre-restart serve pid; no digest; watcher never re-arms; guard fires BLIND each turn | r4-resume-watcher-not-rearmed.txt, r4-tui-resume-*.txt |
| Turn-end follow-up (watcher missing) | pass (exactly one TURN WOULD END BLIND per user turn, no second follow-up) | r4-resume-watcher-not-rearmed.txt |
| Worker worktree stand-down | pass (no nudge, no follow-up, no watch lock, no watcher) | r4-worker-worktree-standdown.txt |
| Headless opencode run | pass (exit 0, no digest, no lingering serve/watcher) | r4-headless-run.txt |
| Claude / Codex anchors unchanged by pty exclusion | pass (claude binary / codex binary) | r4-claude-ancestry-anchor.txt, r4-codex-ancestry-anchor.txt |
