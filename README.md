# kasten-airgap-images-download

Scripts to download the Veeam Kasten Helm chart and every container image it needs, for air-gapped installs or any offline transfer (for example, onto a USB key), and to later verify that none of those images were corrupted or altered in transit.

They follow the official procedure described in [Veeam Kasten's air-gapped install documentation](https://docs.kasten.io/latest/install/offline), using Kasten's own `k10tools` utility rather than a hand-rolled image list.

## What it does

- `airgapped.sh`, downloads the Helm chart, derives the matching Veeam Kasten version from the chart's `appVersion`, then uses `k10tools image list` and `k10tools image copy` to fetch every required image into a local, digest-addressed OCI image layout. Optionally pushes the images on to a private registry. Records each image's digests in `digests-manifest.json` at download time.
- `verify-image-digests.sh`, given the directory produced by `airgapped.sh`, recomputes the sha256 of every image blob (each is named after its own content hash) and cross-checks it against `digests-manifest.json`, to confirm nothing changed since the download, for instance after copying the files to a USB key and moving them to the air-gapped cluster.

## Prerequisites

- `helm`
- `docker` (or another CLI that understands `docker run`, `docker pull`)
- `jq`
- Network access to `charts.kasten.io` and `gcr.io/kasten-images` from the machine running `airgapped.sh` (the verification step itself needs no network access)

## Usage

### Download the chart and images

```bash
./airgapped.sh
```

You will be asked for:
- the Veeam Kasten Helm chart version to download (leave empty for the latest)
- the output directory for the chart and images (default `./kasten-airgap`)
- whether to also push the images to a private registry, and if so, its address

Output layout:
```
<output_dir>/
  chart/
    k10-<version>.tgz
  images/
    images.txt                 # list of required images (k10tools image list)
    digests-manifest.json      # recorded digests, used by verify-image-digests.sh
    <image-name>/               # one OCI image layout per image
      oci-layout
      index.json
      blobs/sha256/...
```

### Verify the images after a transfer

```bash
./verify-image-digests.sh
```

You will be asked for the directory where the images were pulled, the `images` folder created above. The script reports `OK` or `MISMATCH` for each image and exits non-zero if any digest does not match.

## Installing Veeam Kasten from the downloaded images

Once the chart and images are available on the air-gapped side (and pushed to your private registry if you used that option), install with Helm as usual, pointing at your private registry:

```bash
helm install k10 chart/k10-<version>.tgz --namespace kasten-io \
  --set global.airgapped.repository=<your-private-registry>
```

See the [official documentation](https://docs.kasten.io/latest/install/offline) for the full set of air-gapped install options (image pull secrets, metering mode, and so on).
