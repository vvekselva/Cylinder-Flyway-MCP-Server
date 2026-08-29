#!/usr/bin/env sh
set -eu

SOURCE_REPO="vvekselva/CylinderManagement"
SOURCE_COMMIT="3ae6e61442132d94a307275b08dd65fcef228d89"
SOURCE_PATH="cylinder.datascripts/src/main/resources/db/migration"
MANIFEST="${1:-/workspace/migration-manifest.csv}"
DEST="${2:-/workspace/migrations}"

mkdir -p "$DEST"

# Manifest stores Git blob SHA-1, not ordinary file SHA-1.
git_blob_sha1() {
  file="$1"
  size=$(wc -c < "$file" | tr -d ' ')
  { printf 'blob %s\0' "$size"; cat "$file"; } | sha1sum | awk '{print $1}'
}

tail -n +2 "$MANIFEST" | while IFS=, read -r version filename expected; do
  url="https://raw.githubusercontent.com/${SOURCE_REPO}/${SOURCE_COMMIT}/${SOURCE_PATH}/${filename}"
  target="${DEST}/${filename}"
  echo "Fetching governed migration V${version}: ${filename}"
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 "$url" -o "$target"
  actual=$(git_blob_sha1 "$target")
  if [ "$actual" != "$expected" ]; then
    echo "ERROR: frozen-source mismatch for ${filename}: expected ${expected}, got ${actual}" >&2
    exit 42
  fi
done

count=$(find "$DEST" -maxdepth 1 -type f -name 'V*.sql' | wc -l | tr -d ' ')
if [ "$count" != "17" ]; then
  echo "ERROR: expected 17 governed SQL files, found ${count}" >&2
  exit 43
fi

echo "Governed migration source verified: ${count} files from ${SOURCE_COMMIT}."
