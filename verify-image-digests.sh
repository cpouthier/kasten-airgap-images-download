#!/usr/bin/env bash
set -euo pipefail

# Verify the integrity of Veeam Kasten container images downloaded by
# airgapped.sh, useful after copying them onto a USB key or any other
# offline transfer. Every image is stored as an OCI image layout, where
# each blob file under blobs/sha256/ is named after its own content hash,
# so recomputing it is the actual digest check.

command -v jq >/dev/null 2>&1 || { echo "jq is required but not found in PATH" >&2; exit 1; }

if command -v shasum >/dev/null 2>&1; then
  SHA256='shasum -a 256'
else
  SHA256='sha256sum'
fi

echo -e "\033[0;31m Enter the directory where the Veeam Kasten images were pulled: \033[0m"
read images_dir < /dev/tty

if [[ ! -d "$images_dir" ]]; then
  echo "Directory not found: $images_dir" >&2
  exit 1
fi

manifest_file="$images_dir/digests-manifest.json"
if [[ -f "$manifest_file" ]]; then
  echo "Using recorded digest manifest: $manifest_file"
else
  echo "No digest manifest found at $manifest_file, verifying blob content only."
  manifest_file=""
fi

total=0
failed=0

for image_dir in "$images_dir"/*/; do
  image_name=$(basename "$image_dir")
  [[ -f "$image_dir/index.json" ]] || continue
  total=$((total + 1))
  image_ok=true

  while IFS= read -r blob_file; do
    expected_digest=$(basename "$blob_file")
    actual_digest=$($SHA256 "$blob_file" | awk '{print $1}')
    if [[ "$actual_digest" != "$expected_digest" ]]; then
      echo "MISMATCH $image_name: $blob_file"
      echo "  expected $expected_digest"
      echo "  got      $actual_digest"
      image_ok=false
    fi
  done < <(find "$image_dir/blobs/sha256" -type f 2>/dev/null)

  # Cross-check against the digest recorded at download time, if available,
  # to also catch tampering of index.json itself (it is not content-addressed
  # the way the blobs are).
  if [[ -n "$manifest_file" ]]; then
    recorded_index_digest=$(jq -r --arg name "$image_name" '.[] | select(.image == $name) | .indexDigest' "$manifest_file")
    if [[ -n "$recorded_index_digest" ]]; then
      current_index_digest=$($SHA256 "$image_dir/index.json" | awk '{print $1}')
      if [[ "$current_index_digest" != "$recorded_index_digest" ]]; then
        echo "MISMATCH $image_name: index.json changed since download"
        echo "  recorded $recorded_index_digest"
        echo "  current  $current_index_digest"
        image_ok=false
      fi
    else
      echo "WARNING $image_name: not found in digest manifest"
    fi
  fi

  if $image_ok; then
    echo "OK $image_name"
  else
    failed=$((failed + 1))
  fi
done

echo ""
echo "Checked $total images, $failed with digest mismatches"
[[ "$failed" -eq 0 ]] && exit 0 || exit 1
