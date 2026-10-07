#!/usr/bin/env bash
# Fetch the Foundry dependencies into lib/ at the commits pinned in README.md (section "Dependencies").
# Plain clones, no git submodules in this repository. Safe to rerun: an existing clone is only
# checked out again at its pin. Exits non-zero if any HEAD differs from its pin afterwards.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p lib

# name | url | commit | recurse nested submodules (1 or 0)
deps=(
  "forge-std|https://github.com/foundry-rs/forge-std|886b4f8b63409ef474542de6394d25a9b5908ed3|0"
  "openzeppelin-contracts|https://github.com/OpenZeppelin/openzeppelin-contracts|cab19933c33c2ad1d4c7a84864a3601dddfd16f3|0"
  "v4-core|https://github.com/Uniswap/v4-core|e50237c43811bd9b526eff40f26772152a42daba|1"
)

for entry in "${deps[@]}"; do
  IFS='|' read -r name url commit recurse <<<"$entry"
  dir="lib/$name"
  if [ ! -d "$dir/.git" ]; then
    git clone --quiet "$url" "$dir"
  fi
  if ! git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
    git -C "$dir" fetch --quiet origin
  fi
  git -C "$dir" -c advice.detachedHead=false checkout --quiet "$commit"
  if [ "$recurse" = "1" ]; then
    git -C "$dir" submodule update --quiet --init --recursive
  fi
  head="$(git -C "$dir" rev-parse HEAD)"
  if [ "$head" != "$commit" ]; then
    echo "pin mismatch for $name: $head != $commit" >&2
    exit 1
  fi
  echo "$name $head"
done
