# A meter wmbusmeters cannot decode yet

*Polski: [UNKNOWN_METER.pl.md](UNKNOWN_METER.pl.md)*

The add-on receives every frame your boards hear, also from meters that
wmbusmeters has no driver for. Such a meter shows up under
**RECEIVED / SEARCH** as a candidate without a value (driver `unknown`, or
"unknown format signature"). This page is the way from there to a working
meter. It is how the B METERS Hydroclima 0x34 allocators got a driver in
November 2026, from frames and display photos sent by one user.

**No guarantee.** The add-on's maintainer does not promise that every
meter can be decoded. Some formats are encrypted with a key only the billing
company has, and those stay closed. Many others are only undocumented or
lightly obfuscated, and then this works — but whether and when depends on
the format and on the data you can collect.

## 1. Check it is really unknown

- Is the add-on on the latest version? A newer wmbusmeters may already have
  the driver.
- Open **Report…** in the candidate's row to see the raw telegram and the
  `wmbusmeters --analyze` output (you don't have to file anything). If the
  analysis says the telegram is encrypted (AES), you need the key from the
  billing company, not a new driver — see *"My meter is encrypted"* in the
  user guide.
- Note the manufacturer, version and type (e.g. `BMP,34,08`) and the meter ID.

## 2. Collect the telegrams automatically

A few telegrams are not enough. Collect all frames of the meter for a day or
two. You don't have to copy anything by hand — a Home Assistant automation
writes every frame to a file:

1. **Settings → Devices & services → Add integration → File → Notification**,
   file path `/media/meter_log.txt`.
2. Create this automation. Replace `92607351` with the meter ID **in the
   order it appears in the frame**: ID `51736092` is sent as `92607351`
   (the four bytes reversed).

   ```yaml
   alias: Unknown meter telegram log
   mode: queued
   max: 100
   triggers:
     - trigger: mqtt
       topic: wmbus/+/telegram
   conditions:
     - condition: template
       value_template: "{{ (trigger.payload | upper)[8:16] == '92607351' }}"
   actions:
     - action: notify.send_message
       target:
         entity_id: notify.file
       data:
         message: "{{ now().isoformat() }} {{ trigger.topic }} {{ trigger.payload | upper }}"
   ```

   For several meters of the same model, filter on manufacturer and version
   instead (`[4:8]` and `[16:20]` of the frame, e.g. `B009` and `3408`).

Let it run over at least one working day: many meters are quiet at night and
on Sundays.

## 3. Read the display at the same time

The frames alone say nothing; the values on the display are the key.

- Every screen the display cycles through, with the **time** you read it.
- At the start and at the end of the capture, and once or twice in between
  while the value changes.
- Dates on the display (current date, billing date) too: a value known in
  advance is the best way to find where it sits in the frame.
- Several meters of the same model help, and a meter whose value does not
  change (radiator off, no consumption) helps most: every frame then carries
  the same content in a different form.

## 4. Ask the add-on author

In the candidate's row, open **Report…** and click **Ask the add-on
author**. A new question opens in this repository's Discussions, category
*Nowe liczniki / Unknown meters*, already filled in: the model as the title,
one telegram, the wmbusmeters analysis and a list of what to add. Nothing is
sent by the add-on — you review the text and post it from your own GitHub
account. Attach the log file, the display readings and a photo of the label.

The meter number is hidden in the report by default (replaced by
`99999999`); the frames in your log file still contain it. If you'd rather
not share them publicly, say so in the discussion first.

## 5. Try the driver straight away — the fast part

Once there is a driver file (`.xmq`), you don't wait for a new release:

1. Turn on **`custom_drivers_enabled`** (External drivers) in the add-on
   options. A **DRIVERS** tab appears.
2. Upload the `.xmq`. It is checked in a separate wmbusmeters process first,
   and meters on it run in their own instance, so a faulty file cannot stop
   your other meters. The driver name must start with `external_`.
3. **Matching meters on air** decodes the latest frame of every meter that
   fits the driver, on trial, without touching anything running. Compare
   the values with the display right away.
4. Values wrong? A corrected file is uploaded the same way and checked
   against the same frames. One round takes minutes, not a release cycle.
5. Values right? **Switch to …** puts the meter on the driver.

Unchecked, the file is treated as confidential (NDA): it stays in the add-on
and is left out of Home Assistant backups.

## 6. Upstream

A driver that matches the displays belongs in wmbusmeters, so it works for
everyone. A wmbusmeters driver needs real telegrams with known values as
tests — the frames and display readings from steps 2 and 3, with the owner's
permission. When a wmbusmeters update learns the format, the add-on can take
it over from there.
