> 🌐 [**EN**](README.en.md) | [PL](README.pl.md) | [DE](README.de.md) | [CS](README.cs.md) | [SK](README.sk.md)

# wMBus MQTT Bridge — user guide (EN)

> A user-facing guide: install, add meters, read the dashboard, troubleshoot.
> **How it works internally** (architecture, runtime files, soft-reload, the ESP
> diagnostics contract) is in [`ARCHITECTURE.md`](ARCHITECTURE.md).

---

## Table of contents

1. [What it does](#1-what-it-does)
2. [Requirements](#2-requirements)
3. [Quick start — Home Assistant](#3-quick-start--home-assistant)
4. [Quick start — Docker standalone](#4-quick-start--docker-standalone)
5. [The WebUI — what you see](#5-the-webui--what-you-see)
6. [Typical workflow: from empty to a working meter](#6-typical-workflow-from-empty-to-a-working-meter)
7. [Filter by value — when you hear too many other meters](#7-filter-by-value--when-you-hear-too-many-other-meters)
8. [Configuration options](#8-configuration-options)
9. [Interface language](#9-interface-language)
10. [Troubleshooting](#10-troubleshooting)
11. [How it works under the hood](#11-how-it-works-under-the-hood)
12. [Licence and upstream](#12-licence-and-upstream)

---

## 1. What it does

> **In one sentence:** it decodes Wireless M-Bus telegrams (water, heat and
> electricity meters) **without a local USB dongle** — the raw HEX frames are
> delivered by any external receiver (ESP32, gateway) over MQTT.

- **You** put the radio receiver where there is signal (e.g. an ESP32 with an antenna).
- **The receiver** publishes raw HEX frames to MQTT (`wmbus/<device>/telegram`).
- **This add-on** connects to the broker, feeds `wmbusmeters`, decodes the
  telegrams and publishes the result back to MQTT + **Home Assistant Discovery**.

Result: **your meters show up as sensors in HA with no radio hardware on the HA side.**

```mermaid
flowchart LR
  ESP["🛰️ ESP32 / gateway<br/>CC1101 · SX1276 · SX1262"] -->|"HEX → wmbus/+/telegram"| BROKER["📡 MQTT broker"]
  BROKER -->|"subscribe"| ADDON["🧩 This add-on<br/>wmbusmeters + dashboard"]
  ADDON -->|"JSON + Discovery"| BROKER
  BROKER -.->|"sensors"| HA["🏠 Home Assistant"]
```

> 🤝 Typically used with the **[esphome-wmbus-bridge-rawonly](https://github.com/Kustonium/esphome-wmbus-bridge-rawonly)**
> firmware (ESP32 + CC1101/SX1276/SX1262, publishes RAW HEX). The two projects are
> independent — the add-on accepts hex from any source publishing on `raw_topic`.

> 🌉 **As a whole, the ESP (RF receiver) and this add-on (decoder) form a
> distributed _wM-Bus → Home Assistant gateway_** — the radio sits where the
> signal is, while decoding (decryption and the driver set from the pinned
> `wmbusmeters` build) runs on HA.
> Unlike monolithic wM-Bus gateways (radio + decoder in one box) it needs no
> local USB dongle and scales by adding cheap ESP nodes.
>
> **Each half also runs standalone and is interchangeable:** the ESP feeds any MQTT backend (Node-RED, a custom script, your own decoder), and the add-on decodes hex from any source on `raw_topic` (this ESP, rtl-wmbus, another gateway, the replay tool) — they cooperate, but neither depends on the other.

---

## 2. Requirements

- An **MQTT broker** (Mosquitto, EMQX…) reachable from HA / the host.
- A **receiver** publishing HEX frames to `wmbus/<device>/telegram`.
- Home Assistant (add-on mode) **or** Docker + compose (standalone).

> ⚠️ Do not run the official `wmbusmeters` add-on in parallel — this project has
> its own instance and they would duplicate each other.

> 🧱 **Responsibility boundary.** This project ships two MQTT clients — the ESP firmware (radio → MQTT) and this add-on (MQTT → decode → HA); its scope ends at the MQTT topic. **The broker itself — authentication, ACLs, TLS, network exposure and any broker-to-broker bridging for remote/distributed setups (site A → internet → site B) — is the operator's responsibility.** Recommended: keep the broker on your LAN; for remote access use a tunnel/VPN or TLS broker bridging; do not expose port 1883 or the WebUI (8099) directly to the internet. Note: for AES-encrypted meters the payload stays encrypted by the meter end-to-end, independent of broker transport.

> ⚠️ **New to this? Read before exposing anything.** Do **not** forward your broker's port (1883) or Home Assistant to the internet on your home router — an exposed broker can be read and abused by anyone. To reach your system from outside, use a ready-made secure option: **Home Assistant Cloud (Nabu Casa)**, or the **Tailscale** / **Cloudflare Tunnel** add-ons. Not sure? Keep everything on your home network — the add-on does not need internet access to work.

---

## 3. Quick start — Home Assistant

1. **Add the repository:** Settings → Add-ons → Add-on Store → ⋮ → Repositories:
   ```
   https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge
   ```
2. **Install** "wMBus MQTT Bridge", click **Start** (with the default `meters: []`
   the add-on enters **LISTEN mode** and only listens).
3. **Open the WebUI** (Info → OPEN WEB UI).
4. Go to **RECEIVING / SEARCH**, find your meter among the detected candidates and
   click **Add** (modal: ID, driver, name, optional AES key, and which fields to
   publish — see below). After saving, the
   pipeline reloads itself (no container restart).

Full walkthrough in [§6](#6-typical-workflow-from-empty-to-a-working-meter).

---

## 4. Quick start — Docker standalone

For everything outside HA (DietPi, Ubuntu, Raspberry Pi OS, NAS…).

```bash
git clone https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge.git
mkdir -p /home/wmbus
cp -a homeassistant-wmbus-mqtt-bridge/docker/examples/* /home/wmbus/
cd /home/wmbus
docker compose pull
docker compose up -d
docker compose logs -f wmbus
```

The `wmbus` image is multi-arch (amd64 + aarch64) — `pull` fetches the variant
matching your host automatically, no local build toolchain needed.

Configuration in `./config/options.json` (field reference in [§8](#8-configuration-options)):

```json
{
  "raw_topic": "wmbus/+/telegram",
  "discovery_enabled": true,
  "state_prefix": "wmbusmeters",
  "mqtt_mode": "external",
  "external_mqtt_host": "192.168.1.10",
  "external_mqtt_port": 1883,
  "external_mqtt_username": "user",
  "external_mqtt_password": "pass",
  "meters": []
}
```

After editing: `docker compose restart wmbus`. WebUI: expose port `8099` in
`docker-compose.yml` and open `http://<host-ip>:8099/`.

> 💡 In Docker the global **Restart** button works when the container has a
> restart policy (the example Compose file uses `restart: unless-stopped`).
> Without one, the button stops the container; start it again with
> `docker start <container>`.

---

## 5. The WebUI — what you see

Available in **5 languages** (EN/PL/DE/CS/SK) — switcher in the top-right corner.

| Tab | Purpose |
|---|---|
| **PANEL** | Dashboard: the ESP→MQTT→wmbusmeters→HA pipeline (clickable tiles) + statistics. |
| **METERS** | Your configured meters: value, last telegram, **RECEPTION**. |
| **RECEIVING / SEARCH** | Detected candidates + configured-on-air; add/remove meters and filter displayed values here. |
| **LOGS / ESP LOGS** | Runtime events and ESP receiver diagnostics. |
| **SETTINGS / ABOUT** | Active configuration, info. |

### The RECEPTION column (what the badges mean)

Hover the **ⓘ** next to the RECEPTION header for a legend. In short:

- **status + bars** — whether the meter is arriving: *online* / *overdue* / **quiet**.
  The threshold is **adaptive** to that meter's own rhythm (its average interval).
  Prolonged silence is **neutral** (grey), not a red alarm — a meter may be quiet
  at night / while you are away / on a weak battery, so we do not cry wolf.
- **📡 ESP** — the meter is flagged (highlighted) on one of the ESPs.
- **📶 name N% · count** — reception % and telegram count **per ESP** (from the
  optional diagnostics). With several ESPs you see which receiver hears the meter
  and how well. Colour: green ≥90 · amber ≥50 · red <50.

> The raw % and count are **not** a measure of board sensitivity (cumulative count
> since boot, different uptimes). Real sensitivity is **coverage** — which meters a
> board hears at all.

### Adding / removing meters (RECEIVING)

- Non-AES candidates auto-decode — the **Value** column shows a live preview without
  configuring them.
- **Add** stores the meter and reloads the pipeline.
- **Compare** in the **Add** or **Driver…** modal decodes the last telegram with two
  drivers without saving changes. Choose a driver in the **Driver** field, enter
  the AES key if the meter is encrypted, then click **Compare**. The left column is
  the saved driver or `wmbusmeters` auto-detection; the right column is the driver
  you selected. Green rows are extra fields, amber rows are different values; more
  fields do **not** automatically mean the driver is correct, so verify the values
  against the meter display.
- **Report…** uses a configured 32-character AES key for the same meter ID when
  one is available, so `wmbusmeters --analyze` can show decrypted details. The
  key itself is never included, but meter readings may be present — review the
  report before posting it publicly.
- **Remove selected** — tick the checkboxes and remove several at once (button above
  the table).

---

## 6. Typical workflow: from empty to a working meter

```mermaid
flowchart TD
  A["1️⃣ Start, meters=[]"] --> B["LISTEN mode"]
  B --> C["ESP publishes HEX<br/>→ candidate visible"]
  C --> D{"Candidate visible?"}
  D -- "yes (no AES)" --> E["2️⃣ Add"]
  D -- "yes (AES)" --> F["2a. Add + HEX key"]
  D -- "no" --> G["Check ESP, broker,<br/>raw_topic, filter_hex_only"]
  E --> H["3️⃣ Save options.json<br/>+ pipeline reload"]
  F --> H
  H --> I["4️⃣ After the first telegram<br/>meter = Online on METERS"]
```

1. **Start** with `meters: []` → LISTEN mode, log shows `No meters configured -> LISTEN MODE`.
2. **Add** a candidate (no AES — straight away; AES — enter the 32-char HEX key).
   The same modal lists every field the driver can report, each with the
   description wmbusmeters ships for it and a checkbox. Uncheck what you do not
   want as an entity, or type patterns such as `consumption_at_history_*` in
   **Fields to skip**. Leave it alone and every field is published, as before.
   You can change this later from **Driver…** on an existing meter — note that
   unchecking a field removes its entity together with its recorded history.
3. The save goes to `options.json` and the DECODE pipeline reloads **without a full
   container restart**.
4. After the **next telegram** from that meter it appears as **Online** on METERS,
   and HA Discovery creates entities for the numeric fields emitted by
   `wmbusmeters`, for example `total_m3`. The final HA `entity_id` is assigned by
   Home Assistant and is not fixed by the bridge.

Until the first telegram arrives the dashboard shows a **"waiting for the first
telegram"** panel. A full add-on restart is only an emergency fallback.

**Renaming a meter.** Open **Driver…** on a configured meter and edit the
**Name** field. The name is what Home Assistant shows as the device name.
Renaming is safe for history: every entity's `unique_id` is derived from the
meter id, not from the name, so the entities and their recorded data survive.
Home Assistant does not re-slug an existing `entity_id` on a rename — an entity
created as `sensor.kitchen_total_m3` keeps that id after the device is renamed
to *Bathroom*, and only the displayed name follows. Two meters cannot share a
name: the decoder writes one file per name, so the save is refused instead of
letting the second meter silently overwrite the first.

**Unsupported meter?** If a candidate never decodes (unknown driver / "unknown
format signature"), use the **Report…** button in its row: the add-on builds a
ready-to-paste issue block for the upstream wmbusmeters project (raw telegram +
`wmbusmeters --analyze` output). The telegram contains the meter's serial
number. The AES key is never included; when a configured key is used for the
analysis, the decrypted output may include meter readings.

The same **Report…** button sits in every row on METERS, so a meter you have
already added — one that decodes but reports a field wrongly, or reports fewer
fields than its display shows — can be reported without removing it first. It
is also the way to see the raw frame of a configured meter: the report opens
with the telegram itself. The frame comes from the rolling buffer of recently
received telegrams, so it is available as soon as the meter transmits again
after a restart.

---

## 7. Filter by value — when you hear too many other meters

The current WebUI workflow is the **Filter by value** bar on RECEIVING / SEARCH:

1. Wait until configured meters or candidates have a numeric value in the
   **Value** column.
2. Enter the reading from the physical display and a tolerance (default `0.05`).
3. The browser keeps rows whose displayed value falls within that tolerance and
   hides rows with a different or missing value.

This filter only compares values already displayed by the WebUI. It does not
start additional decoders, try other drivers, or change the configuration. Use
**Compare** separately when you need to inspect two drivers on the same frame.

The older `search_mode` backend still exists for advanced use through the hidden
`#search` route. While enabled, LISTEN caches only candidates reported as
unencrypted water meters together with their one suggested driver. A subsequent
restart loads those cached candidates as temporary meters and checks numeric
fields whose names contain `m3` or `total_volume`. It does **not** try every
driver. Temporary SEARCH meters are excluded from Home Assistant Discovery.

---

## 8. Configuration options

From [`config.yaml`](../config.yaml).

### MQTT — input / output

| Field | Type | Default | Description |
|---|---|---|---|
| `raw_topic` | str | `wmbus/+/telegram` | Topic with the raw HEX frames. `+` = wildcard (ESP name in diagnostics) |
| `filter_hex_only` | bool | `true` | Ignore messages that do not look like HEX |
| `mqtt_mode` | enum | `auto` | `auto` (order: `external_mqtt_host` when set → HA broker from the Supervisor service → probe of known broker add-ons `core-mosquitto`/`a0d7b954-emqx`, using `external_mqtt_username/password` when provided) / `ha` (force HA) / `external` (always external) |
| `external_mqtt_host/port/username/password` | str/int | `""` / `1883` / `""` / `""` | External broker (when `external`) |

### Discovery and output

| Field | Type | Default | Description |
|---|---|---|---|
| `discovery_enabled` | bool | `true` | Publish HA Discovery |
| `discovery_prefix` | str | `homeassistant` | Discovery prefix |
| `discovery_retain` | bool | `true` | Discovery as retained |
| `state_prefix` | str | `wmbusmeters` | Value topic prefix |
| `state_retain` | bool | `false` | Retained state |
| `verify_ha_entities` | bool | `false` | In HA add-on mode, use the add-on's declared read-only HA Core API access to verify a canary entity. Docker has no Supervisor token, so verification is unavailable there. |

Every discovered entity carries an **availability template**: when a field is
missing from the meter's latest telegram (some meters alternate between short
and full frames), the entity shows `unavailable` instead of a stale or false
value, and recovers automatically with the next telegram that contains the
field. Independently, an auto-tuned `expire_after` (about 2× the meter's
observed transmit interval, minimum 1 h) marks entities `unavailable` when the
meter goes silent.

Beyond the numeric measurement sensors, each meter that reports a `status`
field also gets two **diagnostic** entities (in the device's *Diagnostics*
section): a `sensor` with the raw status text and a `binary_sensor`
(`device_class: problem`) that turns *on* whenever the status is anything other
than `OK`. The text is passed through verbatim from `wmbusmeters`, so its exact
content depends on the selected upstream driver.

Beyond that, the bridge publishes a Discovery config for **every** field the
driver exposes and splits them by what they measure:

- a field Home Assistant can classify (a `device_class` is guessed) or one
  carrying a consumption unit — m³, GJ, MJ, kWh, Wh, l, hca, kVARh, kVAh, that
  is also the quantities HA has no class for: heat volume, heat energy in
  GJ/MJ, heat cost allocator units and reactive/apparent energy — becomes an
  ordinary measurement sensor, enabled;
- everything else becomes a **diagnostic** sensor published as **disabled**
  (`enabled_by_default: false`): unclassified numbers such as record ages and
  error counters, text fields (`current_status`, `meter_datetime`, …) and
  fields the driver currently reports as `null` (a `fraud_date` before any
  fraud). Home Assistant registers such an entity and lists it on the device
  page switched off; you enable the ones you want.

Only the meter's identity (`id`, `name`, `meter`, `media`, `timestamp`, `rssi`,
`lqi`) never becomes an entity — it is already in the device name and in the
entity attributes.

Every entity also carries a `Description` attribute — the text the driver author
wrote for that field, taken from `wmbusmeters --listfields`. It sits next to the
decoded telegram fields in the entity's attributes, so nothing that was there
before is lost.

Home Assistant reads `enabled_by_default` only when it first adds an entity, so
an upgrade never disables what you already have. `entity_category` is re-applied
on every config update, so unclassified numeric fields created by an older
version do move into the device's *Diagnostics* section.

The same rule works the other way round: an entity that was created disabled
stays disabled until you enable it on the device page — even if a later add-on
version would now publish it as a normal sensor. Deleting the device does not
help, because Home Assistant restores removed entities (including their
enabled/disabled state) as soon as the same meter is rediscovered; it keeps that
record for 30 days. Enable it by hand once and it stays enabled.

### RSSI per receiving board (opt-in, enabled on the ESP)

Signal level is not part of a telegram. The RAW topic carries bare hexadecimal,
so `wmbusmeters` never sees an RSSI and cannot report one — the receiving board
has to publish it separately. That publication is **off by default** and is not
an add-on option: you enable it in the firmware's YAML, in the `wmbus_radio`
section:

```yaml
wmbus_radio:
  publish_rssi: true
```

The board then publishes, for every meter it decodes:

```text
wmbus/<board>/rssi/<meter_id>    payload: -52
```

The bridge caches that value per meter **and** per board, and joins it onto the
decoded telegram as `rssi_<board>_dbm`. Each board therefore gets its own
signal-strength entity for the same meter:

```json
{
  "rssi_lilygo_dbm": -52,
  "rssi_xiaoseed_dbm": -50
}
```

This is deliberate. Two boards can hear the same meter, and a single merged
value would simply alternate between them — a number that looks like a
fluctuating signal instead of two receivers. There is no combined `rssi_dbm`
for that reason.

What the bridge stores is only a plausible measurement: -125 to -1 dBm. The
firmware's "no data" sentinels are dropped rather than published as readings,
and a cached value older than five minutes is not attached to a fresh telegram —
so if one board stops publishing, its entity goes unavailable instead of
freezing on its last number.

With the option left off, nothing arrives, no field is added and no entity is
created.

### Legacy SEARCH mode

| Field | Type | Default | Description |
|---|---|---|---|
| `search_mode` | bool | `false` | Enables the hidden legacy SEARCH backend described in [§7](#7-filter-by-value--when-you-hear-too-many-other-meters) |
| `search_expected_value_m3` | float | `0` | Expected m³ reading |
| `search_tolerance_m3` | float | `0.05` | Comparison tolerance — don't raise in a block |
| `search_delta_mode` / `search_min_delta_m3` | bool/float | `false` / `0.001` | (Experimental) delta comparison |
| `search_topic` | str | `wmbus/search/candidates` | Non-retained SEARCH result topic |

### Debug

| Field | Type | Default | Description |
|---|---|---|---|
| `loglevel` | enum | `normal` | `normal` / `verbose` / `debug` |
| `debug_every_n` | int | `0` | Extra diagnostics every Nth telegram |

### Meters — `meters[]`

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | str | yes | Your meter label, used in MQTT Discovery names and generated configuration |
| `meter_id` | str | yes | The meter serial number (HEX, from LISTEN) |
| `type` | str | yes | **The wmbusmeters driver name** (e.g. `hydrodigit`, `amiplus`, `izarv2`) **or `auto`/`other`**. A free string — wmbusmeters validates the driver at decode time (deliberately not an enum, so new drivers are never rejected). |
| `type_other` | str? | when `type=other` | Custom driver name |
| `key` | str? | when encrypted | 32-char AES key (HEX) |
| `exclude_fields` | str? | no | Glob patterns, comma- or space-separated, for decoded fields that should get **no** Home Assistant entity — e.g. `consumption_at_history_*, history_*_date`. Empty publishes every field. |
| `calculated_fields` | str? | no | Extra fields **wmbusmeters** computes from the telegram, semicolon separated, each `name=formula` — e.g. `difftemp_c=flow_temperature_c - return_temperature_c`. The decoder does the arithmetic; the result is a normal field and becomes an entity like any other. |
| `static_fields` | str? | no | Constant values attached to this meter, semicolon separated, each `name=value` — e.g. `location=kitchen; apartment=12`. The decoder copies them into the telegram **as text** (`apartment=12` arrives as `"12"`), so they show up in the entity attributes and as diagnostic entities: a label, not a measurement. |

Two things are worth knowing before writing one. The arithmetic is **unit-aware**:
`total_m3 / 2 counter` works, while `total_m3 * 2` does not — a bare number carries
no unit and the decoder rejects the formula. Adding fields that share a unit needs
nothing special, e.g.
`difftemp_c=max_external_temperature_c - min_external_temperature_last_month_c`.
And a formula the decoder cannot parse costs you only that one field: it says so in
the log, the field is simply absent, and the rest of the meter decodes as usual.

The name of a calculated field is not free-form: it must end in a unit, and that
unit converts the result. From one and the same formula, `difftemp_c` yields °C
while `difftemp_f` yields °F — measured on a live telegram, 11 °C came back as
`11`, `51.8` and `284.15` under the `_c`, `_f` and `_k` names. A name with no unit
or an unknown one (`mojepole`, `kopia_xyz`) is refused: the decoder says
*"Could not extract a valid unit from calculated field name"*, that field is not
created, and the meter keeps decoding. Constant fields have no such rule — any
name is accepted, because nothing is converted.

The WebUI driver list is generated from the pinned `wmbusmeters` build and its
XMQ sources. Use that catalog instead of a manually maintained list in this guide.

The field table in the meter's driver panel comes from
`wmbusmeters --listfields` — the driver's full catalog, not the list of what
this path publishes. Ten fields common to every driver are therefore shown
greyed out and cannot be ticked. `id`, `name`, `meter`, `media` and `timestamp`
are the meter's identity: they stay in the device name and in the entity
attributes instead of becoming entities of their own. `timestamp_ut`,
`timestamp_lt`, `timestamp_utc`, `device` and `rssi_dbm` never reach the
decoder's JSON here — the three timestamps exist only for the CSV/`fields`
output formats, and the last two are filled in by a receiving radio device,
which the decoder does not have when telegrams are fed to it as hex.

---

### Diagnostics tab

A per-board table: frames, meters, missing events, restarts in the last 24 hours
and time since the last frame, with one status per board. Below it, a card per
board with the details and a plain-language note explaining any warning.

Two things it is built to catch. **Sequence gaps**, which prove an event was lost
between the ESP and the add-on - though not whether the radio, MQTT, the network
or the subscriber was at fault. And **silent restarts**: a restart resets the
board's counters, so without a record it erases its own evidence. When restarts
are spaced about 15 minutes apart, the tab says so and names the likely cause -
ESPHome's default `api.reboot_timeout`, which restarts a board whenever no
Native API client is connected. An MQTT-only receiver never has one.

The page needs firmware that publishes the `rx` metadata topic; boards on older
firmware simply do not appear.

When the firmware also stamps frames with their reception time, the card gains
an **ESP clock** line: whether the board's clock is set, and how far its idea of
the reception time is from the bridge's.

When the firmware also publishes a retained `<diag>/config` snapshot, the card
gains a **Configuration** section that lists every effective setting with its
marker - `default`, `CHANGED`, or `set` - so the reader can see what the board
actually came up with without asking for the YAML. Older firmware simply omits
the section; there is nothing to render from an empty topic.

### ESP RX evidence export (`esp_rx_api_enabled`, off by default)

Firmware that publishes structured receive metadata on `wmbus/<board>/rx` lets the
add-on count **actual receptions per meter and per board**, instead of relying on
percentages each board computed about itself. Those percentages were not
comparable between boards: a board hearing every second transmission also derived
a twice-longer average interval and still showed 100%.

The option **`esp_rx_api_enabled` is off by default** and changes nothing about
collection or the normal GUI. Turning it on does two things:

- exposes `GET /api/esp-rx` through the authenticated Ingress WebUI — reception
  summary, per-board sequence continuity and bounded history, with `limit`
  (1–10000), `since` and `until` (UTC epoch, `until` exclusive);
- adds a **Download RX history** button on the Received / Search page, which saves
  the same allow-listed data with the complete retained buffer (up to 100,000
  events) under a UTC-stamped filename.

The export **never** returns RAW telegrams, AES keys or MQTT credentials, and it is
read-only: downloading does not truncate history, reset counters or restart
anything. While the option is off, the endpoint answers HTTP 404.

Sequence gaps prove that an event went missing somewhere between the ESP and the
subscriber. They do **not**, on their own, say whether the cause was the radio,
MQTT, the network or the subscriber.

### Qundis walk-by block (`qds_walkby_enabled`, off by default)

Qundis meters put their whole walk-by payload into a single manufacturer record
(`0DFF5F`, 53 bytes) on CI=0x78 frames. Since the 2026 generation that record is
encrypted **inside the record**, not at the wM-Bus layer: those frames carry no
TPL header, so wM-Bus correctly reports them as unencrypted and nothing marks
them as needing a key.

Two things go wrong without this option, and it fixes both:

- **Random values with `status: OK`.** The decoder decides whether a block is a
  walk-by record by testing one byte, which random encrypted content satisfies
  once in 256 telegrams — roughly every eight hours per meter. It then reads the
  encrypted bytes as a number. On a meter reading 1.387 m³ that produces
  `15430.611`, which silently poisons Home Assistant long-term statistics. With
  the option on, a record that cannot be validated is passed to the decoder with
  its key changed so no driver matches it: the reading is dropped, the meter
  clock still updates.
- **No values at all, with no explanation.** If the meter's AES key is
  configured, the add-on decrypts the block itself and hands the decoder a
  readable record. If it is not, the log says so in as many words, together with
  the meter version, type, CI and the records found.

**The key is the meter's ordinary AES key** — the same one its regular (CI=0x7A)
frames already use. There is no separate walk-by secret; if the regular frames of
that meter decrypt, that key is the one needed here. A wrong key is reported as
such and never produces a fallback value.

With the option off, decoding is byte-for-byte what it was, so an installation
with no Qundis meters is unaffected. See `docs/ARCHITECTURE.md` §3.5.

### Wired M-Bus (serial bus, off by default)

Heat and water meters are often wired rather than radio: an M-Bus master converter
sits on a two-wire bus and presents itself to the machine as a serial port
(USB, RS-232 or RS-485). The add-on can poll such a bus itself.

Everything downstream is the same as for radio — same drivers, units, Discovery,
calculated and constant fields. Only the transport differs: meters are polled
instead of listened to, and they are addressed rather than discovered.

After the first valid reply, a wired meter also appears in **Dashboard** and
**Meters**. The source column shows `M-Bus · <bus alias>` instead of ESP, radio-band
and reception badges, and the Dashboard adds the actual wired path
`meter → serial master → polling wmbusmeters → MQTT + HA`. This path is shown as
active only after the runtime has accepted a telegram, not merely after enabling
the engine.

**Two switches, both off by default.** `mbus_tab_visible` only shows the tab;
`mbus_enabled` starts the engine. With both off nothing changes for you.

| Option | Meaning |
|---|---|
| `mbus_device` | serial port; prefer a `/dev/serial/by-id/…` path |
| `mbus_bus_alias` | bus name in the meter configuration (`MAIN`) |
| `mbus_baudrate` | 300–9600, usually 2400 |
| `mbus_poll_interval` | default interval written into every meter without its own |
| `mbus_donotprobe_all` | leave on — see the warning below |
| `mbus_device_serial` | filled in automatically when you pick a port; lets the add-on notice that a `/dev` node now belongs to different hardware instead of silently polling it |
| `mbus_loglevel` | `normal`, `verbose`, `debug` — for the bus instance only, independent of the main log level |
| `mbus_logtelegrams` | logs every frame exchanged with the bus; useful when a meter stays silent, noisy otherwise |
| `mbus_ignoreduplicates` | drops repeated identical telegrams before decoding |
| `mbus_meters[]` | `id`, `address` (`p1`..`p250` or 8 hex), `type`, `key`, `poll_interval` |

**The add-on never scans ports, deliberately.** Probing means transmitting, and on a
typical Home Assistant machine one of the serial ports is a Zigbee coordinator.
The decoder cannot confirm a correct converter anyway — it only opens the device
and reports success — so the port is always chosen by you.

The selected bus can then be checked explicitly: **Check whether the bus is alive**
sends one test broadcast, **Scan primary addresses** walks only the range you choose
(`p1`–`p250`, at most 32 per request), shows both address acknowledgement and the
immediate data-reply diagnosis for every row, and **Poll once** requests one configured
primary address. All three are refused while regular polling is running because
M-Bus has one master. **Poll once is diagnostic only:** it displays the raw reply,
but does not decode it, publish it to MQTT/Home Assistant or add the meter to the
Pipeline. For normal operation, save a meter, enable the engine, click **Apply**
and restart the add-on. Decoder output from that regular engine is visible in the
read-only **Bus console**; it never accepts arbitrary bytes to transmit.

The meter table's **Driver** field suggests every driver shipped in the current
image while still accepting a custom name. `auto` may identify a meter, but is not
guaranteed to select a useful driver for every wired response; choose the meter's
documented driver when automatic decoding produces no values.
**Detect driver** performs one diagnostic poll and passes the returned frame to
the analyzer in the bundled `wmbusmeters`. A suggestion fills the field but is
never saved automatically: review it and click **Save meters**. If the analyzer
cannot make a reliable suggestion, the UI says so instead of guessing.
Pipeline derives the displayed unit from the actual decoded field name (for
example `_c` → `°C` and `_rh` → `RH%`), including drivers whose telegram has no
cumulative meter reading and therefore uses a generic numeric fallback.

**In Docker** map your converter explicitly:
`devices: ["/dev/serial/by-id/usb-…:/dev/ttyUSB0"]`. Never `/dev:/dev`, never
`privileged`.

**The tab says why nothing is arriving.** On a bus, a wrong address, a dead meter,
a converter that does not power the line and a meter speaking a different protocol
all look the same from the outside: no entities appear. The bus-status card names
which one it is, per meter, together with the moment each one last answered:

- *No reply* — the port is open, the addressed meter stays silent. Address, wiring,
  or a converter that does not feed the bus.
- *Damaged frames* — checksum errors, most often two meters sharing one primary
  address. A meter answering with two different ids is flagged as such: the decoder
  reports no conflict, it simply emits both, and you would otherwise get a second
  device in Home Assistant out of one entry.
- *This is not M-Bus traffic* — bytes are flowing, none of them shaped like an M-Bus
  frame. Typical utility electricity meters with an optical port or RS-485 speak
  DLMS/COSEM (IEC 62056); others use Modbus RTU/TCP. This add-on decodes neither
  protocol. This does not exclude a genuine EN 13757 M-Bus electricity meter for
  which wmbusmeters has a driver. An RS-485 connector alone does not mean M-Bus.
- *A different device is on that port* — the port now resolves to other hardware
  than the one you picked, so polling is refused rather than aimed at somebody's
  Zigbee coordinator.

**Not verified on a real bus.** The protocol was tested against a simulator, not
against real meters — the author has no wired M-Bus hardware. If something does not
work, open an issue; that is the only way it gets fixed.

The **About** view documents both actual data paths and displays the project's
AI-assistance disclosure. The repository copy is [NOTICE.md](../NOTICE.md).

### Tauron / KPL electricity meters (Poland)

These meters put a non-standard prefix where the wM-Bus standard puts the bytes that
confirm a decryption succeeded. Upstream `wmbusmeters` reads that as a wrong key and
discards the whole telegram, reporting *"did you use the correct decryption key?"* even
though the key is correct. This add-on carries a local workaround for it, applied only
to meters whose manufacturer flag is `KPL`.

Configure such a meter with the driver **`amiplus`** — automatic detection will not find
it, because no upstream driver claims this manufacturer.

**Not verified here.** Nobody on this side has such a meter; the workaround rests on a
user report. If you have one, please open an issue with a raw telegram.

## 9. Interface language

5 languages (en/pl/de/cs/sk). Selection: `?lang=en` in the URL → cookie
`wmbus_lang` → `Accept-Language` header → default `en`. Switcher in the top-right.

---

## 10. Troubleshooting

### "Telegrams reach the broker but no entities appear in HA"

Run the **Discovery Doctor** (SETTINGS view): a one-click checklist that
shows the current bridge MQTT state, whether Discovery is enabled and retained,
and how many retained sensor configs exist for each configured meter, including
a sample payload. A received HA birth message is positive evidence that HA uses
that broker and prefix; its absence is inconclusive because the message is not
always retained. Optional canary verification through the HA Core API provides
the stronger check. The dialog also has a **Force re-discovery** button.

### "I want to start over — remove all meters"

In the SETTINGS view, **Reset add-on** removes ALL configured meters, clears
their Home Assistant entities (it publishes empty retained discovery configs so
the entities disappear) and wipes runtime state (candidates, the ignored list
and statistics). The add-on returns to its post-install state. The action is
irreversible and asks for confirmation first.

### "I want to change options without leaving the WebUI"

The SETTINGS view has an editable **Configuration** form for scalar options from
the add-on schema, each with an explanation of what it does. Meters are managed
separately in RECEIVING / SEARCH. Save writes the options through the Supervisor
API in HA add-on mode and directly to
`/config/options.json` in standalone Docker. The MQTT password is write-only
(leave it blank to keep the current value). Core options take effect after a
full add-on/container restart.

### "My meter encrypts its telegrams — what now?"

When LISTEN explicitly reports encryption, the candidate shows an **AES req.**
badge. Without the meter's individual 128-bit AES key (32 hex chars) its payload
cannot be decoded. Where to get the key: your **building
manager / housing association**, the **utility company** that bills the meter,
or the **meter installer**. You can add the meter without the key and enter it
later via the **Driver…** button. When `wmbusmeters` emits a recognized missing-
or invalid-key warning, the bridge records it and shows the corresponding red
status on the meter row. After fixing the key, the pipeline reloads and waits
for the next telegram.

### "I see no telegrams" (RAW count = 0)
1. Is the receiver publishing to `wmbus/<anything>/telegram`? Test: `mosquitto_sub -h <broker> -t 'wmbus/#' -v`.
2. Check the actual startup lines: `MQTT: <host>:<port> topic=<raw_topic>` and `MQTT broker ready`.
3. With `filter_hex_only: true`, non-HEX or odd-length payloads are discarded silently before the RAW counter. If the ESP sends base64/JSON, change the sender format or disable this filter deliberately.
4. Is the broker reachable? Check connection errors (`mqtt_mode`).

### "I added a meter but it does not show on METERS"
It appears only **after the next telegram** for that ID (tens of seconds to a few
minutes). If it still doesn't — check `meter_id`, the driver, the AES key and the logs.

### "A driver is missing from the meter form"
The current schema stores `type` as a free string; it has no fixed allowed-driver
enum. The WebUI catalog is generated from built-in and XMQ drivers in the pinned
`wmbusmeters` build, and the image build fails if the built-in `izar` driver is
missing. Check the active options and select the driver again from that catalog.

### "The status shows «quiet», not red «offline»"
That is intended (honest-witness): a meter is passive, so prolonged silence is
ambiguous (night/away/battery) — we show a neutral state, not a false alarm. The
threshold is derived from each meter's **rhythm**, not a fixed 15/60 min.

### "The value only ever grows, it isn't instantaneous"
The main value shown is the **meter total** (`total_m3`,
`total_energy_consumption_kwh`). If the decoder JSON exposes `total_m3` but no
instantaneous-flow field, the bridge does not synthesize one. Compute
current/periodic consumption in HA with a **Utility Meter** helper (daily/monthly,
survives restarts) or **Derivative** (m³/h). `total_m3` is published as
`device_class: water` + `state_class: total_increasing`, so it also feeds the HA
water/Energy statistics.

### "My meter is encrypted — where do I get the AES key?"
From the meter provider (building manager / water/heat supplier), a sticker or the
meter documentation. Without the key you cannot decode encrypted telegrams.

### "Add meter did nothing" (Docker)
The `./config/` directory must be **writable** (not `:ro`). After adding, the log
should confirm the write to `options.json`. If needed, `docker restart <container>`.

---

## 11. How it works under the hood

**Why decode on the server, not on the ESP?** Projects that embed the decoder
in the ESP firmware keep hitting the same classes of problems: every new meter
model means a firmware update, every ESPHome/toolchain release can break the
embedded decoder's build, and the whole device fleet ends up pinned to an old
ESPHome just to keep one component compiling. Here the ESP carries no decoder
at all, so:

- adding or changing a meter is a WebUI edit — **never a reflash**;
- ESPHome updates cannot break decoding — there is no decoder on the chip to break;
- AES keys stay on the server — the ESP never sees key material;
- the firmware is identical for everyone and its footprint does not grow with meters.

The honest cost: you need an always-on host and an MQTT broker — which a Home
Assistant installation already has. The full rationale, including the
failure-class table, is in
[`ARCHITECTURE.md`](ARCHITECTURE.md#why-decode-centrally).

The `wmbusmeters` integration boundary, telegram flow, process model, runtime
files, soft reload, ESP contract, and dashboard state are described in
**[`ARCHITECTURE.md`](ARCHITECTURE.md)**. Build, CI, decoder upgrades, and the
boundary between the dev and stable repositories are in
**[`DEVELOPMENT.md`](DEVELOPMENT.md)**.

---

## 12. Licence and upstream

**GNU GPL-3.0.** This project contains and modifies code from `wmbusmeters-ha-addon`
(GPL-3.0); the whole — including `webui.py`, `i18n.py`, the rewritten `bridge.sh` —
is distributed under GPL-3.0.

- **wmbusmeters** — https://github.com/wmbusmeters/wmbusmeters (Fredrik Öhrström, GPL-3.0)
- **wmbusmeters-ha-addon** — https://github.com/wmbusmeters/wmbusmeters-ha-addon (GPL-3.0)

A fork developed by **Kustonium**: MQTT input instead of a local dongle, a WebUI in
5 languages, LISTEN/ADD, value filtering, and driver comparison.

---

Questions / bugs → [GitHub Issues](https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge/issues).
