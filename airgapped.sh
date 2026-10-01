#!/usr/bin/env bash
set -euo pipefail

# Download the Veeam Kasten Helm chart and every container image it needs,
# using Kasten's own k10tools utility, for air-gapped installs or offline
# mirroring (e.g. onto a USB key).

command -v helm >/dev/null 2>&1 || { echo "helm is required but not found in PATH" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker is required but not found in PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required but not found in PATH" >&2; exit 1; }

if command -v shasum >/dev/null 2>&1; then
  SHA256='shasum -a 256'
else
  SHA256='sha256sum'
fi

echo -e "\033[0;31m Enter the Veeam Kasten Helm chart version to download (leave empty for latest): \e[0m"
read chart_version < /dev/tty

echo -e "\033[0;31m Enter the output directory for the chart and images (default: ./kasten-airgap): \e[0m"
read output_dir < /dev/tty
output_dir=${output_dir:-./kasten-airgap}

echo -e "\033[0;31m Also push the images to a private registry? (y/N): \e[0m"
read push_choice < /dev/tty
push_choice=${push_choice:-N}

target_registry=""
if [[ "$push_choice" =~ ^[Yy]$ ]]; then
  echo -e "\033[0;31m Enter the target private registry, e.g. myregistry.example.com/kasten: \e[0m"
  read target_registry < /dev/tty
fi

mkdir -p "$output_dir/chart" "$output_dir/images"

# Step 1 of https://docs.kasten.io/latest/install/offline: fetch the Helm
# chart locally.
helm repo add kasten https://charts.kasten.io/ >/dev/null 2>&1 || true
helm repo update

if [[ -n "$chart_version" ]]; then
  helm pull kasten/k10 --version "$chart_version" --destination "$output_dir/chart"
else
  helm pull kasten/k10 --destination "$output_dir/chart"
fi

chart_archive=$(ls -t "$output_dir/chart"/k10-*.tgz | head -n1)
echo "Downloaded chart: $chart_archive"

# The k10tools image tag always matches the chart's appVersion, so the images
# stay in lockstep with the chart just downloaded, whether or not a specific
# version was requested above.
k10_version=$(tar -xzOf "$chart_archive" k10/Chart.yaml | grep '^appVersion:' | awk '{print $2}')
echo "Veeam Kasten version: $k10_version"

k10tools_image="gcr.io/kasten-images/k10tools:$k10_version"
echo "Pulling $k10tools_image"
docker pull "$k10tools_image"

# Step 2 of https://docs.kasten.io/latest/install/offline: list every image
# required by this Veeam Kasten version.
image_list_file="$output_dir/images.txt"
docker run --rm "$k10tools_image" image list > "$image_list_file"
echo "Found $(wc -l < "$image_list_file" | tr -d ' ') images, listed in $image_list_file"

# Step 4 (filesystem-based transfer) of the same page: save every image
# locally as an OCI image layout, one self-describing, digest-addressed
# directory per image.
echo "Downloading Veeam Kasten container images to $output_dir/images"
docker run --rm -v "$output_dir/images:/images" "$k10tools_image" image copy --dst-path /images

if [[ -n "$target_registry" ]]; then
  # Step 4, import side: push the locally saved images to the private registry.
  echo "Pushing images to $target_registry"
  docker run --rm -v "$HOME/.docker:/home/kio/.docker" -v "$output_dir/images:/images" "$k10tools_image" \
    image copy --src-path /images --dst-registry "$target_registry"
fi

# Record each image's manifest digests and the hash of its index.json, so
# kasten/verify-image-digests.sh can later confirm nothing was altered since
# this download (e.g. during a USB transfer).
manifest_file="$output_dir/images/digests-manifest.json"
echo "[]" > "$manifest_file"
for image_dir in "$output_dir/images"/*/; do
  image_name=$(basename "$image_dir")
  [[ -f "$image_dir/index.json" ]] || continue
  index_digest=$($SHA256 "$image_dir/index.json" | awk '{print $1}')
  manifest_digests=$(jq -c '[.manifests[].digest]' "$image_dir/index.json")
  tmp=$(mktemp)
  jq --arg name "$image_name" --arg index_digest "$index_digest" --argjson manifests "$manifest_digests" \
    '. + [{"image": $name, "indexDigest": $index_digest, "manifestDigests": $manifests}]' \
    "$manifest_file" > "$tmp"
  mv "$tmp" "$manifest_file"
done

echo "Done."
echo "Chart archive: $chart_archive"
echo "Images (OCI layout) under: $output_dir/images"
echo "Digest manifest: $manifest_file"
[[ -n "$target_registry" ]] && echo "Images also pushed to: $target_registry"

exit 0
