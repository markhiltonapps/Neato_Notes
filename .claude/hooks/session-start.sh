#!/bin/bash

# Sets up the monorepo so tests, linters and builds work in Claude Code on the
# web. Outside of those sessions it does nothing unless called with --force.

set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != 'true' ] && [ "${1:-}" != '--force' ]; then
	exit 0
fi

# Async, so the session starts right away - the first commands of a session may
# run before the install and build have finished
echo '{"async": true, "asyncTimeout": 1800000}'

cd "${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

WASM_PACK_VERSION='0.13.1'
WASM_PACK_DIR='packages/onenote-converter/node_modules/wasm-pack/binary'

# The app-cli build task shells out to rsync, which the image doesn't ship
if ! command -v rsync > /dev/null; then
	SUDO=''
	if [ "$(id -u)" -ne 0 ]; then
		SUDO='sudo'
	fi
	$SUDO apt-get update -qq
	$SUDO apt-get install -y -qq rsync
fi

# wasm-pack downloads its binary from its postinstall script using axios 0.26.1,
# which sends a plain HTTP request that the sandbox egress proxy answers with a
# 405. Seeding the binary first makes binary-install skip the download, and Yarn
# keeps this directory when it links the package.
if [ "$(uname -s)" = 'Linux' ] && [ "$(uname -m)" = 'x86_64' ] && [ ! -x "$WASM_PACK_DIR/wasm-pack" ]; then
	mkdir -p "$WASM_PACK_DIR"
	curl -sSL "https://github.com/rustwasm/wasm-pack/releases/download/v$WASM_PACK_VERSION/wasm-pack-v$WASM_PACK_VERSION-x86_64-unknown-linux-musl.tar.gz" | tar -xz --strip-components=1 -C "$WASM_PACK_DIR"
fi

# The pre-commit hook runs `corepack yarn`, and corepack fetches the pinned Yarn
# release from repo.yarnpkg.com, which the sandbox proxy blocks. Priming its
# cache from the npm registry, which is allowed, keeps commits working.
if ! corepack yarn --version > /dev/null 2>&1; then
	COREPACK_NPM_REGISTRY='https://registry.npmjs.org' corepack install
fi

yarn install

# The install copies packages/app-cli/app to its build directory before
# `yarn tsc` has emitted the JavaScript, so the copy is redone here
yarn workspace joplin run build
