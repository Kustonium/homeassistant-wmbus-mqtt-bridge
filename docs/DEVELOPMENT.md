# Development and Release

Maintainer reference for building, testing, and publishing **wMBus MQTT
Bridge**. Runtime behavior and the integration boundary with `wmbusmeters` are
documented in [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Repository roles

Development and stable releases live in separate repositories:

- **dev**: `homeassistant-wmbus-mqtt-bridge-dev` (development repository);
- **stable**: `homeassistant-wmbus-mqtt-bridge`.

The dev repository, dev add-on, and mutable `:dev` container tags are a
maintainer-only test channel. End users install the stable repository; the dev
channel is not an end-user release source.

`config.yaml` is the add-on version source of truth. The dev build workflow
derives `X.Y.Z-dev.<run_number>` from its current `X.Y.Z` core. A successful
image-build run writes that exact built version back to `config.yaml`; a
remembered or manually inferred version is not authoritative.

## Dev build pipeline

`.github/workflows/build.yaml` runs on pushes to `main` only when one of its
declared image-affecting paths changes, and it can also be started manually.
Documentation-only pushes do not start this workflow because `README.md` and
`docs/**` are not in `on.push.paths`.

For a triggered build, the dependency graph is:

1. **Gate** examines the push range and decides whether the run is image-affecting.
2. **Static tests** run after the gate and verify the driver-catalog and
   Discovery publication contracts.
3. **Build** runs after static tests and builds both amd64 and aarch64 images.
   Each architecture image is pushed with both the mutable `:dev` tag and the
   run-specific `:X.Y.Z-dev.<run_number>` tag.
4. **Manifest**, **Decode smoke**, and **Standalone boot** all start after the
   architecture builds and run independently of one another. Manifest publishes
   both the run-specific multi-arch tag and the mutable standalone `:dev` tag.
5. **Bump** updates `config.yaml` only after build, manifest, decode smoke, and
   standalone boot have all passed.

If a required job fails, `config.yaml` remains on its previous version. The
run-specific images can still exist, and the per-architecture or multi-arch
mutable `:dev` tags may already have moved because publication happens before
the smoke and boot jobs finish. Those tags belong to the maintainer-only test
channel; they are not stable end-user releases.

## Upgrading wmbusmeters

### Fixed upstream pin

The [`Dockerfile`](../Dockerfile) builds upstream `wmbusmeters` from the full
commit named by `ARG WMBUSMETERS_COMMIT`. The clone is intentionally not shallow
because upstream derives its version through `git describe --tags`.

Do not replace the pin with upstream `master`. A release pin provides a
reproducible binary and a reviewable decoder change. The monthly
`.github/workflows/wmbusmeters-pin-bump.yml` workflow compares the current pin
with the latest upstream `X.Y.Z` release tag and opens a pull request when a new
release exists. Merging remains a human decision.

### Driver catalog contract

The Docker build creates `drivers.json` for the WebUI from:

- `wmbusmeters --listdrivers`, with `--listmeters` as a compatibility fallback;
- upstream XMQ definitions under `drivers/src/*.xmq`.

The image build fails unless the built-in `izar` driver is present. This check
protects the entire class of built-in drivers: a changed list command must not
silently leave the WebUI with only source-scanned XMQ drivers.

### Golden decode fixtures

`tests/test_decode_smoke.sh` reads `tests/fixtures/golden.tsv`. Each row names a
fixture directory/ID, driver, and key source. The matching `.hex` file contains
the RAW telegram and `.golden.json` contains normalized expected output.
`timestamp` and `name` are excluded from comparison.

Keys in the fixture table may be:

- `NOKEY`;
- a literal 32-character key only when that key is already public, such as an
  upstream test key;
- an environment-variable name supplied from repository secrets.

Private keys must never be committed or printed by CI. Meter IDs are passed to
`wmbusmeters` in lowercase because address matching is case-sensitive.

When an accepted upstream change intentionally alters decoded JSON, regenerate
the affected `.golden.json` with the pinned binary and review the field/value
change before committing it. `GOLDEN_REQUIRE=0` can be used temporarily to
print missing expected output, but it is not the normal protected build mode.

## Standalone Docker gate

The `standalone-boot` job starts the freshly built amd64 image with its default
`/usr/bin/docker-entrypoint.sh` and a Mosquitto container reachable as
`mosquitto`. It verifies that:

- `/config/options.json` is generated;
- `bridge.sh` connects to the broker;
- the container remains running.

This path is tested separately because Home Assistant uses s6 and does not run
the Docker entrypoint. A working add-on boot therefore does not prove the
standalone wrapper works.

## Stable repository boundary

This repository contains no automated dev-to-stable promotion workflow and does
not define a file-sync contract for stable releases. The stable repository has
its own build workflow and repository identity. Any transfer between the two
repositories is external to the automation stored here and must not be described
as an implemented promotion process.

## Current validation automation

The repository currently runs these independent workflows:

- `shellcheck.yml` runs ShellCheck at warning severity on repository `*.sh`
  files, excluding `.git`, `.claude`, and `wmbusmeters-mqtt-stdin`;
- `yaml-lint.yml` runs `yamllint` on the listed workflow files,
  `.github/dependabot.yml`, `config.yaml`, and `repository.yaml`;
- `build.yaml` runs the two static contract tests before image builds, then the
  golden decode smoke and standalone boot checks described above;
- `changelog-draft.yml` regenerates the changelog skeleton on pushes to `main`;
- `wmbusmeters-pin-bump.yml` performs the monthly upstream release check and
  opens a pull request when the configured conditions are met.

There is no automated Markdown link checker or general Python test job in the
current workflows. Decoder upgrades still require human review of intentional
field and value changes in the golden fixtures.
