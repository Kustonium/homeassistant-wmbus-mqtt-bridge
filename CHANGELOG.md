## 1.5.60

### Other (review)
- Fix awk boot ID comparisons (26c9b93)

## 1.5.59

### Fixed
- pin the coverage sensor entity_id with object_id (910339b)

## 1.5.58

### Added
- publish per-board meter coverage as an HA sensor (4b32c1a)

### Fixed
- let shellcheck resolve the sourced lib (62710b3)

## 1.5.57

### Added
- let a configured meter be renamed (5348662)

## 1.5.56

### Fixed
- remember which Configuration sections the reader opened (24caf68)

## 1.5.55

### Added
- make the Configuration section collapsible (950e4e8)

## 1.5.54

### Added
- render the ESP configuration snapshot in the panel (59fc422)

## 1.5.53

### Added
- diagnostics tab, and make a silent restart visible (a1aa748)
- classify, validate and decrypt the Qundis walk-by block (opt-in) (f54b550)
- **Qundis walk-by block (`qds_walkby_enabled`, off by default).** Qundis meters
  pack their whole walk-by payload into one manufacturer record (`0DFF5F`, LVAR
  0x35, 53 bytes) on CI=0x78 frames. Since the 2026 generation that block is
  encrypted *inside* the record -- the frame carries no TPL header, so wM-Bus
  correctly reports it as unencrypted and nothing flags it. The new option adds
  a stage ahead of the decoder that:
  - rejects any walk-by record it cannot validate, instead of letting the
    decoder's single-byte gate (`blob[9] == 0x13`) match random ciphertext
    1 time in 256 and publish it as a reading. Verified against wmbusmeters
    3.0.0: the frame from upstream issue #2025 decodes to `total_m3 15430.611`
    with `status: OK` on a meter reading 1.387 m3; through this stage the same
    frame yields only `meter_datetime`.
  - decrypts the block (AES-128-CBC) when the meter's ordinary AES key is
    configured -- the same key its CI=0x7A frames already use, not a separate
    walk-by secret -- and hands the decoder the plaintext record.
  - classifies every telegram as `QDS_PLAINTEXT_OK`, `QDS_ENCRYPTED_PAYLOAD`,
    `QDS_DECRYPT_FAILED`, `QDS_UNKNOWN_LAYOUT` or `QDS_NO_MFCT_BLOCK`, each with
    the meter version, type, CI, the DIF/VIF records found and the reason for
    rejection -- never a bare "no values".
  With the option off the decode path is byte-for-byte unchanged.

### Fixed
- Strict BCD validation on manufacturer-block fields: a nibble above 9 now
  rejects the record instead of being read as a decimal digit. The decoder's
  `extractDVdouble()` maps hex A-F to "digits" 17-22, which is how ciphertext
  bytes `9E D5 FE 13` became the reading 15430.611.

## 1.5.52

### Added
- download retained ESP RX history (2ad37f2)
- expose opt-in ESP RX evidence API (a0fecfc)
- consume structured ESP RX metadata (951912d)
- track per-meter reception by ESP source (0e61a25)

### Fixed
- recognise upstream's own KPL handling by its real name (8e81126)

## 1.5.51

### Added
- decode Tauron/KPL meters via a self-retiring patch to the pinned decoder (3eae103)
- Tauron/KPL electricity meters (Poland) can now be decoded. These meters put a
  non-standard prefix where the standard puts the two bytes that confirm a
  decryption succeeded; upstream `wmbusmeters` reads that as a wrong key and drops
  the whole telegram, reporting *"did you use the correct decryption key?"* while the
  key is in fact correct. The add-on now carries a local patch to the pinned decoder
  that rewrites the prefix — only for meters whose manufacturer flag is `KPL`, and
  only when the exact byte pair matches, so no other meter can be affected.
  Configure such a meter with the driver `amiplus`: automatic detection cannot find
  it, because no upstream driver claims this manufacturer.
  The patch retires itself. It is skipped as soon as upstream grows its own KPL
  handling, and it fails the build if it stops applying, so the monthly pin bump
  cannot quietly ship an image without it.
  A synthetic KPL telegram was constructed to prove the patch does what it claims,
  and it is committed as a golden fixture: without the patch the decoder emits no
  JSON for it and the test fails, with the patch it decodes. Measured A/B on two
  builds of the pinned decoder, and the unpatched run prints the correctly
  decrypted plaintext on the very line where it blames the key.
  **Not verified against the meter.** Nobody here owns one and no raw telegram was
  available; this rests on a user report. What is verified: the patch applies to the
  pinned commit, compiles, and leaves both upstream's own test suite and this
  repository's 14 golden decode fixtures passing. If you have such a meter, please
  open an issue with a raw telegram.

## 1.5.50

