# tests/

Three categories of tests, each with a different cost/benefit tradeoff.

## Unit tests (`tests/test_*.sh`)

Fast, hermetic, no iTerm2 required for most of them.

| File                          | What it covers                                                                                                                 |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `test_time_parsing.sh`        | `parse_in`, `parse_at`, DST gap detection, polling predicates, human-readable delta formatting                                 |
| `test_state_file.sh`          | State file JSON construction, shell-injection round-trip safety, status marking, stale detection logic                        |
| `test_preflight_dry_run.sh`   | Basic dry-run path + resume-id shell injection defense                                                                         |
| `test_caffeinate_reexec.sh`   | **Regression**: re-exec must run before pre-flights, must be skipped for dry-run, must have CL_UNDER_CAFFEINATE guard         |
| `test_prompt_sources.sh`      | The documented prompt-passing patterns: literal, env var, file substitution, multi-line rejection, non-printable rejection    |
| `test_failure_modes.sh`       | **Chaos**: every pre-flight check is exercised by deliberately breaking its precondition and asserting the error message     |
| `test_tail_slicing.sh`        | `CL_OSA_CONTENTS_TAIL` env var behaviour — full contents, sliced contents, hash stability                                     |

Run all unit tests:

```sh
bash tests/run-all.sh
```

Some tests (`test_caffeinate_reexec`, `test_prompt_sources`, `test_failure_modes`, `test_tail_slicing`) require `TERM_PROGRAM=iTerm.app` — they self-skip cleanly if run outside iTerm2.

## Integration tests (`tests/integration/test_*.sh`)

Slower, require iTerm2 to be running, touch real AppleScript.

| File              | What it covers                                                                                                                      |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `test_osa.sh`     | Every `osa_*` wrapper in `lib/osa.sh` against the **current live iTerm2 session**. Validates UUID resolution, contents, write, etc. |

Run integration tests:

```sh
bash tests/integration/run-integration.sh
```

## Fixtures (`tests/fixtures/`)

| File                | Purpose                                                                                                                                                         |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fake-claude`       | A bash stand-in for the real `claude` binary. Prints a splash, waits, prints `❯`, reads one line from stdin, writes it to `$CL_FAKE_CLAUDE_OUTPUT`, exits.      |

## What we deliberately don't test

- **No mocking of `osascript`**. The whole point of the tool is that iTerm2 scripting works. A mock would tell you nothing.
- **No mocking of `caffeinate`**. OS primitive, trust it.
- **No mocking of the iTerm2 session UUID resolution**. Same reasoning.

## What we don't YET test (but should)

- **Secure Input engaged at T-0**. Would need to script 1Password or the lock screen. Flaky.
- **`write_failed` tombstone class**. Hard to trigger without revoking Automation permission mid-test, which is a privilege issue.

## Running the e2e test (`test_e2e_fake_claude.sh`)

`tests/integration/test_e2e_fake_claude.sh` exercises the full arm→fire→deliver cycle against the `fake-claude` fixture. **It must be run from a bare iTerm2 shell, not from inside a running Claude Code session** — auto-skips in the latter case via `$CLAUDECODE` / `$CLAUDE_CODE_ENTRYPOINT` detection. The reason: when the test runs inside an agent session, the agent's TUI already owns the pane's pty; `claude-later`'s backgrounded `exec fake-claude` then inherits the agent subshell's pipe rather than the pane, so fake-claude's stdout never reaches the pane and the helper's readiness probe never finds the `❯` glyph.

To run manually: open a fresh iTerm2 tab, `cd` to the repo, then `bash tests/integration/test_e2e_fake_claude.sh`. It takes ~10 seconds.

## Writing new tests

The test harness in `test-utils.sh` is deliberately tiny — just a few assert helpers. Don't build a framework. When adding a test:

1. If it can be expressed as "given this input, assert this output" with no iTerm2 — unit test.
2. If it needs iTerm2 but only for read-only checks — integration test.
3. If it needs to actually fire `claude-later` and observe a live pane — don't write it until the fake-claude blocker is resolved, or write it as a manual-only test clearly marked `MANUAL:` in the filename.
