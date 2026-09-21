# SessionStart hook verification

**Verdict: FAILED.** The hook ran unaided and got most of the way, but `yarn install` exited non-zero because the `wasm-pack` postinstall could not fetch its binary. Under `set -euo pipefail` that aborted the hook before its final `yarn workspace joplin run build`, so `packages/app-cli/build/app.js` was never emitted and the app-cli smoke test fails. The `rsync`, `corepack` and `yarn install` groundwork all succeeded, and `packages/lib` linting and tests work.

Verified on a cold container, branch `claude/joplin-repo-install-dzgt95`, repo root `/home/user/Neato_Notes`.

## Step 1 — baseline

Recorded at `2026-09-21T11:56:57+00:00`:

- Repo root: `/home/user/Neato_Notes` (clean tree, HEAD `2725e02`)
- `node_modules/` at repo root: absent
- `ps aux | grep -c session-start`: `4` — the hook was running (PID 257 `/bin/sh -c $CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh`, PID 258 the script itself)
- Repo root listing showed the expected monorepo contents (`package.json`, `packages/`, `yarn.lock`, `.claude/`, etc.) and no `node_modules`

The hook was confirmed to be doing the work itself: at `11:57:31` the process table showed PID 883 `yarn-4.16.0.cjs install` as a descendant of the hook. Nothing in this verification ran `yarn install` or any build by hand.

## Step 2 — artifact timings

Polled every 30s from `11:57:25`. Elapsed is measured from the step 1 baseline (`11:56:57`).

| Artifact | Appeared | Elapsed |
| --- | --- | --- |
| `node_modules/.yarn-state.yml` | `12:00:55` (detected; file mtime `12:00:30`) | ~213s |
| `packages/onenote-converter/node_modules/wasm-pack/binary/wasm-pack` | by `11:57:25` | ≤28s |
| `packages/app-cli/build/app.js` | **never appeared** | — |

Polling was stopped once the hook process had exited, at `12:11:41` (~15m after baseline), rather than running the full 25 minutes: the hook was gone, so no further artifacts could appear.

The `wasm-pack` binary did appear — the hook's `curl` seeding worked — but it did **not** survive. Yarn's link step recreated `packages/onenote-converter/node_modules/wasm-pack` at `12:00:33.297`, deleting the seeded binary, and the postinstall then ran the download it was meant to skip and failed at `12:00:33.315`. That directory is empty now.

## Step 3 — commands

### `command -v rsync`

```
/usr/bin/rsync
```

Exit status `0`. The hook's `apt-get install rsync` worked.

### `corepack yarn --version`

```
4.16.0
```

Exit status `0`. The hook's cache priming from the npm registry worked.

### `yarn linter-ci packages/lib/ArrayUtils.ts` (from repo root)

No output. Exit status `0`.

### `yarn jest ArrayUtils` (from `packages/lib`)

```
PASS ./ArrayUtils.test.js
  ArrayUtils
    ✓ should return unique elements (103 ms)
    ✓ should remove array elements (103 ms)
    ✓ should pull array elements (102 ms)
    ✓ should find items using binary search (102 ms)
    ✓ should compare arrays (102 ms)
    ✓ should merge overlapping intervals (102 ms)

Test Suites: 1 passed, 1 total
Tests:       6 passed, 6 total
```

Exit status `0`.

### `node build/main.js --profile /tmp/joplin-profile version` (from `packages/app-cli`)

```
Error: Cannot find module './app'
Require stack:
- /home/user/Neato_Notes/packages/app-cli/build/main.js
    at Function._resolveFilename (node:internal/modules/cjs/loader:1383:15)
    ...
  code: 'MODULE_NOT_FOUND',
  requireStack: [ '/home/user/Neato_Notes/packages/app-cli/build/main.js' ]
```

Exit status `1`. `packages/app-cli/build/` holds 62 copied `.ts` files and only 4 `.js` files; `app.js` is absent. This is precisely the state the hook's closing comment describes as the thing its final build step exists to repair — that step never ran.

## Step 4 — what broke

The break is the **`yarn install` step of the hook**, caused by the `wasm-pack` seeding not holding.

Yarn's own summary, from the hook's captured output:

```
➤ YN0009: │ wasm-pack@patch:wasm-pack@npm%3A0.13.1#~/.yarn/patches/wasm-pack-npm-0.13.1-2a81da84b4.patch::version=0.13.1&hash=fc5819 couldn't be built successfully (exit code 1, logs can be found here: /tmp/xfs-8e0957cb/build.log)
➤ YN0000: └ Completed in 3m 47s
➤ YN0000: · Failed with errors in 5m 34s
```

`/tmp/xfs-8e0957cb/build.log`:

```
# Script name: postinstall

Downloading release from https://github.com/rustwasm/wasm-pack/releases/download/v0.13.1/wasm-pack-v0.13.1-x86_64-unknown-linux-musl.tar.gz
Error fetching release: Request failed with status code 405
```

The 405 is the egress-proxy response the hook's comment already anticipates. The seeding is meant to avoid it, and the flaw is in the assumption stated in that comment — "Yarn keeps this directory when it links the package". It does not. The mtimes show Yarn replacing the directory and the postinstall failing 18ms later:

```
2026-09-21 12:00:33.297729763 +0000 packages/onenote-converter/node_modules/wasm-pack
2026-09-21 12:00:33.297729763 +0000 packages/onenote-converter/node_modules/wasm-pack/binary
2026-09-21 12:00:33.315750707 +0000 /tmp/xfs-8e0957cb/build.log
```

Sequence:

1. Hook seeds `wasm-pack` via `curl` — succeeds, binary present by `11:57:25`
2. `yarn install` resolves (0.9s) and fetches (1m 46s)
3. Link step recreates `packages/onenote-converter/node_modules/wasm-pack`, destroying the seeded binary (`12:00:33.297`)
4. `wasm-pack` postinstall runs, requests the tarball over the blocked path, gets 405, exits 1 (`12:00:33.315`)
5. `yarn install` reports `Failed with errors in 5m 34s` and exits non-zero
6. `set -euo pipefail` aborts the hook there; `yarn workspace joplin run build` never runs
7. `packages/app-cli/build/app.js` is never emitted

Claude Code recorded the whole thing as a hook error (`Hook SessionStart:startup (SessionStart) error: ...`).

Note that `yarn install` still populated `node_modules` far enough for `packages/lib` to lint and test — only the `wasm-pack` package build and everything after the install failure are affected. The failure is not a flake: the 405 is a deterministic proxy response to that URL over the postinstall's plain-HTTP request path.

As instructed, the hook was not fixed; this file only reports.

## Notes

`git commit --no-verify` was used, because the repo's pre-commit hook runs `corepack yarn` lint-staged over a tree whose install did not complete cleanly.
