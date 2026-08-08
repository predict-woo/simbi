#!/bin/sh
# Vendors the anydoc CLI (https://github.com/firecrawl/anydoc, MIT) into
# vendor/anydoc/anydoc for bundling at Simbi.app/Contents/Helpers/anydoc.
#
# Upstream ships no standalone CLI (npm/GitHub carry only Node addons and
# Python wheels — verified 2026-08-08 against v0.1.7), so we build the
# crate's examples/convert.rs, a complete CLI, from the pinned crates.io
# tarball. Bump VERSION + SHA256 together to take a new release.
set -eu

VERSION=0.1.7
SHA256=96db46b7211c9994a0be9f3c520936c2682af8cc8151c69c9f9416a8426de574

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/vendor/anydoc"
BIN="$OUT/anydoc"
STAMP="$OUT/VERSION"

if [ -x "$BIN" ] && [ "$(cat "$STAMP" 2>/dev/null || true)" = "$VERSION" ]; then
    exit 0
fi

command -v cargo >/dev/null 2>&1 || {
    echo "fetch-anydoc: cargo not found. Install Rust (https://rustup.rs)" \
        "to build the vendored anydoc CLI." >&2
    exit 1
}

mkdir -p "$OUT"
CRATE="$OUT/anydoc-$VERSION.crate"
[ -f "$CRATE" ] || curl -fsSL -o "$CRATE" \
    "https://static.crates.io/crates/anydoc/anydoc-$VERSION.crate"
echo "$SHA256  $CRATE" | shasum -a 256 -c - >/dev/null

SRC="$OUT/src"
rm -rf "$SRC"
mkdir -p "$SRC"
tar xzf "$CRATE" -C "$SRC"
cd "$SRC/anydoc-$VERSION"

# Build every darwin slice whose Rust target is installed; the app ships
# universal, but a single-arch binary only degrades the other arch to the
# converter's existing non-anydoc fallback, so missing x86_64 is a warning.
SLICES=""
for TARGET in aarch64-apple-darwin x86_64-apple-darwin; do
    if cargo build --release --example convert --target "$TARGET" \
        >"$OUT/build-$TARGET.log" 2>&1; then
        SLICES="$SLICES target/$TARGET/release/examples/convert"
    else
        echo "fetch-anydoc: warning: $TARGET build failed" \
            "(see vendor/anydoc/build-$TARGET.log; missing" \
            "'rustup target add $TARGET'?) — continuing without it." >&2
    fi
done
[ -n "$SLICES" ] || {
    echo "fetch-anydoc: no architecture built — see vendor/anydoc/build-*.log" >&2
    exit 1
}

# shellcheck disable=SC2086  # SLICES is a deliberate word-split list
lipo -create -output "$BIN" $SLICES
strip "$BIN" 2>/dev/null || true
rm -rf "$SRC"
echo "$VERSION" >"$STAMP"
echo "fetch-anydoc: built $BIN ($(lipo -archs "$BIN"))"
