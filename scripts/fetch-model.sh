#!/bin/sh
# Downloads the Qwen3-1.7B-4bit MLX model into the app bundle resources.
# Weights are gitignored (1 GB). Run once before opening the Xcode project.
set -e
DEST="$(dirname "$0")/../app/Resources/Qwen3-1.7B-4bit"
BASE="https://huggingface.co/mlx-community/Qwen3-1.7B-4bit/resolve/main"
FILES=".gitattributes README.md added_tokens.json config.json merges.txt \
model.safetensors model.safetensors.index.json special_tokens_map.json \
tokenizer.json tokenizer_config.json vocab.json"

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
echo "done: $(du -sh "$DEST" | cut -f1)"
