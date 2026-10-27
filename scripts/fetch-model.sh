#!/bin/sh
# Downloads the Qwen3-1.7B-4bit MLX model into the app bundle resources.
# Weights are gitignored (1 GB). Run once before opening the Xcode project.
set -e
PIN=3b1b1768f8f8cf8351c712464f906e86c2b8269e
DEST="$(dirname "$0")/../app/Resources/Qwen3-1.7B-4bit"
BASE="https://huggingface.co/mlx-community/Qwen3-1.7B-4bit/resolve/$PIN"
FILES=".gitattributes README.md added_tokens.json config.json merges.txt \
model.safetensors model.safetensors.index.json special_tokens_map.json \
tokenizer.json tokenizer_config.json vocab.json"

# A leftover folder from resolve/main must not be treated as this pin.
reset_if_unpinned() {
  dir=$1
  if [ -d "$dir" ] && [ "$(cat "$dir/REVISION" 2>/dev/null || true)" != "$PIN" ]; then
    rm -rf "$dir"
  fi
}

if [ "${1:-}" = "--selftest" ]; then
  tmp=$(mktemp -d)
  mkdir -p "$tmp/w"
  echo stale > "$tmp/w/model.safetensors"
  echo not-the-pin > "$tmp/w/REVISION"
  reset_if_unpinned "$tmp/w"
  [ ! -d "$tmp/w" ]
  mkdir -p "$tmp/w"
  echo "$PIN" > "$tmp/w/REVISION"
  echo keep > "$tmp/w/model.safetensors"
  reset_if_unpinned "$tmp/w"
  [ -f "$tmp/w/model.safetensors" ]
  rm -rf "$tmp"
  echo "fetch selftest ok"
  exit 0
fi

reset_if_unpinned "$DEST"
mkdir -p "$DEST"
for f in $FILES; do
    if [ -s "$DEST/$f" ]; then
        echo "skip $f (exists)"
        continue
    fi
    echo "fetch $f"
    curl -Lf --retry 3 -o "$DEST/$f.part" "$BASE/$f"
    mv "$DEST/$f.part" "$DEST/$f"
done
printf '%s\n' "$PIN" > "$DEST/REVISION"
echo "done: $(du -sh "$DEST" | cut -f1)"