### Fixed
- the main README described a radio-only add-on. Wired M-Bus shipped in 1.5.49 and was
  documented in depth in the five user guides and the architecture notes, but the sections
  a first-time reader actually reads — the statement of purpose, the data-flow diagram and
  the key-features list — still described a single MQTT input path. Read against the M-Bus
  tab that the same version installs, the purpose sentence ("decode wM-Bus **without a
  local radio dongle**, using **external receivers** and **MQTT as the input**") was no
  longer true as written.
  Both language halves now name the wired path where the reader meets the project, always
  with all three qualifiers together: optional, off by default, and not verified against a
  real bus. The diagram shows both paths and states where they converge — the entity layer
  never asks where a decoded telegram came from. The add-on description in `config.yaml`
  says so too.

## 1.5.49

### Added
- diagnose replies during address scan (47f43aa)
- detect wired meter drivers (6b99fe6)
- guide engine startup and suggest drivers (31b00a3)
- surface wired meters across dashboard (a1fd3bc)
- add bounded bus diagnostics (c1d2f40)
- show why nothing is arriving on the bus (67bf5c9)
- fence off the M-Bus options in the settings form (b24aed1)
- poll wired M-Bus meters from a serial bus (7fef93b)
- the primary-address scan now combines presence detection with an immediate
  data request. Every scanned address reports both whether it acknowledged and
  whether its reply is valid, ACK-only, foreign, incomplete, checksum-failed or
  multiple, removing the need to click Poll once for every test address.
- wired meters can request a driver suggestion from the analyzer in the bundled
  `wmbusmeters`. Detection performs one bounded diagnostic poll, fills the field
  for review and never saves a guess automatically.
- the ESP8266 wired M-Bus simulator now exposes real upstream `aptmbusna` water
  and `nemo` electricity telegrams on primary addresses p8 and p9. This verifies
  driver detection and distinct volume, flow, energy and power units instead of
  exercising only the original synthetic temperature reply.
- wired M-Bus: the add-on can now poll meters on a serial bus itself, as a third
  wmbusmeters instance next to DECODE and LISTEN. Everything downstream is
  unchanged — the same drivers, units, Discovery and calculated/constant fields —
  because the entity layer never asked where a decoded telegram came from.
  Two independent gates, both off by default: one shows the tab, the other starts
  the engine. With them off the add-on behaves exactly as before, and a machine
  with no bus sees no change at all.
  What the tab does differently from a naive port picker, and why:
  - it **never scans ports**. `detectMBUS` in the decoder only opens a device and
    declares success, so scanning cannot confirm the right one — while on a typical
    Home Assistant machine one of those ports is a Zigbee coordinator, and M-Bus
    polling transmits. `donotprobe=all` is on by default;
  - it stores the **serial number** of the chosen port, not just its path. A `/dev`
    node is reused: after replugging boards, `ttyACM0` pointed at different hardware
    within minutes while every health check still read "ok". If the identity no
    longer matches, polling refuses to start;
  - it prefers `by-id`, but **falls back to `by-path`** when two identical adapters
    claim the same `by-id` link. That link then names one of them and there is no
    way to tell which — measured with two CH340 cables;
  - it warns about devices people genuinely mistake for a converter: an RTL-SDR, a
    DVB-T tuner, a Zigbee coordinator, and the user's own ESP bridge, which appears
    in the list right next to the real thing;
  - `rssi_dbm` is stripped on this path. The decoder emits it as `0` on a wire,
    which would create a "0 dBm signal strength" entity for a meter with no radio;
  - one **bus probe** (broadcast `0xFE`) answers "is anything on this cable at all"
    without scanning 250 addresses. With several meters the replies overlap and come
    back damaged — that is what a broadcast does, and the UI says so rather than
    reporting a healthy bus as broken.
  The tab states plainly that it is **not verified on a real bus**: the protocol was
  tested against an ESP8266 M-Bus slave simulator across silence, late replies,
  foreign protocol, damaged frames, two meters on one address and a full port
  loss/recovery cycle — but not against anyone's actual meters. Reporting an issue
  is the only thing that changes that, and the tab asks for it.
  Every M-Bus option now carries a name and a description in the add-on
  configuration UI instead of a bare key, in English and Polish. The first one
  states what the whole block is not: an RTL-SDR, a DVB-T stick or a wM-Bus radio
  dongle does not belong here and will not work — radio is received by the ESP and
  arrives over MQTT exactly as before.
- the M-Bus tab now shows a **bus-status card**: what the bus is doing, how many
  meters are polled and rejected, and per meter the last id seen and when it last
  answered.
  On a wire, a wrong address, a dead meter, a converter that does not power the
  line and a meter speaking a different protocol all produce the same symptom —
  nothing arrives. The decoder does distinguish them, but only in its own log, so
  the card names the cause: no reply, damaged frames (usually two meters sharing
  one primary address), traffic that is not M-Bus at all (electricity meters
  normally speak DLMS/COSEM, which this add-on does not decode), or a port that now
  resolves to different hardware than the one selected.
  A meter answering with two different ids is flagged as such. The decoder reports
  no conflict — it simply emits both telegrams — which would otherwise turn one
  configured entry into a second device in Home Assistant. "Last answered" is
  counted from the arrival of a telegram, because there is no timeout on this path:
  a reply three seconds late for a two-second `pollinterval` is still accepted.

### Fixed
- wait for slow driver detection replies (35d8390)
- preserve decoded units and expand simulator coverage (747313c)
- refresh USB ports and repair option saving (966825d)
- align engine guidance with process state (9a9b2fe)
- make the wired tab readable and structured (83ff694)
- tell the user what to do when polling cannot start (d81d481)
- make the tab reachable and label every option (e9ed9bf)
- Poll once and driver detection now share the diagnostic scan's adaptive
  3.5-second reply window. A slow but valid meter no longer times out before its
  telegram arrives, while ordinary replies still return after 200 ms of bus idle.
- generic decoded values retain their real JSON field name instead of the
  synthetic key `value`, so Pipeline can derive units such as `°C`, `RH%` or
  `bar`. Current readings are preferred over averages/history: the live wired
  `piigth` test now selects `temperature_c=23.02` instead of the earlier
  `average_temperature_1h_c=23.52`, and displays `23.02 °C`.
- wired M-Bus guidance now distinguishes unsupported utility electricity meters
  using DLMS/COSEM (IEC 62056) or Modbus RTU/TCP from genuine EN 13757 M-Bus
  electricity meters, and warns that an RS-485 connector alone does not identify
  the protocol; the earlier blanket wording was too broad.
- the wired meter form no longer leaves users to type a driver name blindly. It
  suggests the driver catalog baked from the exact `wmbusmeters` build in the
  image, while preserving `auto` and custom names. Catalog entries are
  de-duplicated case-insensitively, so the special `auto` choice appears once.
- the M-Bus tab now states that **Poll once** is raw diagnostics only and cannot
  populate Pipeline, MQTT or Home Assistant. A saved meter with polling disabled
  shows the exact normal-operation sequence: enable, apply and restart.
- the wired M-Bus health state was computed and thrown away. It is established in
  the subshell that reads the decoder's output, so the parent shell never saw it
  and the WebUI — a different process again — could not reach it at all. The state
  now travels through `status_mbus.json`, and the function that pretended to return
  it is gone.
- the banners in the M-Bus tab were unstyled: the CSS classes they used had never
  been defined, so every one of those messages rendered as plain body text —
  including the "not verified on a real bus" notice, which is the one thing on that
  page that must not read as decoration.
- a malformed poll interval no longer reaches a meter file. The option is a free
  string, so the add-on configuration page accepts `15` as readily as `15m`, and a
  meter that is never polled looks exactly like a dead one. It now falls back to
  the default with a warning instead of taking an otherwise valid meter out of
  service.
- `tests/test_mbus_meter_files.sh` was never run by CI — the test that caught the
  atomic-write bug during development was not on the static-tests list. It is now,
  and it covers the status file, the counts and the address clash.

## 1.5.48

### Added
- insert field templates with one click (04412ec)
- attach constant fields to a meter (upstream field_) (ee9ebc2)
- edit calculated_fields from the meter modals (b89c15e)
- pass the decoder's calculate_ fields through to the meter file (2fe978e)
- one-click templates for both field options, and the rule behind the names. The key
  before `=` is the name the field gets in Home Assistant, so it cannot be guessed for
  the user — but it can be offered: a chip appends the template and puts the caret
  after it, leaving only the value to type. A chip whose name is already in the box
  only moves the caret there rather than duplicating it. The calculated templates are
  whole formulas, because a starting point that already balances its units teaches
  more than a bare name.
  While building them, the decoder settled a question worth documenting: for a
  CALCULATED field the name is not free-form. It must end in a unit, and that unit
  converts the result — from one formula, `difftemp_c` returns 11 and `difftemp_f`
  returns 51.8 for the same 11 °C source. A name with no unit or an unknown one is
  refused with "Could not extract a valid unit from calculated field name", the field
  is not created, and the meter keeps decoding. Constant fields carry no such rule:
  any name is accepted, since nothing is converted.
  A constant left at its inserted template (`location=` with no value) is dropped on
  save instead of refusing it: clicking several chips and filling some in is how they
  are meant to be used, and rejecting the save would also discard the driver and key
  edited in the same modal. An empty formula still errors — that is a typo, not an
  unused template — and a malformed field name is still refused in both.
- `static_fields` per meter: constant values attached to a meter, which upstream has
  always supported as `field_<name>=<value>` in a meter file and which this add-on,
  like the formulas, used to erase on every reload. Useful for the label a decoded
  telegram cannot carry — a location, an apartment number, a riser. Verified against
  the pinned decoder before implementing: it copies the value into the JSON **as
  text**, so `apartment=12` arrives as `"12"`, and a value may contain spaces. That
  makes such a field a diagnostic entity and an attribute on every entity of that
  meter, which is the honest description of what it is: a label, not a measurement.
  Same entry shape as the formulas (`name=value`, semicolon separated) and the same
  guarantees: the shape is validated, a malformed entry is skipped with a warning
  naming the meter, and no entry can inject a second key into the generated file.
  Editable from both meter modals in all five languages.
- `calculated_fields` per meter: extra fields the DECODER computes from the telegram,
  such as a flow/return temperature difference. Nothing here does arithmetic — the
  formula engine is upstream's and always was. `wmbusmeters` accepts
  `calculate_<name>=<formula>` in a meter config file and publishes the result as an
  ordinary JSON field, which then becomes a Home Assistant entity through the normal
  Discovery path, unit and device class included. What blocked it was this add-on:
  `refresh_meter_files` deletes and rewrites every `meter-*` file on start and on
  every soft reload, writing only `name`, `id`, `key` and `driver`, so a hand-added
  `calculate_` line survived seconds. It is now carried through from the add-on
  configuration instead. Entries are semicolon separated, `name=formula` each, because
  a formula contains both spaces and commas. Only the shape is validated here —
  whether the formula makes sense stays the decoder's judgement, and it reports a bad
  one itself rather than being second-guessed by a worse copy of its grammar. A
  malformed entry is skipped with a warning naming the meter, and cannot inject a
  second key into the generated file. Verified end to end against a real telegram
  from the replay corpus (Kamstrup KWM2231, `kamwater`, id 53119425): the generated
  meter file went through the pinned decoder with `--useconfig`, exactly as
  `bridge.sh` runs it, and the JSON came back carrying
  `"difftemp_c":7` next to the decoded fields. Two behaviours found while doing so
  and now documented: the arithmetic is unit-aware, so `total_m3 * 2` is rejected
  while `total_m3 / 2 counter` is not, and a formula the decoder cannot parse costs
  only that field — it is reported in the log and the rest of the meter decodes
  normally.

### Fixed
- drop unfilled constant-field templates instead of refusing the save (dde1182)
- raise the contrast of small hint text (ec7fc26)
- make modal text inputs use the full width (eb93614)

## 1.5.47

### Added
- offer the upstream issue report for configured meters (7cd8660)
- join opt-in per-meter RSSI onto the decoded telegram (08177ee)
- toggle a field's entity from the METERS field panel (9f43e9a)
- the upstream issue report is available for configured meters, not only for
  candidates: METERS now carries the same **Report…** button in every row. Asked for
  by a user who had added a meter and then had no way to look at its raw frame,
  and needed by anyone whose meter decodes but reports a field wrongly — until now
  reporting that meant removing it from the configuration first. A configured meter
  has no candidate RAW row, so the frame comes from the rolling all-frames buffer
  matched on the id in little-endian order (`_resolve_raw_for_id`, the same lookup
  the driver comparison uses, and one that also works for Diehl-style frames whose
  A-field does not parse). The driver comes from the meter's own configuration, the
  medium from its last decoded telegram, and the manufacturer is read back out of
  the analysis. The AES key is still never part of the report.
- optional signal strength per receiving board. A telegram carries no RSSI — the RAW
  topic is bare hexadecimal, so `wmbusmeters` never sees a level and cannot report
  one — which is why the value has to travel out of band. When the firmware YAML
  enables it (`wmbus_radio: publish_rssi: true`, **off by default**), each board
  publishes `wmbus/<board>/rssi/<meter_id>`; the bridge caches it per meter *and*
  per board and joins it onto the decoded telegram as `rssi_<board>_dbm`, so every
  receiving board gets its own `signal_strength` entity for the same meter. Only
  plausible measurements (-125 to -1 dBm) are stored — the firmware's "no data"
  sentinels are dropped — and a cached value older than `RSSI_MAX_AGE_S` (300 s) is
  not attached, so a board that stops publishing goes unavailable instead of
  freezing on its last reading. With the option off nothing arrives and no entity
  is created. Documented in the localized READMEs and in `ARCHITECTURE.md`.

### Changed
- the merged `rssi_dbm` and `rssi_source` fields are gone; only the per-board fields
  remain. `rssi_dbm` was kept as a compatibility value meaning "whichever board
  reported last", which is exactly what makes it unreadable: with two boards hearing
  the same meter, one entity alternated between their levels and looked like a
  fluctuating signal rather than two receivers. `clean_legacy_entities()` (formerly
  `clean_legacy_totalm3`) now also clears the retained `rssi_dbm` config, so the
  entity disappears from installations that already created it during this dev
  cycle.

### Fixed
- translate the decode-mode strings into de/cs/sk (333af33)
- mark driver fields that can never become entities (7d27997)
- keep only the per-board RSSI entity (c90b00c)
- reject the firmware's "no data" sentinels as RSSI readings (3e28fa1)
- the decode-mode strings existed only in English and Polish, so the German, Czech
  and Slovak WebUI fell back to English for the whole "candidate data is stale"
  explanation — the one place where the numbers on screen need a caveat to be read
  correctly. All five languages now carry the same 547 keys.
- the driver field table offered ten fields that can never become an entity here.
  Reported from a live install running `apatorna1`: every field was ticked, yet
  `timestamp_ut`, `timestamp_lt`, `timestamp_utc`, `device` and `rssi_dbm` never
  appeared, and unticking `media`/`timestamp` changed nothing. The table is
  `wmbusmeters --listfields`, which is the driver's whole catalog rather than what
  this path publishes, and every driver's catalog opens with the same ten universal
  fields. Three of them are timestamps wmbusmeters deliberately keeps out of JSON
  (they exist for the CSV/`fields` formats); `device` and `rssi_dbm` are written
  only when a radio device received the telegram, which never happens when the
  decoder is fed through `stdin:hex`; the remaining five are the meter's identity,
  which `emit_discovery_from_json` has always kept out of the entity list because it
  is the device name and travels in every entity's attributes. Those rows now stay
  visible but lose their checkbox and state the reason, so the panel no longer
  promises a publish it cannot perform. The decoder's own `rssi_dbm` is unrelated to
  the opt-in per-board RSSI this add-on joins on as `rssi_<board>_dbm`.

### Other (review)
- Document per-ESP RSSI entities (298f8cf)
- Add per-ESP RSSI entities (e48dd3e)

## 1.5.46

### Added
- expose the driver's field description as an entity attribute (d12b909)
- pick fields to publish from the driver's own field catalog (44dc591)
- edit exclude_fields from the WebUI meter modals (5f2c452)
- use the add-on icon as the WebUI brand mark (5fba20d)
- let a meter exclude fields from Home Assistant Discovery (5dd37b7)
- add the add-on logo shown above the name (b040350)
- entities carry the driver's description of their field as a `Description`
  attribute. `wmbusmeters --listfields=<driver>` prints one line per field with the
  text its author wrote; the bridge loads that catalog once per driver — the
  decoder binary is pinned, so it cannot change while the container runs — and
  matches it against the decoded field name with a glob, because the catalog names
  repeated fields with a placeholder (`consumption_at_history_{storage_counter-7counter}_m3`).
  An entity has exactly one `json_attributes_topic`, already pointed at the state
  topic so the whole decoded telegram reaches the attributes. The description is
  therefore merged in through a `json_attributes_template`
  (`dict(value_json, Description="…") | tojson`) rather than replacing that
  pass-through — replacing it would have cost every other field. A field the
  catalog does not describe keeps the plain pass-through with no template, and if
  the decoder cannot be queried the descriptions are simply absent. Quotes and
  backslashes are stripped from the text before it is embedded in the Jinja
  literal. Requested on the forum alongside the field list.
- the meter modals list every field the driver can report, with the description
  wmbusmeters ships for it, and a checkbox per field. The catalog comes from
  `wmbusmeters --listfields=<driver>` through a new `api/driver-fields` endpoint,
  cached per driver for the life of the process because the decoder binary is
  pinned. It covers fields the meter has not sent yet, which the entity list
  cannot: entities exist only once a telegram carried the field.
  Unchecking a field adds its name to `exclude_fields`; a field already covered by
  a hand-written pattern is greyed out with its checkbox disabled, so the table
  never rewrites a pattern someone typed. Templated names such as
  `total_volume_subunit{subunit_counter}_m3` contribute the equivalent glob
  (`total_volume_subunit*_m3`) — the braces are a placeholder for a repeated
  field, not a literal name, and the backend validator rejects them.
  Saving also drops entries another entry already covers: a plain field name is
  redundant next to a glob that matches it, and mixing the two is the normal
  outcome of clicking rows while a pattern is typed in the box. Keeping both is
  not merely untidy — the name outlives the glob, so removing `history_*_date`
  would leave `history_reference_date` excluded on its own and the click would
  look ignored. Globs are never dropped, not even by wider globs: losing a
  pattern someone wrote by hand is worse than storing a redundant one.
- the add-on icon is now the WebUI brand mark. The sidebar drew a green square with
  the letters `WB`, a placeholder from before the project had artwork. `icon.png` is
  copied into the WebUI assets by the `Dockerfile` rather than duplicated under
  `rootfs/`, so the tile in the add-on store and the mark in the panel stay the same
  file. If the asset cannot be loaded the `WB` square comes back, so an older
  container shows a brand mark instead of a broken image.
- per-meter `exclude_fields`: glob patterns for decoded fields that should get no
  Home Assistant entity, comma- or space-separated (e.g.
  `consumption_at_history_*, history_*_date`). Empty publishes every field, which is
  what every earlier version did, so an upgrade changes nothing on its own. Prompted
  by a forum observation on the 1.5.45 behaviour: publishing every driver field is
  right for most meters, but a driver like `evo868` reports twelve monthly history
  readings plus twelve matching dates on every telegram, and a household with a
  dozen such meters drowns in entities. One pattern now replaces twenty-four of
  them. Excluding `status` also removes its problem `binary_sensor`, since a problem
  flag without the status it reports on is worse than neither. An excluded field is
  removed rather than merely skipped: the bridge publishes an empty retained config
  for it once, so entities created before the pattern was added disappear instead of
  lingering until they expire — with the consequence that the entity's recorder
  history goes with it. The patterns are rebuilt by `refresh_meter_files()`, which
  is also the soft-reload path, so editing a meter takes effect without restarting
  the container. The patterns are entered in the WebUI, in the **Add meter** modal
  and in **Driver…** for a meter that already exists, so the option lives next to
  the meters it applies to; the add-on Configuration tab still works but needs a
  restart, because Supervisor only writes `options.json` on add-on start.
- add-on logo (`logo.png`, 1482x160). Home Assistant draws `logo.png` at the top of
  the add-on page, above the name — with the file missing, the page showed the name
  alone while add-ons like InfluxDB show their wordmark. Supervisor reads it from the
  directory that holds `config.yaml`, the same place as `icon.png`. It is built from
  the icon's own palette and motifs — navy panel, water-meter dial, wifi arcs —
  rather than repeating the wordmark that the icon already contains. The panel is
  opaque on purpose: a transparent logo with white lettering disappears on the light
  Home Assistant theme.
  The proportions follow the frontend rather than the ~250x100 the documentation
  suggests. `supervisor-app-info.ts` renders the file with
  `img.logo { max-width: 100%; max-height: 40px }`, so height is the binding limit
  and the only thing that decides how large the name looks is the share of the file's
  height taken by the lettering. For reference the InfluxDB add-on logo is 300x69
  with content touching both edges, its wordmark filling 74% of the height — about
  29 px on screen. Two earlier attempts here spent that height on padding and a
  second text line and drew roughly 10 px. The type size is now fitted so the cap
  height is 60% of the canvas, giving about 24 px on screen; the file is wide
  (9.4:1) because the name is 17 characters against InfluxDB's 8. No behaviour
  change.

### Fixed
- parse the field catalog without a GNU sed extension (8decf21)
- drop exclude_fields entries another entry already covers (bb3adef)
- give the logo mark clearance inside the panel (df84b0e)
- fit the logo wordmark to the height the frontend allows (e5cd306)
- size the logo for how the add-on page renders it (d05dd2b)
- the `Description` attribute never appeared. The catalog parser split
  `--listfields` output with `sed -E 's/[[:space:]]{2,}/	/'`, which relies on GNU
  sed turning `	` in the replacement into a tab. The add-on image is Alpine and
  ships busybox sed, so the field names parsed into nonsense, nothing matched, and
  every entity silently kept the plain pass-through. Parsing is now done with bash
  parameter expansion, which depends on no sed dialect at all. The gap was in the
  tests as much as in the code: they injected `FIELD_CATALOG` directly and never
  ran `load_field_catalog`, so the only untested step was the one that broke. A
  case now feeds a stub reproducing the real column layout — padded names,
  descriptions with single spaces, a templated name and a field with no
  description — through the parser and the glob lookup.

## 1.5.45

### Added
- publish every driver field, split measurements from diagnostics (a8d357c)
- publish discovery entities for text fields, disabled by default (1a6fe07)
- ship an add-on icon instead of the generic placeholder (f0dbd8e)
- Discovery entities for the decoder's text fields, published disabled. Until now
  `emit_discovery_from_json` created an entity only for JSON fields of type
  `number`, plus the dedicated pair for a field named exactly `status`. A meter
  whose driver reports its state under a different name (`apatorna1`:
  `current_status`, `frame_status`, `historic_status`, plus `meter_datetime` and
  `historic_datetime`) therefore showed those values on the WebUI METERS tab but
  had no matching entity in Home Assistant — the data was reachable only through
  the entity attributes fed by `json_attributes_topic`. Every remaining string
  field now gets its own `sensor` config with `entity_category: diagnostic` and
  `enabled_by_default: false`, so Home Assistant registers it and lists it on the
  device page switched off; the user enables the ones they want. Numeric fields are
  untouched (same unit/device_class/state_class guessing, still enabled), and
  `status` keeps its existing text sensor plus `problem` binary sensor — it is now
  excluded from the generic loop so the two paths cannot publish to the same config
  topic. `enabled_by_default` is read by Home Assistant only when it first adds an
  entity to its registry, so upgrading changes nothing for entities that already
  exist.
- add-on icon (`icon.png`, 256x256). Home Assistant was drawing the generic puzzle
  placeholder because the repository carried no icon file at all; Supervisor reads
  `icon.png` from the directory that holds `config.yaml`. The source artwork is a
  rounded square sitting on an opaque black JPEG background, which would have shown
  up as a black tile on the light theme, so the corners are transparent in the PNG
  and the tile now matches both themes. No behaviour change.

### Changed
- Discovery now publishes **every** field the driver exposes, and splits entities by
  what they measure instead of by JSON type. A numeric field that Home Assistant can
  classify (`guess_device_class` returns a class) or that carries a consumption unit
  stays a plain measurement sensor; everything else — numbers with no class (record
  ages, error counters), text fields and fields the driver currently reports as
  `null` — is published with `entity_category: diagnostic` and
  `enabled_by_default: false`. The consumption-unit check (`is_consumption_unit`:
  m³, GJ, MJ, kWh, Wh, l) exists because `guess_device_class` deliberately returns
  an empty class for m³ on heat and cooling meters, and GJ/MJ have no Home Assistant
  device class at all — without it a heat meter's consumption would have been filed
  as a diagnostic. Motivated by a `hydrodigit` report: `fraud_date` and `leak_date`
  arrive as JSON `null` until the event occurs, so the type filter dropped them
  entirely; they now exist as diagnostic entities that stay `unavailable` until the
  meter fills them in. Only container values (`object`, `array`) and the meter's
  identity (`id`, `name`, `meter`, `media`, `timestamp`, `rssi`, `lqi`) are still
  skipped. NB the two flags behave differently on upgrade, deliberately: Home
  Assistant reads `enabled_by_default` only when it first adds an entity, so nothing
  you already have gets disabled, while `entity_category` is re-applied on every
  config update, so unclassified numeric fields created by an older version move
  into the device's Diagnostics section.

### Fixed
- treat hca and reactive/apparent energy as consumption units (a2c511c)
- heat cost allocator readings were filed as disabled diagnostics. `hca` — the unit
  of an `fhkvdataiii`-style allocator, and the only value such a device bills on —
  has no Home Assistant device class, so the measurement-versus-diagnostic split
  introduced in this cycle sent `current_hca` and `previous_hca` to the Diagnostics
  section with `enabled_by_default: false`, leaving the allocator with nothing but
  its two temperatures as ordinary sensors. Found on a live test instance replaying
  simulated telegrams. `is_consumption_unit` now also covers `hca`, plus `kVARh` and
  `kVAh`, which are cumulative billing quantities with no HA device class either.
  NB Home Assistant reads `enabled_by_default` only when it first adds an entity, so
  an allocator entity already created as disabled has to be enabled by hand once;
  the category change to a plain sensor applies on the next telegram.

## 1.5.44

### Added
- show the wM-Bus band (T1/C1/S1) a meter was received on (9d30fa6)

### Removed
- vendored snapshot of the upstream wmbusmeters add-on (`wmbusmeters-mqtt-stdin/`,
  267 files, 2.2 MB). It was imported as a reference in May 2026 and never wired
  into this add-on: the `Dockerfile` does not copy it into the image, no script or
  workflow reads it, and it was excluded from ShellCheck CI, so it could not affect
  behaviour. Its subsystems are all superseded — Home Assistant Discovery is
  generated at runtime from the decoded telegram by
  `rootfs/usr/bin/bridge-lib/09-discovery.sh` instead of from the 37 per-driver JSON
  templates, and the WebUI is served directly by `rootfs/usr/bin/webui.py` on the
  ingress port instead of by the bundled Flask/nginx/Ace stack. The snapshot also
  carried third-party assets (Ace editor, Bootstrap) with no origin or licence note,
  which this repository should not redistribute unattributed. No user-visible change.
  The files remain retrievable from git history at commit `07edb6c`.

## 1.5.43

### Fixed
- time out preview rows stuck in "pending" state (9f76b46)

## 1.5.42

### Added
- publish multi-arch manifest for standalone Docker image (d8851ce)

## 1.5.41

### Fixed
- graceful broker auth-failure — reconnect backoff + runtime WebUI banner (989552a)
- candidates silently dropped after factory reset (missing status_candidates.tsv) (93a5f7c)

## 1.5.40

### Added
- one-shot broker probe at Docker entrypoint startup (diagnose offline reason) (b53a5f5)
- working WebUI restart button in Docker standalone (SIGTERM to PID 1) (b497cca)
- surface run.sh broker-resolution failures as an actionable WebUI banner (e31ba43)
- real broker detection in mqtt_mode=auto (probe known broker add-ons) (528b415)

### Changed
- probe broker add-ons before the 60 s Supervisor-service wait in auto (28485c0)

### Fixed
- align default raw_topic to wmbus/+/telegram in Docker standalone (4f2d5c8)

## 1.5.39

### Added
- edit add-on options from WebUI Settings, generated from the schema (78e4b51)

## 1.5.38

### Added
- Status diagnostic entities for every meter that reports a `status` field: a
  text sensor with the raw status and a `binary_sensor` (`device_class: problem`)
  that turns on for any non-`OK` state. Both appear in the device's Diagnostics
  section and are removed together with the meter. The status text is passed
  through verbatim from wmbusmeters, so richer drivers expose more detail — e.g.
  `elf2` decodes the full heat-meter error flags (`DIFFERENTIAL_TEMPERATURE_TOO_LOW`,
  `TEMPORARY_ERROR`, …) while the older `elf` driver reports only the generic TPL
  status. Documented in README and docs/ (EN/PL/DE/CS/SK) and ARCHITECTURE.md.

## 1.5.37

### Added
- compare meter driver decodes on demand (98d448a)
- add factory reset that removes all meters and clears their HA entities (a2e713b)

### Fixed
- clarify driver compare modal layout (b9fcfd1)
- compare candidate drivers before adding meters (3224769)
- compare selected driver against wmbusmeters auto hint (67e32d4)
- keep compare modal from breaking WebGUI render (03f96c7)
- scope published-fields expander to action-enabled meter tables (d3fceee)
- keep built-in drivers and publish discovery before state (5fa0ce4)
- resolve preview id by LE-substring match on the per-telegram path (Diehl/izar) (dd3ffee)

## 1.5.36

### Added
- AES lock badge under meter id; validated key field in change-driver modal (9d09334)
- surface AES key problems for encrypted meters (roadmap task 4) (7c91d32)

### Fixed
- doctor checklist hides the hint on passing checks (f01ddaa)
- gate diffs the whole push range, not only the last commit (3258561)
- Discovery Doctor prefix check uses canary verification and honest unknown state (f448e7b)
- prefix check in Discovery Doctor also accepts the live HA birth signal (3ab1b78)

## 1.5.35

### Added
- decrypt issue-report analysis with the configured AES key (1a37d14)
- published-fields expander on the meters view (ecbded7)
- issue-report export, driver picker and post-add driver change (2d22724)
- per-field availability template in MQTT Discovery configs (afb096d)

### Fixed
- hold live table re-render while the pointer is over a table (9205126)
- pass prune python program via -c (stdin heredoc broke in production) (6adb814)
- add change-driver action to the configured-on-air table (264bca5)
- browsable driver select, input validation and modal click-close bug (1e206cf)
- lowercase meter id in izar fixture test (id match is case-sensitive) (9a5c3b5)
- pin wmbusmeters build to last known-good commit 8c35c4a1 (171e0d1)

## 1.5.34

### Added
- prune long-silent candidates from status_candidates.tsv (24h) (c8dc73c)
- sink no-reception candidates to the bottom + media-group dividers (909ea78)
- stable candidate sort — group by media, then telegram count, then id (71640fc)

### Fixed
- align candidate silent-detection with the age-adjusted UI counters (2ba28b0)

## 1.5.33

### Fixed
- Meters whose wmbusmeters driver was added after the add-on's options schema
  was frozen (notably Diehl/Izar `izarv2`) were rejected when saved (Supervisor
  HTTP 400 "value must be one of …"), so they fell back to a file-only write and
  silently disappeared on the next restart/upgrade. The `meters[].type` field is
  now a free string, so any current wmbusmeters driver is accepted.

### Added
- Opt-in Home Assistant entity verification (`verify_ha_entities`, off by
  default): the add-on can ask the HA Core API whether its discovery entities
  were actually created. Enabling it grants read-only HA Core API access
  (`homeassistant_api`). This brings the stable schema/permissions in line with
  the development build (promote now syncs config.yaml, so they no longer drift).

## 1.5.32

### Added
- adaptive per-meter status from its cadence; silence never red (b2477b0)

### Fixed
- keep reception counts continuous across candidate->meter promotion (2d4d8a8)

## 1.5.31

### Added
- Per-ESP reception quality for each configured meter: the dashboard now shows,
  per receiver, the reception % and the telegram count for a meter, sourced from
  the ESP's opt-in diagnostics (`meter_snapshot` and the more frequent
  `meter_window`). It populates within minutes and scales to any number of ESPs.
