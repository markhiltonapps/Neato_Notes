# SessionStart hook verification — round 3

**Verdict: PASS.** On a cold container the hook ran to completion end to end, with no retry needed. All three install artifacts were produced, Claude Code recorded the hook as `success` (no hook error, no `YN0009`), and the linter, Jest and the built CLI all work from a fresh session.

Environment: commit `d253124` on `claude/joplin-repo-install-dzgt95`, container started 2026-09-21T12:55Z.

## Timeline

| Time (UTC) | Event |
| --- | --- |
| 12:55:13 | Claude Code spawns the SessionStart hook; it prints `{"async": true, "asyncTimeout": 1800000}` and backgrounds (spawn exit code 0, 55 ms) |
| 12:55:19 | Baseline observation: `node_modules/` does not exist; hook running as PID 185/186 |
| 12:55:45 | `rsync` installed via apt (`libpopt0` + `rsync 3.2.7-1ubuntu1.5`) |
| ~12:55:45 | `yarn install --mode=skip-build` starts |
| 12:57:45 | `node_modules/` appears |
| 12:59:01 | `node_modules/.yarn-state.yml` written — skip-build install done in 3m 31s |
| ~12:59:03 | `wasm-pack` binary seeded from the GitHub release tarball |
| ~12:59:05 | `corepack install` primes the Yarn 4.16.0 cache (`Adding yarn@4.16.0 to the cache...`) |
| 12:59:15 | Full `yarn install` starts; package build logs appear under `/tmp/xfs-*` (root `postinstall` gulp build at `/tmp/xfs-3da821a9/build.log`) |
| 13:01:18 | `packages/app-cli/build/app.js` written by the root postinstall |
| 13:01:22 | Full `yarn install` done in 2m 18s |
| 13:01:24 | `yarn workspace joplin run build` runs `prepareBuild` (82 ms) |
| 13:01:30 | Hook process exits |
| 13:01:38 | Claude Code marks the hook shell `completed` and logs `Hook SessionStart:startup (SessionStart) success` |

Total hook wall time: ~6m 17s.

## Artifacts

| Path | Present | mtime |
| --- | --- | --- |
| `node_modules/.yarn-state.yml` | yes | 2026-09-21 12:59:01 |
| `packages/onenote-converter/node_modules/wasm-pack/binary/wasm-pack` | yes | 2024-10-29 18:34:06 (mtime from the release tarball — the seeded binary, unmodified and not deleted by the link step) |
| `packages/app-cli/build/app.js` | yes | 2026-09-21 13:01:18 |

## Retries

None. The hook's captured stdout contains exactly two `➤ YN0000: · Yarn 4.16.0` banners, matching the two scripted installs (`--mode=skip-build`, then the full install). There is no third install run, so the 3-attempt `retry` wrapper never fired a second attempt. The Electron download that failed in round 2 succeeded on the first try this time.

Build logs: `/tmp/xfs-3da821a9/build.log` is Yarn's log for the root `postinstall` script (the gulp `build` task, which runs `buildParallel` across the workspaces). These per-package `build.log` files are created for every package with a build script and are not retry evidence. The link step reported `YN0007` ("must be built") for each such package, which is the normal first-build notice.

## Errors

- Claude Code hook error: **none**. The hook shell status went `backgrounded` → `completed`, and the response was logged as `success`.
- `YN0009` (Yarn build failure): **none**. `grep -rn "YN0009" /tmp/*.log /tmp/xfs-*/build.log` returned nothing, so every package build — including the root postinstall that failed in round 2 — succeeded.

Only benign noise was emitted: `invoke-rc.d: policy-rc.d denied execution of start` from the rsync apt install, a `caniuse-lite` staleness warning from the web clipper webpack build, and the Node `punycode` deprecation warning.

## Post-install commands

### `command -v rsync`

```
/usr/bin/rsync
```

Exit status: 0

### `corepack yarn --version`

```
4.16.0
```

Exit status: 0 — corepack resolves the pinned Yarn release from its primed cache, so the `corepack yarn` pre-commit hook works.

### `yarn linter-ci packages/lib/ArrayUtils.ts` (from the repo root)

No output.

Exit status: 0

### `yarn jest ArrayUtils` (from `packages/lib`)

```
PASS ./ArrayUtils.test.js
  ArrayUtils
    ✓ should return unique elements (104 ms)
    ✓ should remove array elements (101 ms)
    ✓ should pull array elements (102 ms)
    ✓ should find items using binary search (102 ms)
    ✓ should compare arrays (102 ms)
    ✓ should merge overlapping intervals (102 ms)

Test Suites: 1 passed, 1 total
Tests:       6 passed, 6 total
Snapshots:   0 total
Time:        5.681 s
```

Exit status: 0

### `node build/main.js --profile /tmp/joplin-profile version` (from `packages/app-cli`)

```
Joplin CLI Client

Copyright © 2016-2026 Laurent Cozic
joplin 3.7.1 (prod, linux)

Device: linux, Intel(R) Xeon(R) Processor @ 2.10GHz
Client ID: d8aaf07eba4149cc9df5e1f0891cec63
Sync Version: 3
Profile Version: 53
Keychain Supported: No
Alternative instance ID: -
Sync target: (None)
Editor: Markdown
```

Exit status: 0
