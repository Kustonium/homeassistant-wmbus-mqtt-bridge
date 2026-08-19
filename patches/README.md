# Add-on-local patches to the pinned `wmbusmeters`

Patches applied to the pinned upstream checkout at image build time
(`Dockerfile` → `apply-local-patches.sh`), for behaviour that cannot be reached
through configuration.

**Upstream wins.** Every patch declares a signal that upstream has solved the
problem itself. When that signal appears, the patch is skipped and the build log
says so. When a patch no longer applies, the build **fails** instead of quietly
shipping without it — the pin is bumped by a monthly cron, and a workaround that
evaporates while the release notes still imply it works is worse than no
workaround at all.

## 0001 — Tauron/KPL non-standard decrypt check bytes

**Symptom.** A user with a Polish Tauron electricity meter (manufacturer flag
`KPL`, `0x2E0C`) supplies the correct AES key and gets no entities at all, plus:

```
WARNING!! decrypted content failed check, did you use the correct decryption key?
```

The key is fine. After a correct AES-CBC decryption this meter puts `60 9b`
where the standard puts the `2f2f` check bytes. `Telegram::potentiallyDecrypt()`
reads the mismatch as a wrong key, sets `decryption_failed`, `t.parse()` returns
false, and no field is ever extracted.

Note the diagnosis in that message is wrong for this case, and that is upstream's
bug independently of this patch: one sentence covers two different failures, and
it sends people to re-check a key that was never the problem.

**What the patch does.** In both AES-CBC paths (`AES_CBC_IV` and
`AES_CBC_NO_IV`), rewrites `60 9b` to `2f 2f` when — and only when — the
manufacturer is `KPL`.

**Why this is safe.** Those two bytes are consumed as protocol
(`addExplanationAndIncrementPos(pos, 2, …)`) a few lines further down and never
reach `parseDV()`, so rewriting them cannot destroy payload. The condition is
guarded by both the manufacturer and the exact byte pair, so no other meter can
be affected, and if the pair turns out not to be constant the patch simply stops
matching.

**Upstream signal (retirement).** `MANUFACTURER_KPL` appearing in `src/wmbus.cc`,
or a driver named after the manufacturer/utility. `manufacturers.h` is
deliberately *not* part of the signal: the `KPL` flag code has been listed there
for years — as "KPLC Power, Kenya" — with no telegram handling attached.

**Driver.** None is shipped. Detection would need
`addDetection(MANUFACTURER_KPL, …)`, which no upstream driver has, so `auto` will
not pick this meter up: configure it explicitly as `amiplus`. The field set is
reported to match `amiplus` apart from the header.

**Evidence, and its limits.** The mechanism is verified from upstream source; the
patch applies to the pinned commit, compiles, passes upstream's own `make test`
("All tests ok!") and this repository's 14 golden decode fixtures. What is *not*
verified is the fix itself: nobody here has such a meter, and no raw telegram was
available. It rests on a single third-party report (forum.arturhome.pl, thread
"Licznik S34U28 od Taurona") and on the fork `zelo66/wmbusmeterCustom`, whose
author says plainly that it was written "by AI, just to make it work". If you
have this meter, please open an issue with a raw telegram — that is what would
turn this from plausible into verified.
