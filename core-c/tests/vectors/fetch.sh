#!/bin/sh
# Download all SingleStepTests/8088 v2 vectors (skips files already present & non-empty)
cd "$(dirname "$0")"
while read -r f; do
  [ -s "$f" ] && continue
  echo "$f"
done < filelist.txt | xargs -P 8 -I{} curl -sfL --retry 3 -o {} "https://raw.githubusercontent.com/SingleStepTests/8088/main/v2/{}"
echo "done: $(ls *.gz 2>/dev/null | wc -l) gz files"