- Reception badges (the ESP flag and per-ESP reception %) shown in the reception
  column across all meter tables, stacked one per line, with a legend on the
  column header explaining what each marker means.
- Bulk removal of configured meters via per-row checkboxes and a toolbar action.

### Changed
- ESP devices silent for over 12 h are dropped from the "Connected ESP" list
  (e.g. after a topic_name rename), while a recently stopped ESP stays visible
  and still raises the "pulse stopped" verdict.

### Fixed
- Removed the RSSI signal-strength band: field testing showed RSSI is not
  trustworthy across boards, so reception % — not RSSI — is the quality signal.
- Corrected the "configured meters on air" panel subtitle: the 15m/60m counters
  come from the decode instance (primary wmbusmeters), not the parallel listen
  instance.
- Made the pipeline expand affordance readable (triple chevron).


## 1.5.30

### Added
- Always-on ESP radio-path status in the dashboard, independent of the ESP's
  `diagnostic_mode`. The ESP firmware now publishes, every 60 s, a health pulse
  (`wmbus/<device>/health`) and the set of meters it is configured for
  (`wmbus/<device>/meters`). The WebUI turns these into:
  - a per-ESP "radio alive / receiver hearing" verdict taken from the pulse — so
    it reflects that the receiver actually hears telegrams, not merely that the
    firmware's main loop runs — with an aggregate that names a stopped ESP instead
    of hiding it behind a healthy total, surfaced on both the workspace and the
    pipeline tile;
  - a "ESP" badge on meters and candidates the ESP is explicitly flagged for
    (`target_meter_id` / `highlight_meters`), so an ESP-vs-add-on configuration
    mismatch is visible at a glance.
  This works even with ESP diagnostics off, and stays honest-witness throughout:
  missing or stale data degrades to a neutral state and is never shown as a green
  "all good".

