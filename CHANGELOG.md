# Changelog

## [1.5.3] - 2026-05-20

### Added
- WebUI topbar now shows the running addon version (`v<version>`) and a
  yellow `DEV` badge whenever the manifest version contains `-`
  (e.g. `1.5.3-dev`). Value is read from `config.yaml` baked into the
  image.
- Meter card status label is now dynamic instead of always saying
  "Online": `seen_15m > 0` → online (green), else `seen_60m > 0` →
  silent (amber), else offline (red). Localised in PL / EN / DE /
  CS / SK.
- Meter card value now shows the matching unit with a small category
  emoji (⚡ / 💧 / 🔥 / 🌡 / 📊 / ⏱ / 📐 / 📅 / 📏 / 📡 / 💡 / ⚖).
- Pending-meters panel keeps a "Restart addon now" button so users
  do not have to leave the page to apply newly-added meters.
- `scripts/promote-rootfs.sh` and `.github/workflows/sync-rootfs.yaml`
  keep the stable addon's `rootfs/`, `Dockerfile` and `translations/`
  in lockstep with the dev addon. Automatic sync runs on every push
  to `dev`; the script is the manual escape hatch.
- New CI step `Enforce version bump (stable only)` fails the stable
  build if `config.yaml` version is empty, still carries `-dev`, or
  equals the latest `X.Y.Z` git tag — no more accidental re-builds
  of the same number.
- New CI step `Create git tag for stable release` pushes a
  lightweight tag matching the stable version after a successful
  build, making the enforce-bump step self-policing on the next
  release.

### Fixed
- `bridge.sh guess_unit()` rewritten with the full wmbusmeters
  suffix vocabulary; longest suffixes are checked first so `_kwh`
  is not shadowed by `_kw`, `_kvarh` by `_kvar`, `_m3h` by `_m3`,
  etc. New coverage: `kVARh`, `kVAh`, `kVAR`, `kVA`, `J/h`, `GJ`,
  `MJ`, `dBm`, `hca`, `pct`, `ppm`, `bar`, `Pa`, `mol`, `min`,
  `rad`, `deg`, `kg`, `cd`, `K`, `°F` and the base units. The
  result is the correct `unit_of_measurement` on HA entities for
  many more meter field types.
- Non-numeric meta suffixes (`utc`, `datetime`, `counter`,
  `factor`, `txt`, `nr`, `month`) explicitly emit no unit so HA
  no longer gets bogus `unit_of_measurement` on metadata fields.
- `Dockerfile` now bakes `config.yaml` into the runtime image at
  `/usr/bin/config.yaml`. Without this, the new WebUI version
  detection would always fall back to `("dev", True)` because HA
  does not mount the addon manifest into the container.

### Changed
- `permissions` in `.github/workflows/build.yaml` bumped from
  `contents: read` to `contents: write` so the auto-tag step can
  push tags back to `origin` via the default `GITHUB_TOKEN`.
- Build workflow path filter is narrowed to image-affecting paths
  only (`rootfs/**`, `Dockerfile`, `config.yaml`, `translations/**`).
  Pure documentation commits no longer trigger any build and no
  longer produce phantom "Update available" notifications in HA.

### Notes
- No MQTT topology, no broker connection, no add-on options have
  changed. This release is layout / UX / CI polish on top of the
  defensive Discovery rework that shipped in 1.5.2.
