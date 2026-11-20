# Runbook: rolling back a bad R2 payload publish

`download.tunaos.org/asahi` is served from `R2_BUCKET/asahi/`. The branded
curl|sh bootstrap and asahi-installer read it (see
[`docs/DESIGN.md`](../docs/DESIGN.md), [`README.md`](../README.md)). The
`Publish release to Cloudflare R2 and move the pointer` step of
[`build-payload.yml`](../.github/workflows/build-payload.yml) writes it. That
step runs only on `main`, only with `upload_r2: true`, and only after every
payload test in the same job passed. It uses
[`scripts/publish-payload-r2.sh`](../scripts/publish-payload-r2.sh).

The bucket also serves TunaOS's `live-isos/`. Write only under `asahi/`.

## Layout

```text
asahi/installer_data.json                    the pointer clients fetch
asahi/releases/<version>/<name>.zip           immutable payload
asahi/releases/<version>/installer_data.json  names that release's zip URL
asahi/releases/<version>/<name>.provenance.json
asahi/releases/<version>/SHA256SUMS
asahi/releases/<version>/previous-installer_data.json   the pointer it replaced
```

`<version>` is `<UTC date>-<run id>-<attempt>`, for example
`20261120-44680000000-1`. A release is written once and never overwritten or
deleted. The pointer is a copy of one release's `installer_data.json`, and the
publish moves it only after the release is uploaded and verified. A rollback
moves the pointer back. It never rebuilds and never deletes anything.

## 1. Confirm the current publish is bad

- New install reports fail at a stage that the pre-publish tests
  (`scripts/test-payload.sh`, `scripts/test-boot-payload.sh`) do not cover.
  [`docs/TESTING-CHECKLIST.md`](../docs/TESTING-CHECKLIST.md) has two earlier
  cases of this.
- Find the release the pointer names:

  ```sh
  curl -fsS https://download.tunaos.org/asahi/installer_data.json | jq -r '.os_list[0].package'
  ```

## 2. Pick the release to restore

The bad release records the pointer it replaced:

```sh
rclone config create R2 s3 provider=Cloudflare \
  access_key_id=$R2_ACCESS_KEY_ID secret_access_key=$R2_SECRET_ACCESS_KEY \
  endpoint=$R2_ENDPOINT region=auto

rclone lsf "R2:${R2_BUCKET}/asahi/releases/"
rclone cat "R2:${R2_BUCKET}/asahi/releases/<bad-version>/previous-installer_data.json" \
  | jq -r '.os_list[0].package'
```

That URL names the last good release. Any older release under `releases/` can
also be the target.

## 3. Move the pointer back

```sh
rclone copyto --checksum --s3-no-check-bucket \
  --header-upload "Cache-Control: no-cache" \
  "R2:${R2_BUCKET}/asahi/releases/<good-version>/installer_data.json" \
  "R2:${R2_BUCKET}/asahi/installer_data.json"
```

Do not delete the bad release. Its objects are the evidence for the
post-mortem.

## 4. Verify the rollback

```sh
curl -fsS https://download.tunaos.org/asahi/installer_data.json | jq -r '.os_list[0].package'
curl -fsSI "https://download.tunaos.org/asahi/releases/<good-version>/<name>.zip" | head -1
```

The first command must print the good release's zip URL, and the second must
return `200`. To check the zip bytes, download it and compare with the
`SHA256SUMS` file in the same release.