### Fixed
- "Pulse stopped" is distinguished from "firmware without the pulse": an ESP that
  was seen and then goes silent reports that it stopped (powered off / lost
  connection) instead of a misleading "update the ESP firmware".
- Severity ordering of the radio verdict is correct: a stopped pulse degrades the
  pipeline tile green → amber only while the ESP is otherwise online; a fully
  offline ESP source stays red rather than being softened to amber.
- The per-ESP radio health no longer overwrites the device STATUS column (which
  made every row read as "offline" while telegrams were arriving).
- A focused pipeline tile no longer freezes: the live-update DOM patch now
  preserves only focused form inputs, not buttons, so a tile keeps refreshing
  after it is clicked to open its workspace.
- The ESP health/meters subscribers no longer abort under `set -euo pipefail`
  when their status file does not exist yet, which previously stopped the file
  from ever being created on first run (so the meter-flag badge never appeared).


## 1.5.29

### Added
- MQTT→HA healthcheck: the add-on now detects when it publishes to a broker
  that Home Assistant does not consume (a common "my meters never appear in HA"
  cause). HA presence is reported honestly — confirmed on the native HA broker
  (`core-mosquitto` / `mqtt_mode=ha`) or via a seen `online` birth message — and
  the MQTT tile shows broker identity read from `$SYS` (Mosquitto / EMQX, native
  / external) with a diagnostics panel (software, version, connected clients,
  HA-on-broker, TLS support).
