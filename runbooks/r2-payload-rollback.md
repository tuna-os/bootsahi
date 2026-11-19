# Runbook: rolling back a bad R2 payload publish

`download.tunaos.org/asahi` is served from `R2_BUCKET/asahi/`, and is what the
branded curl|sh bootstrap and asahi-installer point at (see
[`docs/DESIGN.md`](../docs/DESIGN.md), [`README.md`](../README.md)). It is
published by the `Upload payload to Cloudflare R2` step of
[`build-payload.yml`](../.github/workflows/build-payload.yml), a manual,
opt-in (`upload_r2: true`) dispatch. Each publish overwrites, in place:

- `asahi/<name>.zip` (default name: `tunaos-bootstrap`)
- `asahi/installer_data.json`

There is no version suffix on these keys — the published payload is always
whatever was last uploaded. Every publish first backs up the objects it is
about to overwrite to `asahi/backups/<run_id>/`, so the previous payload is
recoverable without rebuilding it.

## 1. Confirm the current publish is bad

Signs to look for:
- A new report of installs failing at a stage the pre-publish selftests
  (`scripts/test-payload.sh`, `scripts/test-boot-payload.sh`) don't cover —
  see the "first real installs failed" section of
  [`docs/TESTING-CHECKLIST.md`](../docs/TESTING-CHECKLIST.md) for two
  precedents of exactly this (both passed producer-side tests and only broke
  on a real install).
- The `Build asahi-installer payload` Actions run that published the current
  live objects: check its `Test: payload structure...` and
  `Test: boot the reconstructed install...` steps actually ran and passed —
  a publish only fires from `upload_r2: true`, which does not itself require
  those steps to have passed if someone dispatched it by hand with a
  different set of inputs.

## 2. Find the backup to restore

Every publish run logs the backup prefix it wrote to
(`asahi/backups/<run_id>/`) in the "Upload payload to Cloudflare R2" step
output. Find the run **before** the bad one in the workflow's run history
(`gh run list --repo tuna-os/bootsahi --workflow "Build asahi-installer payload"`)
and take its run ID — that run's backup step, if it ran, holds what was live
immediately before it published, i.e. two publishes back from the bad one.

To restore the payload that was live **immediately before the bad publish**,
use the backup written **by the bad publish's own run** (it backs up the
previous live objects before overwriting them):

```sh
rclone config create R2 s3 provider=Cloudflare \
  access_key_id=$R2_ACCESS_KEY_ID secret_access_key=$R2_SECRET_ACCESS_KEY \
  endpoint=$R2_ENDPOINT region=auto

# List available backups
rclone lsf "R2:${R2_BUCKET}/asahi/backups/"

# Restore a specific backup (server-side, no local download)
rclone copy --checksum --s3-no-check-bucket \
  "R2:${R2_BUCKET}/asahi/backups/<bad-publish-run-id>/tunaos-bootstrap.zip" \
  "R2:${R2_BUCKET}/asahi/"
rclone copy --checksum --s3-no-check-bucket \
  "R2:${R2_BUCKET}/asahi/backups/<bad-publish-run-id>/installer_data.json" \
  "R2:${R2_BUCKET}/asahi/"
```

## 3. Verify the restore

Confirm the restored `installer_data.json` matches what the pre-bad-publish
run actually built (compare against that run's uploaded `payload` artifact
in Actions, retained for 14 days), and that a fresh
`rclone lsf --format sp "R2:${R2_BUCKET}/asahi/"` shows sizes matching the
known-good artifact.

## 4. If no backup exists

The first-ever publish to a given `PAYLOAD_NAME` has nothing to back up.
Recovery in that case means re-running `build-payload.yml` with
`image` pinned to the last known-good bootstrap image tag/digest and
`upload_r2: true`.
