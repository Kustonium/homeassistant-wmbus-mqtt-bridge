# Contributing

[Polska wersja](CONTRIBUTING_PL.md)

Thanks for looking. Bug reports, telegrams for meters that decode wrongly,
translations and code are all welcome. Issues and discussions can be in
English or Polish.

## How a change gets in

Development happens in a separate repository, and this one receives each
release from it. A pull request here is tested there first, in its own branch,
on real hardware. If it needs changes, they go onto your pull request branch
as well (by you, or by me if "Allow edits by maintainers" is ticked), so the
pull request always holds exactly the code that will be released. After the
release that carries it, your pull request is merged here as it is: it shows
as merged and your commits stay in this repository's history. It stays open
until that release, so a few days of waiting are normal. If a pull request has
to be rewritten substantially, it is closed with a comment instead; authorship
is then kept in the development tree and in the attribution file.

For a small fix, open a pull request directly. For a new feature or anything
that changes how meters are decoded or published, open an issue or a
discussion first.

## Where to start reading

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — the whole add-on: the path of a
  telegram from MQTT through wmbusmeters to Home Assistant, the processes that
  run, the MQTT and Discovery contract, and the invariants worth preserving
  (Appendix B).
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) — the build pipeline, the
  wmbusmeters pin and the decode fixtures.
- `rootfs/usr/bin/` — `bridge.sh` and `bridge-lib/` run the pipeline,
  `webui.py` and `rootfs/usr/share/wmbus-webui/` are the WebUI, `i18n.py` holds
  its texts.

## Checking a change

**Static tests** — the same suite CI runs on every pull request. They need
Linux (WSL works), bash, jq, python3 and the mosquitto clients:

```bash
TZ=UTC LC_ALL=C.UTF-8 bash tests/run_static_tests.sh
```

Some ledger tests compare against files written in UTC, so run them with
`TZ=UTC`.

**WebUI** — it runs on its own, outside Home Assistant, against a scratch data
directory:

```bash
mkdir -p /tmp/wmbus-test && echo '{}' > /tmp/wmbus-test/options.json
cp config.yaml rootfs/usr/bin/   # the settings form reads it; do not commit the copy
WMBUS_BASE=/tmp/wmbus-test WEBUI_PORT=8765 python3 rootfs/usr/bin/webui.py
```

Then open <http://localhost:8765>.

**Decoding** is checked by golden fixtures: a RAW telegram and the expected
output per driver, see "Golden decode fixtures" in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). CI runs them against the pinned
wmbusmeters build.

## A meter that decodes wrongly

The most useful report is the telegram itself: the WebUI's **Report…** button
on a meter gives the RAW hex, the driver and the decoded fields. Mask the meter
number and never post an AES key. If wmbusmeters itself decodes the telegram
wrongly, the fix belongs in wmbusmeters' driver; the add-on only picks it up
with the next pin bump.

## New options and texts

- The default must keep today's behaviour.
- A new option in `config.yaml` needs its name and description in every file
  under `translations/` and a `cfg_desc_<option>` text in `i18n.py`, or Home
  Assistant and the WebUI show a bare key without an explanation. A test
  checks the `cfg_desc_` texts.
- WebUI texts live in `i18n.py` in five languages (en, pl, de, cs, sk). Adding a
  language means a new block there and a file under `translations/`.

## Telegrams in tests

A captured telegram identifies a real meter and carries its readings. Use
synthetic or masked telegrams in fixtures.

## Licence

See [LICENSE](LICENSE), [NOTICE.md](NOTICE.md) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). If AI helped you write a
change, that is fine — please say so in the pull request and say what you
tested in a real Home Assistant.