- Opt-in HA entity verification (`verify_ha_entities`): the add-on publishes a
  hidden diagnostic canary entity and asks the HA Core API whether it was
  actually created, giving a definitive verified / not-created verdict with an
  actionable reason in the HA panel, instead of inference. Uses `homeassistant_api`
  only when the option is enabled.
- Stale-data detection: a liveness heartbeat distinguishes "bridge alive but
  idle" from "bridge down". When the bridge stops updating, the dashboard shows
  a STALE badge, a banner, and greys the pipeline tiles rather than displaying a
  stale green snapshot.
- The ESP tile lists all active ESP devices, and the wmbusmeters panel shows the
  running wmbusmeters version.
- A dedicated zero-meter LISTEN instance keeps candidate manufacturer/identity
  visible even with meters configured.

### Changed
- `mqtt_mode=auto` now honours an explicitly configured `external_mqtt_host`
  over HA's own Mosquitto — if you configured an external broker, it is used.
- ESP online/offline is driven by live telegram flow as the primary signal;
  optional `diag/*` topics only refine it.

### Fixed
- Honest-witness corrections to the healthcheck: birth-message absence no longer
  raises a false "no HA on broker" alarm; a non-native broker without
  confirmation shows neutral "HA unconfirmed" instead of a green "published" lie;
  the canary is queried via the HA Template API (robust against entity_id
  slugification) rather than a guessed entity_id.
- The bridge waits for the HA MQTT service to return instead of FATAL-looping on
  a broker restart; the heartbeat and ESP / `$SYS` subscribers survive soft
  reloads; pipeline tiles grey out while stale and MQTT-wait log spam is thinned.
- Candidate/preview pipeline hardening: LISTEN reloads are coalesced with a
  trailing debounce to stop discovery churn; candidates are registered from the
  RAW path when meters are configured (closing a discovery dead zone); AES
  classification is preserved on the RAW path (no bogus preview for encrypted
  meters); full manufacturer names are filled from the FLAG code; a `BASH_REMATCH`
  unbound-variable crash and a decoded-JSON reload churn are fixed.
- The WebGUI no longer double-logs "Meter X saved" / "Search X" events.


## 1.5.28

### Added
- detect missing Home Assistant on the MQTT broker (MQTT→HA healthcheck) (eae89c7)


## 1.5.27

### Fixed
- The dashboard ESP pipeline tile could show a contradictory "Offline · N/min"
  state — reporting the receiver offline while telegrams were actively flowing
  through the bridge. The ESP online/silent/offline state was derived solely
  from `sourceDeviceObj.health`, which `webui.py` computes from
  `last_telegram_epoch` in `status_esp_telegram_devices.tsv`; that file is
  written by a separate `mosquitto_sub` in `bridge-lib/13-esp.sh`, so when that
  secondary subscriber lags or reconnects its epoch ages past the offline
  threshold even though the primary pipeline keeps receiving telegrams. Fixed in
  `rootfs/usr/share/wmbus-webui/assets/app.js` (`pipelineHeader`): a live
  telegram rate (`hasLiveRate`, i.e. `rate_current_min > 0`, which `webui.py`
  already zeroes once older than 90 s) now takes precedence for `espOnline` and
  `espSeen`, while the per-device `health` from the tracker TSV only refines the
  state when no live rate is available. Telegrams are the primary sign of life;
  the optional `diag/*` topics remain auxiliary. The per-ESP device list in the
  workspace panel still shows each device's tracker-based health.

### Changed
- The `media_water` label was simplified from "cold water" to "water" in the
  Polish, German, Czech and Slovak translations (`rootfs/usr/bin/i18n.py`), so
  the media name matches meters that report generic water rather than
  specifically cold water.


## 1.5.26

### Fixed
- Parallel LISTEN restarted roughly once per newly discovered candidate, so
  discovering many ids made the supervisor kill and respawn the pipeline ~15
  times in a row (visible as repeated "`.reload_listen` detected, killing
  pid=…" / "pipeline stopped, restarting") and it rarely stayed up long enough
  to decode a preview. Cause: `_request_listen_reload`
  (`bridge-lib/06-candidates.sh`) used a leading-edge cooldown of 10 s, so a new
  candidate arriving more than 10 s after the previous reload triggered an
  immediate reload; discovery of ~29 ids spans several replay cycles, so the
  per-candidate reloads never coalesced. Replaced with a trailing ("settle")
  debounce with a cap: each call stamps `.reload_listen_req`; a single
  background worker (guarded by the atomic `mkdir` of `.reload_listen_pending`)
  fires `.reload_listen` exactly once when either no new request has arrived for
  `RELOAD_SETTLE_SECONDS` (default 6 s, so a short discovery reloads promptly) or
  the worker has run for `RELOAD_MAXWAIT_SECONDS` (default 30 s, so a long burst
  is force-flushed and early candidates still decode). A sustained discovery
  burst now costs roughly one reload per 30 s plus one final settle reload
  instead of one reload per candidate. The supervisor restart loads every
  `meter-preview-<id>` file present on disk, so coalescing drops no candidate;
  the WebGUI manual preview toggle still touches `.reload_listen` directly
  (`webui.py`), bypassing this debounce, and stays immediately responsive.
  `bridge-lib/06-candidates.sh` only.
- AES-encrypted candidate (e.g. NES electricity `00089907`) wrongly showed
  "decoding…" forever and "not analysed" encryption instead of "requires AES",
  after the candidate-discovery fix started registering all manufacturers from
  the RAW path. Cause: the RAW path labelled the type from the DLL device-type
  byte (`map_device_type`), which carries no encryption info, so the
  "encrypted" marker was lost — `candidate_type_requires_aes` stopped matching,
  a preview file was created for a meter that can never decode without a key,
  and the encryption analysis went blank. Fixed in `bridge-lib/05-raw.sh`: a new
  `raw_is_encrypted()` reads the TPL CFG security mode for the common short
  header (CI=0x7A) and appends `encrypted` to the registered type, and the RAW
  registration guard now refuses to downgrade an existing `encrypted`
  classification to the bare device-type label. AES meters again skip preview
  creation and show "requires AES"; plain meters are unaffected and still
  decode. `bridge-lib/05-raw.sh` only.
- Manufacturer column showed only the bare 3-letter FLAG code (e.g. `BMT`)
  instead of the full vendor name (`BMT · BMETERS`) for a meter/candidate first
  seen while another meter was already configured. The full text comes only from
  the LISTEN `manufacturer:` block, which is not emitted once the parallel LISTEN
  has preview files loaded (it leaves "print all" mode), so such ids only ever
  had the RAW M-field code. A small confirmed FLAG-code -> vendor lookup
  (`mfct_name_from_code` in `05-raw.sh`: BMT, NES, SAP, QDS, TCH) now lets the RAW
  path fill the full `(CODE) Vendor` form, which the WebGUI compactor renders as
  `CODE · Vendor`. Unknown codes fall back to the bare code (no regression); the
  existing fill-only-when-empty-or-bare guard upgrades a previously stored bare
  code and never downgrades a full LISTEN name. `bridge-lib/05-raw.sh` only.
- New candidates were not discovered while one or more official meters were
  configured: with no meter the addon listed and decoded the whole replay
  corpus, but with a meter configured only candidates that already had a
  `meter-preview-<id>` file or arrived via the Diehl/SAP RAW special case
  appeared — every other id (e.g. Qundis qwaterv2) was never shown. Root cause:
  `status_raw_candidate_seen()` (`05-raw.sh`) registered a candidate from the RAW
  M-field only for Diehl/SAP (`mfct 0x304C`), assuming the LISTEN path supplies
  the rest. That holds in pure LISTEN mode, but with meters configured the
  primary pipeline runs in DECODE mode (inline candidate parser gated off) and
  the parallel LISTEN — loaded with preview files — leaves "print all telegrams"
  mode, so it never emits the analysis block for unmatched telegrams and new
  candidates are never seen. The RAW path now also registers non-Diehl
  manufacturers when `OFFICIAL_METERS_COUNT > 0`, so the candidate list still
  populates (and previews still decode) with meters configured. Pure LISTEN mode
  (no meters) is unchanged — non-Diehl ids are still left to the LISTEN parser to
  avoid the "auto / inne" clobber. The hardcoded `izarv2` fallback for device
  type `0x07` is now scoped to Diehl/SAP only, so a non-Diehl water meter (also
  type `0x07`, e.g. QDS/BMETERS) registered via the RAW path is no longer
  mislabelled as `izarv2`; LISTEN/decoded-JSON supplies its real driver. The
  existing concrete-driver guard keeps a real classification authoritative and
  prevents reception double-counting. `bridge-lib/05-raw.sh` only.
- Parallel LISTEN parser crashed with `BASH_REMATCH[1]: unbound variable` (under
  `set -u`) from the second telegram block onward, killing and restarting the
  candidate/preview pipeline. In `parse_listen_candidates()` the captured ID was
  read as `${BASH_REMATCH[1]}` *after* `_process_listen_text_block()` had already
  run its own `[[ =~ ]]` internally (via `candidate_update_manufacturer_text` /
  `emit_snippet_if_new`), which clears `BASH_REMATCH`. The match is now captured
  into a local immediately, before the flush call. `bridge-lib/11-listen.sh` only.
- Candidate preview values stayed stuck on "decoding..." while one or more
  official meters were configured, and recovered only after the meters were
  removed. Root cause: `status_candidate_seen_from_json()` (parallel LISTEN,
  added in `db2dfcc`) runs on every decoded preview telegram, but only when
  `OFFICIAL_METERS_COUNT > 0`. It relabels the candidate driver from the decoded
  JSON (e.g. `auto` -> `izarv2`), which rewrote the `meter-preview-<id>` file and
  triggered `_request_listen_reload`, killing and restarting the parallel LISTEN
  pipeline on every telegram. With a multi-meter replay the pipeline never
  stabilised, so previews never finished decoding. A user debug log confirmed
  both the reload churn (`LISTEN supervisor: .reload_listen detected, killing
  pid=...`) and that previews do decode once the driver settles (`unchanged, no
  reload triggered`). `status_candidate_seen()` now takes a 6th `reload`
  argument (default `true`, preserving the text/RAW callers) and the decoded-JSON
  path passes `reload=false`: the driver is still refreshed in the preview file
  for the next natural restart, but no immediate LISTEN reload is triggered, so
  the pipeline is no longer churned. `bridge-lib/06-candidates.sh` and
  `bridge-lib/11-listen.sh` only; preview values, TSV schema, preview states,
  text/RAW reload behaviour and `wmbusmeters` are unchanged.

### Reverted
- Reverted the dedicated zero-meter manufacturer-detection LISTEN instance
  (`bridge-lib/14-detect.sh`). A user reported that after the change, candidate
  preview values stopped decoding while an official meter was configured
  (they reappeared once the meter was removed), a regression that did not exist
  before. A file-level comparison against the pre-modularization monolithic
  `bridge.sh` confirmed the preview decode path (`run_once`,
  `parse_listen_candidates`, `_store_candidate_value`) is byte-identical, so the
  only behavioural difference was the newly added third concurrent
  `wmbusmeters` + `mosquitto_sub` instance. Reverting restores the known-good
  preview behaviour. The bare-vs-full manufacturer healing on the non-concurrent
  paths (`05-raw.sh`, `06-candidates.sh`, `11-listen.sh`) is retained; a
  non-interfering approach for the configured-meter manufacturer case will be
  revisited separately.


## 1.5.25

### Fixed
- Configured-meters-on-air panel showed a bare 3-letter manufacturer code
  (e.g. `NES`) instead of the compact display name
  (`NES · NORA ELK MALZ SAN ve TIC`) after upgrading from a pre-1.5.22
  installation, and the code never healed even after hundreds of telegram
  receptions. Two causes were addressed in `bridge-lib`:
  - `candidate_fill_manufacturer_code()` (RAW hex path, `05-raw.sh`) only
    filled column 9 of `status_candidates.tsv` when it was empty. A legacy
    bare 3-letter code left by an old installation is non-empty, so the
    write was skipped on every restart. It now also matches `/^[A-Z]{3}$/`
    so a legacy code is treated like an empty cell. Full-text names do not
    match the pattern and are never downgraded.
  - `_process_listen_text_block()` (parallel LISTEN, `11-listen.sh`) only
    wrote the manufacturer after an early `[[ -n id && -n driver ]]` guard.
    `wmbusmeters` omits the `driver:` line for telegrams it cannot decrypt
    or recognise, so the full manufacturer text captured by the LISTEN text
    path never reached the TSV. A new `candidate_update_manufacturer_text()`
    in `06-candidates.sh` now writes the full text form before the driver
    guard, overwriting only an empty or bare 3-letter column. It never
    creates rows and never touches reception stats or events.

## 1.5.24-dev

### Changed
- Maintenance refactor: split helper functions from the large
  `rootfs/usr/bin/bridge.sh` runtime script into sourced modules under
  `rootfs/usr/bin/bridge-lib/`. The refactor keeps `bridge.sh` as the
  Home Assistant/Docker entrypoint and leaves startup initialization,
  wrapper integration and `run_once` orchestration in `bridge.sh`.
- The extracted modules now group existing bridge logic by responsibility:
  logging/utilities, options parsing, atomic TSV helpers, status files, raw
  telegram helpers, candidate lifecycle, meter file generation and value
  selection, Home Assistant Discovery helpers/publishing, SEARCH, Parallel
  LISTEN, MQTT pipeline helpers and ESP subscribers.
- This development cycle is intended to be behaviour-preserving. WebUI status
  file formats, MQTT topics, Home Assistant Discovery identifiers, reload
  markers and generated `wmbusmeters` configuration are not intentionally
  changed by the modularization.

### Fixed
- Hardened bridge module loading so `bridge.sh` resolves `bridge-lib` from
  `${BASH_SOURCE[0]}` instead of `$0`, preserving execution through wrappers,
  direct script calls and PATH-based smoke tests.
- Updated the IZAR fixture test lookup so it validates the extracted meter
  helper in `bridge-lib/07-meters.sh` after the refactor.

## 1.5.22-dev

### Fixed
- Candidate `manufacturer` (column 9 of `status_candidates.tsv`) no longer
  stays empty when official meters are configured. Once a candidate has a
  `meter-preview-<id>` file, the parallel LISTEN instance decodes its
  telegrams to JSON — which carries no manufacturer name — and
  `status_candidate_seen_from_json()` updated the row without it, so
  persisted candidates (and the configured-meters panel that borrows the
  candidate's manufacturer) showed a blank `Producent`. Every raw telegram
  carries the wMBus M-field, so `status_raw_candidate_seen()` now decodes
  the 3-letter EN 13757 manufacturer code via the new
  `mfct_code_from_raw_hex()` and fills it into an existing candidate row
  through `candidate_fill_manufacturer_code()` only when the column is
  empty. The full text name from the LISTEN text path stays authoritative
  (a later text update still overwrites the bare code via
  `_upsert_candidate_row`), no candidate rows are created, and reception
  stats / events are untouched (no double counting). `bridge.sh` only.

## 1.5.21-dev

### Fixed
- Correct `total_m3` selection for IZAR meters: the bridge now prefers
  the current `total_m3` field over `last_month_total_m3` when both are
  present in the decoded JSON. Previously, the historical monthly value
  was selected over the live reading in some field-ordering situations.

- Preserve preview context after a candidate is added to the
  configuration: the cached preview value and state
  (`status_candidate_preview_state.tsv`) are now kept visible in the
  pending-meters panel until the first official DECODE telegram arrives,
  instead of being cleared immediately on pipeline reload.

- Self-heal orphaned `meter-preview-*` files: when a candidate is
  officially configured, the bridge now removes its
  `meter-preview-<id>` file and the `.preview_attempts/<id>` counter
  on every restart-loop iteration. A guard in
  `ensure_candidate_autodecode()` also prevents the file from being
  re-created for officially configured meters on subsequent telegrams.
  `status_candidate_values.tsv` and `status_candidate_preview_state.tsv`
  are deliberately preserved.

### Added
- Manual "Usuń podgląd" / Cancel preview button in the new SPA WebGUI:
  available in the candidates table, the pending-meters section, and the
  configured-meters-on-air panel whenever `preview_active` is true.
  Calls the existing `/api/cancel-preview` endpoint.

- Regression tests for IZAR current total selection, covering real
  user-reported HEX telegrams where `total_m3` and
  `last_month_total_m3` co-exist in the decoded output.

## 1.5.19-dev

### Fixed
- FU-008: Diehl/SAP (mfct 0x304C) RAW fallback no longer hardcodes
  `izarv2 / Water meter (0x07)` for every SAP telegram. The A/TYPE byte
  (raw[18:20]) is now read: type `0x07` keeps the unchanged izarv2 water
  path, any other type registers as `auto` + a mapped label via the new
  `map_device_type()` (known OMS types + `Unknown meter type (0xXX)`
  fallback, no full 0x00–0xFF table). Added a hard LISTEN-over-RAW
  priority: if the candidate already has a concrete (non-`auto`) driver
  from a real LISTEN classification, the RAW fallback returns without
  overwriting it — fixing the alternating overwrite race (e.g. non-water
  Diehl flapping auto → sharky → auto). bridge.sh only; IZAR water path
  and lowercase-ID handling unchanged.

## 1.5.18-dev

PRD §14 follow-up batch (FU-001, FU-002, FU-005). Verification-only
items FU-003 and FU-004 needed no code change (current behaviour already
correct; reference PRD updated).

### Fixed
- FU-001: unified the `search_tolerance_m3` default to `0.05` across all
  runtime and Docker fallbacks. `bridge.sh` used a stale `1` fallback in
  two spots (`json_get '.search_tolerance_m3' '1'` and
  `float_or_default "${SEARCH_TOLERANCE_M3}" "1"`) and
  `docker/entrypoint.sh` seeded the default `options.json` with `1`.
  Without an explicit value, Docker users (and anyone clearing the option)
  got a 20× wider match tolerance than the documented `0.05`, risking
  false matches in multi-dwelling buildings. `config.yaml` was already
  correct.

- FU-005: the "Restart add-on" button no longer silently fakes success in
  Docker standalone mode. Without a Supervisor API, `/api/restart-bridge`
  can only return a 400, yet the frontend swallowed the error, entered the
  "restarting" overlay and — because the WebUI process never actually went
  down — reported "Add-on restarted successfully". The handler now detects
  `meta.runtime === "docker"` and shows a clear instruction to run
  `docker restart <container>` on the host instead. New i18n key
  `restart_docker_manual` (EN/PL/DE/CS/SK). HA behaviour unchanged.

### Docs
- FU-002: corrected the published MQTT state/Discovery topic examples in
  all READMEs (EN/PL/DE/SK/CS). The topic uses the hardware serial
  (`.id`, e.g. `wmbusmeters/41553221/state`), not the user label — docs
  previously showed `wmbusmeters/cold_water_bathroom/state`. Discovery
  topic and `unique_id` now use `wmbus_<meter_id>`; the user label is kept
  only in the sensor `name`. Placeholders fixed: `<id>` → `<meter_id>`,
  `sensor/<id>_<field>` → `sensor/wmbus_<meter_id>/<field>`.

## 1.5.3-dev

Development snapshot ahead of the next stable cut. Bundles the
stable-track fixes already promoted to 1.5.1 / 1.5.2 plus a batch of
WebUI polish and an exhaustive unit-suffix table.

### Added
- `unit_from_key()` (WebUI) and full rewrite of `guess_unit()`
  (`bridge.sh`) with the exhaustive wmbusmeters field-suffix
  vocabulary. Longest suffixes are checked first so `_kwh`
  isn't shadowed by `_kw`, `_kvarh` by `_kvar`, `_m3h` by `_m3`,
  etc. New coverage includes `kVARh`/`kVAh`/`kVAR`/`kVA`, `J/h`,
  `GJ`/`MJ`, `dBm`, `hca`, `pct`/`ppm`, `bar`, `Pa`, `mol`, `min`,
  `rad`, `deg`, `kg`, `cd`, `K`, `°F` and the base units. Non-numeric
  meta suffixes (`utc`, `datetime`, `counter`, `factor`, `txt`, `nr`,
  `month`) explicitly emit no unit. In the WebUI the unit is shown
  with a small category emoji on the meter card.
- Dynamic meter-status label on the WebUI meter card (was always
  the static "Online"): `seen_15m > 0` → online (green), else
  `seen_60m > 0` → silent (amber), else offline (red).
  Uses `online_label` / `silent_label` / `offline_label` i18n keys.
- Restart button is back inside the pending-meters panel — earlier
  removal was reverted by user preference.

### Changed
- Carries every change from the 1.5.2 stable release: defensive
  `value_template` (`value_json.get(...) | default(none)`),
  `expire_after = 2 * avg_interval_s` (60 s rounded, 3600 s floor),
  `state_class: measurement` restricted to statistically meaningful
  `device_class` values, `device_class` for `m³` derived from
  the meter's reported `media`. See `wmbus_mqtt_bridge/CHANGELOG.md`
  for the full description.
- Carries every change from the 1.5.1 stable release: combined
  AI-development notice, ESPHome-pairing paragraph, mermaid radio
  list now lists CC1101/SX1276/SX1262, machine-translation
  disclaimers trimmed.

### CI
- Build workflow no longer rebuilds the image for text-only commits
  (`README.md`, `CHANGELOG.md` inside the addon folder, repo-root
  docs). Path filter narrowed to `rootfs/**`, `Dockerfile`,
  `config.yaml`, `translations/**` and the workflow file itself.
- New `sync-rootfs` workflow keeps `wmbus_mqtt_bridge/rootfs`,
  `Dockerfile` and `translations` in lockstep with the dev addon
  by auto-committing back to `dev` after every push that changes
  the dev runtime. Manual escape hatch is
  `scripts/promote-rootfs.sh`.

### Notes
- Versions `1.5.1-dev` and `1.5.2-dev` were not separately published —
  the dev branch moved straight from `1.5.0-dev` to `1.5.3-dev` while
  promoting incremental fixes to the stable channel.

---

## 1.5.0-dev

Development snapshot tracking the upcoming `1.5.0` stable release.
First version of the embedded WebUI — please report regressions via
GitHub Issues.

### Added
- **WebUI with Home Assistant Ingress** — new panel "wMBus Bridge" served on
  port 8099 via `hassio_api: true` + `ingress: true`, no extra port exposure.
  Backed by a Python service (`rootfs/usr/bin/webui.py`) supervised by s6
  (`rootfs/etc/services.d/wmbus_webui/run`).
- **Multi-language UI** — translation layer in `rootfs/usr/bin/i18n.py`
  covering Polish, English, German, Czech and Slovak. All UI strings are
  machine-generated and may contain errors in any language.
- **Multi-language documentation** under `docs/` — full PL/EN/DE/CS/SK
  versions of the README, linked from the main README. All docs are
  machine-generated.
- Combined AI / machine-generated-text notice in the README (PL/EN).

### Changed
- Add-on stage set to `experimental`.
- Default `search_tolerance_m3` lowered from `1` to `0.05` for a more accurate
  match window during meter discovery.
- Bridge runtime script (`rootfs/usr/bin/bridge.sh`) heavily extended to back
  the WebUI flows (status, candidates, controls).
- Dockerfile: base image bumped to `alpine:3.23`; `python3` added to the
  add-on stage for the WebUI; `webui.py` made executable on build.

### Notes
- Version `1.5.0` bumped manually; previous published release was `1.4.7`.

---

## 1.4.6

## Updated to version [2.0.0-444]
