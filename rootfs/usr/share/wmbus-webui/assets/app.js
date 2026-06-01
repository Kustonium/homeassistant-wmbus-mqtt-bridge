(() => {
  const app = document.getElementById("app");

  const navItems = [
    ["dashboard", "nav_dashboard", "DB"],
    ["meters", "nav_meters", "MT"],
    ["discover", "nav_discover", "RX"],
    // Legacy SEARCH mode hidden from nav — its main use-case (find your meter
    // by matching expected m³) is now covered by the Discover page's
    // "Filter by value" input + always-on parallel LISTEN. searchPage()
    // function and backend search-control endpoint remain available via
    // direct URL hash (#search) for advanced users who set it up before.
    // ["search", "nav_search", "SR"],
    ["logs", "nav_logs", "LG"],
    ["esp-logs", "nav_esp_logs", "EL"],
    ["settings", "nav_settings", "ST"],
    ["about", "nav_about", "AB"],
  ];

  const textAliases = {
    webui_language: "show",
    webui_restart: "restart_addon",
    webui_updated: "updated_label",
    webui_online: "online_label",
    webui_raw_input: "raw_telegrams_received",
    webui_recent_meters: "configured_meters",
    webui_top_candidates: "best_candidate",
    webui_no_meters: "no_configured_meters_yet",
    webui_no_candidates: "no_candidates_yet",
    webui_no_events: "no_events_yet",
    webui_id: "id_label",
    webui_name: "meter_name_label",
    webui_value: "value_label",
    webui_last_seen: "last_telegram",
    webui_add: "add_meter",
    webui_remove: "delete",
    webui_stop: "save_disable_search",
    webui_search_cache: "candidates_for_search_label",
    webui_matches: "search_matches",
    webui_runtime_events: "recent_events_title",
    webui_diagnostics: "esp_diag_title",
    webui_suggestion: "esp_suggestion_title",
    webui_boot: "esp_boot_title",
    webui_esp_events: "esp_events_title",
    webui_search_mode: "search_config",
    webui_options_snapshot: "json_preview",
    webui_data_path: "runtime_files",
    webui_add_meter: "add_meter",
    webui_meter_name: "meter_name_label",
    webui_aes_key: "aes_key_label",
    webui_cancel: "cancel_label",
  };

  // Dashboard view selector — persisted in localStorage so the user keeps
  // their preferred lens across reloads. "pipeline" = data-flow diagram with
  // clickable nodes; "stats" = speed-dial + sparkline + funnel.
  const LS_VIEW_KEY = "wmbus.dashboardView";
  function loadDashboardView() {
    try {
      const v = window.localStorage.getItem(LS_VIEW_KEY);
      return (v === "stats" || v === "pipeline") ? v : "pipeline";
    } catch (_) { return "pipeline"; }
  }
  function saveDashboardView(v) {
    try { window.localStorage.setItem(LS_VIEW_KEY, v); } catch (_) {}
  }

  const state = {
    route: currentRoute(),
    data: null,
    loading: true,
    error: "",
    modal: null,
    toast: null,
    liveConnected: false,
    mediaFilter: "all",
    // Dashboard view ("pipeline" | "stats") — segmented control on PANEL.
    dashboardView: loadDashboardView(),
    // Drill-down workspace when a pipeline node is clicked. null = no drill-down.
    workspace: null,  // "esp" | "mqtt" | "wmbus" | "ha" | null
  };

  let liveSource = null;
  let liveLang = "";
  let liveRenderTimer = null;

  // Debounced render for SSE live updates — coalesces rapid events into one
  // DOM patch. 150ms is enough to batch bursts without feeling sluggish.
  function scheduleRender() {
    if (liveRenderTimer) return;
    liveRenderTimer = window.setTimeout(() => {
      liveRenderTimer = null;
      render();
    }, 150);
  }

  function currentRoute() {
    const hash = window.location.hash.replace(/^#\/?/, "");
    const route = hash.split("?")[0].trim();
    return route || "dashboard";
  }

  function escapeHtml(value) {
    return String(value ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;");
  }

  function t(key, fallback = key, replacements = {}) {
    const dict = state.data?.i18n?.text || {};
    const text = dict[key] || dict[textAliases[key]] || fallback;
    return Object.entries(replacements).reduce(
      (acc, [name, value]) => acc.replaceAll(`{${name}}`, String(value)),
      text,
    );
  }

  function asArray(value) {
    return Array.isArray(value) ? value : [];
  }

  function meterIdFromRawHex(hexValue) {
    const hex = String(hexValue || "").toUpperCase();
    if (!/^[0-9A-F]+$/.test(hex)) return "";
    if (hex.length < 22 || hex.length % 2 !== 0) return "";
    const lengthField = Number.parseInt(hex.slice(0, 2), 16);
    if (!Number.isFinite(lengthField) || lengthField !== (hex.length / 2) - 1) return "";
    // wMBus A-field stores the 4-byte meter ID little-endian after L/C/M-field.
    const idLe = hex.slice(8, 16);
    return `${idLe.slice(6, 8)}${idLe.slice(4, 6)}${idLe.slice(2, 4)}${idLe.slice(0, 2)}`;
  }

  function normalizeMeterId(value) {
    let mid = String(value || "").replace(/\s+/g, "").toUpperCase();
    if (mid.startsWith("0X")) mid = mid.slice(2);
    if (!/^[0-9A-F]+$/.test(mid)) return "";
    if (mid.length > 8) return meterIdFromRawHex(mid);
    return mid.length < 8 ? mid.padStart(8, "0") : mid;
  }

  // ── Media classification ──────────────────────────────────────────────────
  // Works for both candidates (type = wmbusmeters type string like
  // "Warm Water (30°C-90°C) meter (0x06)") and meters (media = wmbusmeters
  // media field like "warm_water").
  function mediaClass(typeOrMedia, driver) {
    const s = ((typeOrMedia || "") + " " + (driver || "")).toLowerCase();
    if (s.includes("electric"))                           return "electricity";
    if (s.includes("warm_water") || s.includes("warm water") || s.includes("hot water")) return "warm_water";
    if (s.includes("heat") || s.includes("caloric") || s.includes("cooling")) return "heat";
    if (s.includes("water"))                              return "water";
    return "other";
  }

  // Returns {icon, color, bg, mc}.
  // Emoji like 💧 ignore CSS color — warm_water vs water is distinguished
  // by the background circle colour (#3b2010 orange vs #0f2a3b blue).
  function mediaIcon(typeOrMedia, driver) {
    const mc = mediaClass(typeOrMedia, driver);
    const icon  = {electricity:"⚡", heat:"🔥", warm_water:"🚱", water:"🚰", other:"·"}[mc] || "·";
    const color = {electricity:"#60b4f0", heat:"#f07840", warm_water:"#f09040", water:"#40c0e0", other:"#607a88"}[mc] || "#607a88";
    return {icon, color, mc};
  }

  // Render medium icon — just the emoji, no background circle.
  function mediaIconHtml(typeOrMedia, driver) {
    const {icon} = mediaIcon(typeOrMedia, driver);
    return `<span style="font-size:16px;vertical-align:middle;">${icon}</span>`;
  }

  // Filter chip bar — renders pill buttons; active one gets .active class.
  function filterChips() {
    const active = state.mediaFilter || "all";
    const filters = [
      ["all",         t("filter_all",         "Wszystkie")],
      ["water",       t("media_water",         "Woda")],
      ["electricity", t("media_electricity",   "Prąd")],
      ["heat",        t("media_heat",          "Ciepło")],
      ["warm_water",  t("media_warm_water",    "Ciepła woda")],
      ["other",       t("media_other",         "Inne")],
    ];
    const chips = filters.map(([key, label]) =>
      `<span class="filter${key === active ? " active" : ""}" data-action="media-filter" data-filter="${key}" style="cursor:pointer;">${escapeHtml(label)}</span>`
    ).join("");
    return `<div class="filters"><span style="color:#9eafba;font-size:12px;">${escapeHtml(t("show", "Pokaż:"))}</span> ${chips}</div>`;
  }

  // Filter array rows by current mediaFilter; typeField is the row property
  // that holds the wmbusmeters type/media string.
  function applyMediaFilter(rows, typeField = "type") {
    const active = state.mediaFilter || "all";
    if (active === "all") return rows;
    return rows.filter(r => mediaClass(r[typeField] || r.media || "", r.driver || "") === active);
  }

  // ── #2 Unit mapping ──────────────────────────────────────────────────────
  // Maps wmbusmeters value_key suffix → display unit string.
  // Longest suffixes checked first to avoid false matches (_kwh before _kw).
  function unitFromKey(valueKey) {
    const k = (valueKey || "").toLowerCase();
    if (k.endsWith("_kvarh"))   return "kVARh";
    if (k.endsWith("_kvah"))    return "kVAh";
    if (k.endsWith("_m3c"))     return "m³°C";
    if (k.endsWith("_m3ch"))    return "m³°C/h";
    if (k.endsWith("_m3h"))     return "m³/h";
    if (k.endsWith("_mjh"))     return "MJ/h";
    if (k.endsWith("_kvar"))    return "kVAR";
    if (k.endsWith("_kva"))     return "kVA";
    if (k.endsWith("_kwh"))     return "kWh";
    if (k.endsWith("_kw"))      return "kW";
    if (k.endsWith("_wh"))      return "Wh";
    if (k.endsWith("_lh"))      return "l/h";
    if (k.endsWith("_jh"))      return "J/h";
    if (k.endsWith("_gj"))      return "GJ";
    if (k.endsWith("_mj"))      return "MJ";
    if (k.endsWith("_dbm"))     return "dBm";
    if (k.endsWith("_hca"))     return "hca";
    if (k.endsWith("_pct"))     return "%";
    if (k.endsWith("_ppm"))     return "ppm";
    if (k.endsWith("_rh"))      return "RH%";
    if (k.endsWith("_hz"))      return "Hz";
    if (k.endsWith("_bar"))     return "bar";
    if (k.endsWith("_pa"))      return "Pa";
    if (k.endsWith("_m3"))      return "m³";
    if (k.endsWith("_mol"))     return "mol";
    if (k.endsWith("_min"))     return "min";
    if (k.endsWith("_rad"))     return "rad";
    if (k.endsWith("_deg"))     return "°";
    if (k.endsWith("_counter")) return "cnt";
    if (k.endsWith("_factor"))  return "×";
    if (k.endsWith("_nr"))      return "nr";
    if (k.endsWith("_kg"))      return "kg";
    if (k.endsWith("_cd"))      return "cd";
    if (k.endsWith("_w"))       return "W";
    if (k.endsWith("_v"))       return "V";
    if (k.endsWith("_a"))       return "A";
    if (k.endsWith("_k"))       return "K";
    if (k.endsWith("_c"))       return "°C";
    if (k.endsWith("_f"))       return "°F";
    if (k.endsWith("_l"))       return "l";
    if (k.endsWith("_m"))       return "m";
    if (k.endsWith("_s"))       return "s";
    if (k.endsWith("_h"))       return "h";
    if (k.endsWith("_d"))       return "d";
    if (k.endsWith("_y"))       return "y";
    return "";
  }

  function parseValueParts(row) {
    const raw = String(row?.value_parts || "").trim();
    if (!raw) return [];
    try {
      const parsed = JSON.parse(raw);
      if (!Array.isArray(parsed)) return [];
      return parsed
        .map((part) => {
          const label = String(part?.label || "").trim();
          const key = String(part?.key || "").trim();
          const value = Number(part?.value);
          if (!label || !Number.isFinite(value)) return null;
          return {label, key, value};
        })
        .filter(Boolean);
    } catch (_) {
      return [];
    }
  }

  function formatFlowValue(value) {
    const n = Number(value);
    if (!Number.isFinite(n)) return String(value ?? "");
    return n.toFixed(3).replace(/\.?0+$/, "");
  }

  function tariffFlowHtml(row) {
    const key = String(row?.value_key || "").toLowerCase();
    if (!key.includes("total_energy_consumption")) return "";
    const parts = parseValueParts(row);
    if (!parts.length) return "";
    const totalValue = row?.value && row.value !== "-" ? formatFlowValue(row.value) : "";
    const totalLabel = t("webui_total", "total");
    const chips = parts.map((part) => `
      <span title="${escapeHtml(part.key)}" style="display:inline-flex;align-items:center;gap:3px;padding:2px 5px;border:1px solid #264859;border-radius:4px;background:#0c1820;color:#8fb5c8;">
        <span style="color:#6f8796;">${escapeHtml(part.label)}</span>
        <strong style="color:#cfe9f7;font-weight:700;">${escapeHtml(formatFlowValue(part.value))}</strong>
      </span>
    `).join(`<span style="color:#4a6070;">+</span>`);
    return `
      <div class="mono" style="margin-top:5px;display:flex;align-items:center;gap:4px;flex-wrap:wrap;font-size:10px;line-height:1.35;">
        ${chips}
        <span style="color:#4a6070;">=</span>
        <span style="display:inline-flex;align-items:center;gap:3px;padding:2px 5px;border:1px solid #1c6b50;border-radius:4px;background:#082017;color:#4df08d;font-weight:700;">
          <span>${escapeHtml(totalLabel)}</span>
          ${totalValue ? `<strong style="color:#d8ffe8;font-weight:700;">${escapeHtml(totalValue)}</strong>` : ""}
        </span>
      </div>
    `;
  }

  function meterValueCell(row) {
    const unit = unitFromKey(row.value_key || "");
    const hasValue = !!(row.value && row.value !== "-");
    const valueStr = hasValue ? row.value : "—";
    const valueColor = hasValue ? "#4df08d" : "#9eafba";
    return `
      <span style="font-weight:700;color:${valueColor};">${escapeHtml(valueStr)}</span>${unit ? ` <span class="mono" style="color:#9eafba;font-size:11px;">${escapeHtml(unit)}</span>` : ""}
      ${tariffFlowHtml(row)}
      ${row.value_key ? `<div class="mono" style="font-size:10px;color:#4a6070;">${escapeHtml(row.value_key)}</div>` : ""}
    `;
  }

  // ── #5 Signal bars + meter health ────────────────────────────────────────
  function signalBars(seen15m) {
    const n = seen15m >= 10 ? 4 : seen15m >= 5 ? 3 : seen15m >= 2 ? 2 : seen15m > 0 ? 1 : 0;
    const ok = "#4df08d", off = "#2a3a3a";
    return `<span style="display:inline-flex;align-items:flex-end;height:16px;gap:1px;">${
      Array.from({length: 4}, (_, i) =>
        `<span style="display:inline-block;width:4px;height:${4 + i * 3}px;background:${i < n ? ok : off};border-radius:1px;"></span>`
      ).join("")
    }</span>`;
  }

  function meterStatusLabel(seen15m, seen60m) {
    if (seen15m > 0) return {label: t("online_label",  "online"),  color: "#2de36f"};
    if (seen60m > 0) return {label: t("silent_label",  "silent"),  color: "#f3c84b"};
    return             {label: t("offline_label", "offline"), color: "#ff646b"};
  }

  // ── #1 Encryption badge (shared by candidateTable + pendingMetersSection) ─
  // bridge.sh sets encryption="unknown" when type_line contains no "encrypted"
  // or "aes" keyword — meaning wmbusmeters did NOT flag it as AES-encrypted.
  // "unknown" therefore means "not detected as encrypted" = no AES in practice.
  function encBadge(enc, note) {
    const e = (enc || "").toLowerCase();
    if (!e) return `<span class="pill muted" title="${escapeHtml(t("enc_unknown", "Not yet analyzed"))}">?</span>`;
    const bad     = ["encrypted", "aes_required", "aes"].includes(e);
    const unknown = e === "unknown";
    const label   = bad     ? t("enc_aes_req", "AES req.")
                  : unknown ? t("enc_unknown", "Not yet analyzed")
                  :            t("enc_no_aes", "no AES");
    const cls     = bad ? "bad" : unknown ? "muted" : "ok";
    const title = note ? ` title="${escapeHtml(note)}"` : "";
    return `<span class="pill ${cls}"${title}>${escapeHtml(label)}</span>`;
  }

  // ── #6 Manufacturer compact formatter ────────────────────────────────────
  // "(MAD) Maddalena, Italy (0x3424)" → "MAD · Maddalena"
  // Returns empty string for missing/empty input (caller shows "—").
  function compactManufacturer(mfr) {
    if (!mfr) return "";
    const m = mfr.match(/^\(([^)]+)\)\s*(.*)/);
    if (!m) return mfr.split(",")[0].trim();
    const code = m[1];
    const name = m[2].split(",")[0].trim();
    return (code && name) ? `${code} · ${name}` : (name || code || mfr);
  }

  // ── #7 Reception interval formatter ──────────────────────────────────────
  function fmtInterval(seconds) {
    const n = Number(seconds);
    if (!n || n <= 0) return t("not_enough_data", "not enough data");
    if (n < 90)   return `~${Math.round(n)}s`;
    if (n < 5400) return `~${Math.round(n / 60)} min`;
    return `~${(n / 3600).toFixed(1)} h`;
  }

  // ── #7 Pending meter banner ───────────────────────────────────────────────
  // Shows a restart action only when the backend explicitly says the running
  // bridge has not applied current options. Otherwise pending meters are simply
  // waiting for their first decoded telegram after the soft reload.
  function pendingMeters() {
    const data = state.data || {};
    if (Array.isArray(data.pending_meters)) {
      return data.pending_meters;
    }

    const decodedIds = new Set(asArray(data.meters).map(m => normalizeMeterId(m.id)));
    return asArray((data.options || {}).meters).filter(m => {
      const mid = normalizeMeterId(m.meter_id);
      return mid && !decodedIds.has(mid);
    });
  }

  function pendingPreviewDecoded(row) {
    const previewState = String(row.preview_state || "").trim();
    return previewState === "decoded_value" || previewState === "decoded_without_numeric_value";
  }

  function pendingMeterHeader() {
    return `
      <tr>
        <th>${escapeHtml(t("webui_id", "ID"))}</th>
        <th>${escapeHtml(t("driver", "Driver"))}</th>
        <th>${escapeHtml(t("manufacturer_col", "Manufacturer"))}</th>
        <th>${escapeHtml(t("encryption_label", "Encryption"))}</th>
        <th>${escapeHtml(t("preview_value_col", "Value"))}</th>
        <th>${escapeHtml(t("last_telegram", "Last telegram"))}</th>
        <th>15M</th>
        <th>60M</th>
        <th>${escapeHtml(t("reception", "Reception"))}</th>
        <th>${escapeHtml(t("aes_key_label", "AES key"))}</th>
        <th></th>
      </tr>
    `;
  }

  function pendingMeterRow(row, analysis) {
    const mid = normalizeMeterId(row.meter_id);
    const driver = row.driver || (row.type === "other" ? (row.type_other || "other") : (row.type || "auto"));
    const hasKey = row.has_key === true || row.has_key === "true" || !!(row.key && row.key.trim());
    const a = analysis[mid] || analysis[mid.toUpperCase()] || {};
    const previewState = String(row.preview_state || "").trim();
    const previewVal = String(row.preview_value || "").trim();
    const previewKey = String(row.preview_value_key || "").trim();
    const previewUnit = previewKey ? unitFromKey(previewKey) : "";
    const rawEnc = String(row.encryption || a.encryption || "").toLowerCase();
    const note = String(row.analysis_note || a.note || "");
    const effectiveEnc = (rawEnc === "unknown" && pendingPreviewDecoded(row)) ? "no_aes" : rawEnc;
    const mfrRaw = String(row.manufacturer || "").trim();
    const mfrCompact = compactManufacturer(mfrRaw);
    const stateText = pendingPreviewDecoded(row) || previewVal
      ? t("pending_preview_confirmed", "Added to configuration — waiting for first official reading")
      : t("pending_waiting_first_official", "Waiting for first telegram");
    const previewCell = previewVal
      ? `<span style="font-weight:700;color:#4df08d;">${escapeHtml(previewVal)}</span>${previewUnit ? ` <span class="mono" style="color:#9eafba;font-size:11px;">${escapeHtml(previewUnit)}</span>` : ""}<div style="font-size:10px;color:#8ea4b1;">${escapeHtml(t("cached_preview_value", "Cached preview value"))}</div>${previewKey ? `<div class="mono" style="font-size:10px;color:#4a6070;">${escapeHtml(previewKey)}</div>` : ""}`
      : previewState === "decoded_without_numeric_value"
        ? `<span style="font-size:11px;color:#9eafba;">${escapeHtml(t("preview_no_value", "no value in telegram"))}</span><div style="font-size:10px;color:#8ea4b1;">${escapeHtml(t("cached_preview_value", "Cached preview value"))}</div>`
        : `<span style="color:#4a6070;">—</span>`;

    return `
      <tr>
        <td><strong>${escapeHtml(mid)}</strong><div style="font-size:10px;color:#8ea4b1;margin-top:2px;">${escapeHtml(stateText)}</div></td>
        <td style="color:#9eafba;font-size:12px;">${escapeHtml(driver)}</td>
        <td>${mfrCompact ? `<span style="font-size:12px;color:#9eafba;" title="${escapeHtml(mfrRaw)}">${escapeHtml(mfrCompact)}</span>` : `<span style="color:#4a6070;">—</span>`}</td>
        <td>${encBadge(effectiveEnc, note)}</td>
        <td>${previewCell}</td>
        <td>${fmtTime(row.last_seen)}</td>
        <td>${escapeHtml(String(row.seen_15m || 0))}</td>
        <td>${escapeHtml(String(row.seen_60m || 0))}</td>
        <td style="color:#607a88;font-size:12px;">${escapeHtml(fmtInterval(row.avg_interval_s))}</td>
        <td>${hasKey
          ? `<span class="pill ok">${escapeHtml(t("aes_key_set", "AES key set"))}</span>`
          : `<span class="pill muted">${escapeHtml(t("no_key", "No key"))}</span>`}
        </td>
        <td><div class="actions">
          ${row.preview_active === "true" ? `<button class="btn" data-action="cancel-preview" data-id="${escapeHtml(mid)}">${escapeHtml(t("cancel_preview", "Cancel preview"))}</button>` : ""}
          <button class="btn danger" data-action="remove-meter" data-id="${escapeHtml(mid)}">${escapeHtml(t("webui_remove", "Remove"))}</button>
        </div></td>
      </tr>
    `;
  }

  function pendingRestartBanner() {
    const data  = state.data || {};
    const model = data.model || {};

    const pending = pendingMeters();
    const pendingCount = pending.length;
    const hasPreview = pending.some(row => pendingPreviewDecoded(row) || String(row.preview_value || "").trim());

    const needsRestart = !!model.pending_restart;
    if (!needsRestart && pendingCount === 0) return "";

    const title = needsRestart
      ? t("pending_title", "Pending changes — waiting for restart")
      : t("waiting_for_telegrams_title", "Waiting for first telegram");
    const detail = needsRestart
      ? t("pending_text", "These meters are saved in options.json but the add-on hasn't picked them up yet. Restart the add-on to apply.")
      : hasPreview
        ? t("pending_preview_confirmed", "Added to configuration — waiting for first official reading")
        : t("pending_waiting_first_official", "Waiting for first telegram");

    return `
      <div class="notice warn" style="margin-bottom:14px;display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;">
        <div>
          <strong>${escapeHtml(title)}</strong>
          <div style="font-size:11px;color:#b0a060;margin-top:3px;">${escapeHtml(detail)}</div>
        </div>
        ${needsRestart ? `<button class="btn warn" data-action="restart" style="white-space:nowrap;flex-shrink:0;">${escapeHtml(t("restart_addon", "Restart add-on"))}</button>` : ""}
      </div>
    `;
  }

  function number(value) {
    const parsed = Number.parseInt(value ?? 0, 10);
    return Number.isFinite(parsed) ? parsed : 0;
  }

  function fmtTime(value) {
    if (!value) return "-";
    const text = String(value);
    const date = new Date(text);
    if (Number.isNaN(date.getTime())) return escapeHtml(text);
    return date.toLocaleString(undefined, {
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    });
  }

  function fmtClock(value) {
    if (!value) return "";
    const date = new Date(String(value));
    if (Number.isNaN(date.getTime())) return "";
    return date.toLocaleTimeString(undefined, {
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    });
  }

  function pill(ok, label) {
    const cls = ok ? "ok" : "bad";
    return `<span class="pill ${cls}"><span class="dot"></span>${escapeHtml(label)}</span>`;
  }

  function levelPill(level) {
    const raw = String(level || "info").toLowerCase();
    const cls = raw.includes("error") ? "bad" : raw.includes("warn") ? "warn" : "ok";
    return `<span class="pill ${cls}"><span class="dot"></span>${escapeHtml(raw)}</span>`;
  }

  function toast(message, isError = false) {
    state.toast = {message, isError};
    render();
    window.clearTimeout(toast.timer);
    toast.timer = window.setTimeout(() => {
      state.toast = null;
      render();
    }, 4800);
  }

  function clearToast() {
    state.toast = null;
    window.clearTimeout(toast.timer);
  }

  function currentLang() {
    return state.data?.i18n?.lang || liveLang || "";
  }

  function applyData(payload) {
    const previousI18n = state.data?.i18n;
    state.data = {...(state.data || {}), ...(payload || {})};
    if (!payload?.i18n && previousI18n) {
      state.data.i18n = previousI18n;
    }
    state.error = "";
  }

  async function fetchData(lang = "") {
    try {
      const url = lang ? `api/app?lang=${encodeURIComponent(lang)}` : "api/app";
      const response = await fetch(url, {cache: "no-store"});
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      applyData(await response.json());
      startLiveUpdates(state.data?.i18n?.lang || lang || currentLang());
    } catch (error) {
      state.error = `Cannot load dashboard data: ${error.message}`;
    } finally {
      state.loading = false;
      render();
    }
  }

  async function postApi(endpoint, payload) {
    const response = await fetch(`api/${endpoint}`, {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify(payload || {}),
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok || result.ok === false) {
      throw new Error(result.message || `HTTP ${response.status}`);
    }
    return result;
  }

  // Soft pipeline reload — backend touches /data/.reload_pipeline; bridge.sh's
  // watcher detects the flag (~2 s poll) and restarts the decode pipeline so
  // newly added/removed meters take effect WITHOUT a full container restart.
  // The webui process and MQTT broker connection stay alive — only the
  // decode wmbusmeters is recycled.
  function triggerSoftReload(message = "") {
    state.softReloading = true;
    state.softReloadingText = message || t("reloading_pipeline", "Applying meter changes…");
    clearToast();
    render();
    (async () => {
      try {
        await postApi("reload-pipeline", {});
      } catch (_) {
        // Endpoint failed — fall back to a normal refresh after a short wait.
      }
      await fetchData(currentLang());
      // Give bridge.sh ~5 s: 2 s flag poll + 2-3 s decode pipeline respawn.
      await new Promise(r => setTimeout(r, 5000));
      state.softReloading = false;
      state.softReloadingText = "";
      await fetchData(currentLang());
    })();
  }

  function startLiveUpdates(lang = "") {
    if (!window.EventSource) {
      state.liveConnected = false;
      return;
    }
    const nextLang = lang || currentLang();
    if (liveSource && liveLang === nextLang) return;
    if (liveSource) {
      liveSource.close();
      liveSource = null;
    }
    liveLang = nextLang;
    const url = nextLang ? `api/events?lang=${encodeURIComponent(nextLang)}` : "api/events";
    liveSource = new EventSource(url);
    liveSource.onopen = () => {
      state.liveConnected = true;
      scheduleRender();
    };
    // Server sends named SSE events: "event: state\ndata: ...\n\n"
    // onmessage only fires for unnamed events — must use addEventListener("state").
    liveSource.addEventListener("state", (event) => {
      try {
        applyData(JSON.parse(event.data));
        state.loading = false;
        state.liveConnected = true;
        scheduleRender();
      } catch (error) {
        state.liveConnected = false;
      }
    });
    liveSource.onerror = () => {
      state.liveConnected = false;
    };
  }

  function routeTitle(route) {
    const item = navItems.find(([id]) => id === route);
    return item ? t(item[1], item[0]) : t("dashboard_title", "Dashboard");
  }

  function navHtml(mobile = false) {
    const cls = mobile ? "mobile-nav" : "nav";
    return `<nav class="${cls}">${navItems
      .map(([id, key, mark]) => {
        const active = id === state.route ? " active" : "";
        const icon = mobile ? "" : `<span class="nav-ico">${mark}</span>`;
        return `<a class="${active}" href="#/${id}">${icon}<span>${escapeHtml(t(key, id))}</span></a>`;
      })
      .join("")}</nav>`;
  }

  function languageSelect(placement = "top") {
    const i18n = state.data?.i18n || {};
    const current = i18n.lang || "en";
    const labels = i18n.labels || {};
    const supported = asArray(i18n.supported).length ? i18n.supported : ["en", "pl", "de", "cs", "sk"];
    const label = t("language_label", "Language");
    return `
      <div class="lang-panel lang-panel-${escapeHtml(placement)}" aria-label="${escapeHtml(label)}">
        <div class="lang-label">${escapeHtml(label)}</div>
        <div class="lang-buttons">
          ${supported
            .map(
              (lang) => `
                <button class="lang-choice ${lang === current ? "active" : ""}" type="button" data-action="language" data-lang="${escapeHtml(lang)}" title="${escapeHtml(labels[lang] || lang.toUpperCase())}" aria-label="${escapeHtml(labels[lang] || lang.toUpperCase())}" aria-current="${lang === current ? "true" : "false"}">
                  <span class="flag flag-${escapeHtml(lang)}"></span>
                </button>
              `,
            )
            .join("")}
        </div>
      </div>
    `;
  }

  function shell(content) {
    const data = state.data || {};
    const meta = data.meta || {};
    const model = data.model || {};
    const title = routeTitle(state.route);
    const updatedAt = model.status?.updated_at || data.status?.updated_at || "";
    const runtime =
      meta.runtime === "home_assistant"
        ? t("webui_runtime_home_assistant", "Home Assistant")
        : t("webui_runtime_docker", "Docker");
    const dev = meta.is_dev ? '<span class="pill warn">DEV</span>' : "";

    return `
      <div class="app-shell">
        <aside class="sidebar">
          <div class="brand">
            <div class="brand-mark">WB</div>
            <div>
              <div class="brand-title">wMBus MQTT Bridge</div>
              <div class="brand-sub">v${escapeHtml(meta.version || "dev")} ${dev}</div>
            </div>
          </div>
          ${navHtml(false)}
          <div class="sidebar-foot">
            ${languageSelect("sidebar")}
            <span>${escapeHtml(runtime)}</span>
          </div>
        </aside>
        <main class="main">
          ${navHtml(true)}
          <header class="topbar">
            <div class="top-title">
              <h1>${escapeHtml(title)}</h1>
              <p>${escapeHtml(t("webui_updated", "Updated"))} ${fmtTime(updatedAt)}</p>
            </div>
            <div class="top-actions">
              ${languageSelect("top")}
              <span class="pill ${state.liveConnected ? "ok" : "muted"}"><span class="dot"></span>${state.liveConnected ? "LIVE" : "POLL"}</span>
              <button class="btn danger" data-action="restart">${escapeHtml(t("webui_restart", "Restart"))}</button>
            </div>
          </header>
          <div class="content">
            ${state.restarting
              ? `<div style="display:flex;flex-direction:column;align-items:center;justify-content:center;padding:80px 20px;gap:16px;">
                   <div style="font-size:36px;">🔄</div>
                   <div style="font-size:18px;font-weight:700;color:#f3c84b;">${escapeHtml(t("restarting_title", "Restarting add-on…"))}</div>
                   <div style="font-size:13px;color:#9eafba;">${escapeHtml(t("restarting_text", "Waiting for the add-on to come back online. This may take 10–30 seconds."))}</div>
                 </div>`
              : state.error ? `<div class="empty">${escapeHtml(state.error)}</div>` : content}
          </div>
        </main>
      </div>
      ${state.modal ? renderModal() : ""}
      ${state.softReloading ? `
        <div style="position:fixed;right:18px;bottom:18px;background:#1d2a18;color:#a3d870;border:1px solid #4a7332;padding:10px 16px;border-radius:8px;z-index:35;display:flex;align-items:center;gap:10px;font-size:13px;">
          <span style="font-size:18px;">⏳</span>
          <span>${escapeHtml(state.softReloadingText || t("reloading_pipeline", "Applying meter changes…"))}</span>
        </div>` : ""}
      ${state.toast ? `<div class="toast ${state.toast.isError ? "error" : ""}">${escapeHtml(state.toast.message)}</div>` : ""}
    `;
  }

  function metric(label, value, sub) {
    return `
      <div class="card metric">
        <span class="label">${escapeHtml(label)}</span>
        <span class="value">${escapeHtml(value)}</span>
        <span class="sub">${escapeHtml(sub || "")}</span>
      </div>
    `;
  }

  function statusCard(title, ok, detail) {
    return `
      <div class="card status-card">
        ${pill(ok, ok ? t("online_label", "Online") : t("attention_label", "Attention"))}
        <strong>${escapeHtml(title)}</strong>
        <span>${escapeHtml(detail || "")}</span>
      </div>
    `;
  }

  function statsPanel(model) {
    const current = Number(model.rate_current_min || 0);
    const previous = Number(model.rate_prev_min || 0);
    const trend = current - previous;
    const trendClass = trend > 0 ? "up" : trend < 0 ? "down" : "flat";
    const trendMark = trend > 0 ? "↑" : trend < 0 ? "↓" : "→";
    // Separate scales: candidates/meters share one scale, rate has its own.
    // Mixing raw_per_min (84.2) with candidate_count (5) as a single maxValue
    // makes candidate/meter bars nearly invisible while rate bar shows 100%.
    const countMax = Math.max(Number(model.candidate_count || 0), Number(model.meter_count || 0), 1);
    const rateMax  = Math.max(Number(model.raw_per_min || 0), 1);
    // Rate source badge
    const rateSource = model.rate_source || "bridge";
    const srcIcon  = rateSource === "esp" ? "📡" : "⚙";
    const srcColor = rateSource === "esp" ? "#00bcd4" : "#607a88";
    // In decode mode raw_per_min is computed from meters TSV (decoded telegrams),
    // not from candidates TSV (which is stale). Label reflects this.
    const inDecodeMode = Number(model.meter_count || 0) > 0;
    const rateLabel = inDecodeMode
      ? t("decoded_per_min_metric", "Decoded / min")
      : t("telegrams_per_min_metric", "Telegrams / min");
    const rateSuffix = rateSource === "esp"
      ? `${srcIcon} ESP 60s`
      : inDecodeMode
        ? t("rate_decoded_avg_label", "session avg (decoded)")
        : t("rate_session_avg_label", "60 min avg");

    return `
      <section class="section">
        <div class="card stats-panel">
          <div class="section-head">
            <h2>${escapeHtml(t("statistics", "Statistics"))}</h2>
          </div>
          <div class="stats-live">
            <div>
              <span>${escapeHtml(t("rate_current_min_label", "Current minute"))}</span>
              <strong>${escapeHtml(current)}</strong>
              <small>${escapeHtml(t("rate_tel_min", "tel / min"))}</small>
            </div>
            <div>
              <span>${escapeHtml(t("rate_prev_min_label", "Previous minute"))}</span>
              <strong>${escapeHtml(previous)}</strong>
              <small>${escapeHtml(t("rate_tel_min", "tel / min"))}</small>
            </div>
            <div class="trend ${trendClass}">
              <span>${escapeHtml(t("rate_trend_label", "Trend"))}</span>
              <strong>${trendMark}</strong>
              <small>${trend > 0 ? "+" : ""}${escapeHtml(trend)} ${escapeHtml(t("rate_vs_prev", "vs previous"))}</small>
            </div>
          </div>
          <div style="text-align:right;font-size:10px;color:#4d6875;padding-top:4px;border-top:1px solid #1a3344;margin-top:4px;">
            ${escapeHtml(t("rate_source_label", "Rate source"))}: <span style="color:${srcColor};font-weight:700;">${srcIcon} ${escapeHtml(rateSource)}</span>
          </div>
          <div class="stats-bars">
            ${statsRow("candidate", t("detected_candidates", "Detected candidates"), model.candidate_count || 0, model.candidate_count || 0, countMax)}
            ${statsRow("meter", t("configured_meters", "Configured meters"), model.meter_count || 0, model.meter_count || 0, countMax)}
            ${statsRow("rate", rateLabel, model.raw_per_min || 0, model.raw_per_min || 0, rateMax, rateSuffix)}
          </div>
        </div>
      </section>
    `;
  }

  function statsRow(type, label, value, barValue, maxValue, suffix = "") {
    const numeric = Number(barValue || 0);
    const pct = numeric > 0 ? Math.max(3, Math.min(100, Math.round((numeric / maxValue) * 100))) : 1;
    return `
      <div class="stats-row ${type}">
        <span class="stats-icon"></span>
        <div class="stats-label">
          <span>${escapeHtml(label)}</span>
          <strong>${escapeHtml(value)}</strong>
        </div>
        <div class="stats-track"><span style="width:${pct}%"></span></div>
        ${suffix ? `<small>${escapeHtml(suffix)}</small>` : ""}
      </div>
    `;
  }

  // Unified pending panel for the dashboard — merges "needs restart" and
  // "waiting for first telegram" into one box (like old webui render_pending_panel
  // + render_waiting_panel, but combined). Restart button is shown only when
  // model.pending_restart is true (options.json newer than status.json = addon
  // not restarted yet). After restart the button disappears but meters remain
  // listed until the first telegram is decoded.
  function dashboardPendingPanel(pending, model, analysis) {
    if (pending.length === 0) return "";

    const needsRestart = !!model.pending_restart;
    const hasPreview = pending.some(row => pendingPreviewDecoded(row) || String(row.preview_value || "").trim());

    const title = needsRestart
      ? t("pending_title", "Pending changes — waiting for restart")
      : t("waiting_for_telegrams_title", "Waiting for first telegram");

    const text = needsRestart
      ? t("pending_text", "These meters are saved in options.json but the add-on hasn't picked them up yet. Restart the add-on to apply.")
      : hasPreview
        ? t("pending_preview_confirmed", "Added to configuration — waiting for first official reading")
        : t("pending_waiting_first_official", "Waiting for first telegram");

    const rows = pending.map(m => pendingMeterRow(m, analysis)).join("");

    return `
      <div class="notice warn" style="margin-bottom:14px;">
        <div style="display:flex;justify-content:space-between;align-items:flex-start;gap:12px;flex-wrap:wrap;margin-bottom:10px;">
          <div>
            <strong>${needsRestart ? "⚠ " : "⏳ "}${escapeHtml(title)}</strong>
            <div style="font-size:11px;color:#b0a060;margin-top:3px;">${escapeHtml(text)}</div>
          </div>
          ${needsRestart ? `<button class="btn warn" data-action="restart" style="white-space:nowrap;flex-shrink:0;">${escapeHtml(t("restart_addon", "Restart add-on"))}</button>` : ""}
        </div>
        <div class="table-wrap" style="margin-top:4px;">
          <table>
            <thead>
              ${pendingMeterHeader()}
            </thead>
            <tbody>${rows}</tbody>
          </table>
        </div>
      </div>
    `;
  }

  // ──────────────────────────────────────────────────────────────────────
  // Dashboard view toggle — Pipeline vs Statystyki
  // Segmented control that switches the top-of-PANEL section between the
  // data-flow diagram (with drill-down nodes) and the speed-dial + funnel +
  // sparkline view. User preference persists in localStorage.
  // ──────────────────────────────────────────────────────────────────────
  function dashboardViewToggle() {
    const v = state.dashboardView;
    const btn = (key, label, icon) => `
      <button class="view-toggle-btn ${v === key ? "active" : ""}"
              data-action="dashboard-view" data-view="${key}" type="button">
        ${icon} ${escapeHtml(label)}
      </button>`;
    return `
      <div class="view-toggle">
        ${btn("pipeline", t("view_pipeline", "Pipeline"), "🔌")}
        ${btn("stats",    t("view_stats",    "Statystyki"), "📊")}
      </div>
    `;
  }

  // ──────────────────────────────────────────────────────────────────────
  // Pipeline header — ESP → MQTT → wmbusmeters → HA
  // Each node shows a status dot and a one-line metric. Click drills down
  // into a workspace panel below. The horizontal arrows carry the current
  // telegrams/min rate so the user sees data flowing through every stage.
  // ──────────────────────────────────────────────────────────────────────
  function pipelineHeader(model) {
    const data = state.data || {};
    const pipe = model.pipe || {};
    const mqtt = model.mqtt || {};
    const esp  = (data.esp || {}).diag || {};
    const espRateFromDiag = model.rate_source === "esp";
    const cur  = Number(model.rate_current_min || 0);
    const rateLabel = `${cur}/min`;

    const cls = (active) => state.workspace === active ? "pipeline-node active" : "pipeline-node";
    // .dot.ok = green, .dot.warn = yellow, .dot.bad = red (CSS standalone rules)
    // "live" adds a soft glow to signal real-time activity (rate > 0).
    const dot = (ok, warn, live) => {
      const cls = ok ? (live ? "ok live" : "ok") : (warn ? "warn" : "bad");
      return `<span class="dot ${cls}"></span>`;
    };

    const meterCount     = Number(model.meter_count || 0);
    const candidateCount = Number(model.candidate_count || 0);
    const rawCount       = Number(model.raw_count || 0);
    const decodedCount   = Number(model.decoded_count || 0);
    const hasLiveRate    = cur > 0;

    // Multi-ESP support: webui.py exposes esp.devices[] with status based on
    // the primary wmbus/+/telegram topic: online <=2 min, warn <=5 min,
    // offline after that. diag/summary is displayed as context only.
    const espDevicesAll    = asArray((data.esp || {}).devices);
    const espActiveDevices = espDevicesAll.filter(d => d && d.active);
    const espOnlineDevices = espDevicesAll.filter(d => d && d.health === "online");
    const espWarnDevices   = espDevicesAll.filter(d => d && d.health === "warn");
    const espCount         = Number((data.esp || {}).devices_count || espActiveDevices.length || 0);
    const isMultiEsp       = espCount > 1;
    const espTitle         = isMultiEsp ? `${espCount} × ESP` : "ESP";
    const raw15m           = Number(model.raw_15m || 0);
    const espOnline        = espOnlineDevices.length > 0;
    const espWarn          = !espOnline && espWarnDevices.length > 0;
    const espSeen          = espDevicesAll.length > 0 || (esp && Object.keys(esp).length > 0) || raw15m > 0;
    const espRssi          = esp.avg_ok_rssi ? `${esp.avg_ok_rssi} dBm` : "—";

    // Status text + rate. The rate comes from model.rate_current_min which
    // status_model() already populates either from ESP's diag.total (when
    // rate_source=="esp") or from bridge.sh's own per-minute counter.
    const rateSuffix = cur > 0 ? ` · ${cur}/min` : "";
    let espStatus = t("pipeline_esp_none", "n/a");
    if (espOnline) {
      espStatus = t("pipeline_esp_active", "active") + rateSuffix;
    } else if (espWarn) {
      espStatus = t("silent_label", "silent") + rateSuffix;
    } else if (espSeen) {
      espStatus = t("offline_label", "offline") + rateSuffix;
    }

    // Source topic — the device segment of the primary (most recent) ESP.
    // Falls back to esp.diag._topic if events are empty (e.g. fresh start
    // with only diag/summary received, no other events yet). The bridge.sh
    // diag/summary subscriber now records the topic as `_topic` in
    // status_esp_diag.json. Show in compact form (just device name).
    // Source topic — most-recent ACTIVE device first. If nothing's active
    // right now fall back to whatever esp.diag._topic remembers from the
    // last summary (could be stale but still informative). Final fallback
    // is the all-devices list (a "ghost" name from MQTT retained).
    const primaryDeviceObj = espActiveDevices[0] || espDevicesAll[0];
    const primaryTopic = (primaryDeviceObj && primaryDeviceObj.topic)
      || (esp && esp._topic)
      || "";
    const topicParts = primaryTopic ? primaryTopic.split("/") : [];
    const primaryDevice = topicParts.length >= 2 ? topicParts[1] : (primaryTopic || "—");

    const espVisibleLine = `${candidateCount} ${t("pipeline_visible_count", "widocznych")} · ${escapeHtml(espRssi)}`;
    // Compact device line. Multi-ESP: ACTIVE devices only, comma-separated
    // (max 3 visible). Inactive/ghost devices stay hidden here — they're
    // shown in the ESP workspace drill-down with a different style.
    const espDeviceSource = espActiveDevices.length > 0 ? espActiveDevices : espDevicesAll.slice(0, 1);
    const espDeviceLine = isMultiEsp
      ? espDeviceSource.slice(0, 3).map(d => d.name).join(", ") + (espDeviceSource.length > 3 ? ` +${espDeviceSource.length - 3}` : "")
      : primaryDevice;

    // ─── wmbusmeters node ───
    // "received / decoded" — raw telegram count vs successfully decoded JSON.
    // The ratio tells the user how much of the air is actually their meters.
    const wmbusLine = `${rawCount} / ${decodedCount}`;
    const wmbusLabel = meterCount > 0
      ? t("pipeline_wmbus_dec_list", "DEC + LIST")  // both instances run
      : t("pipeline_wmbus_listen_only", "LISTEN");   // single instance, no decode targets yet
    const wmbusOk = !!model.wmbus_ok;
    const wmbusWarn = candidateCount > 0 && meterCount === 0;  // hearing but nothing configured
    const haPublishedTime = fmtClock(pipe.discovery_published_at || "");
    const haStatus = model.discovery_ok
      ? (haPublishedTime
          ? t("pipeline_ha_published_at", "published at {time}", {time: haPublishedTime})
          : t("pipeline_ha_published", "published"))
      : t("pipeline_ha_pending", "pending");

    return `
      <section class="section">
        <div class="pipeline">
          <button class="${cls("esp")}" data-action="open-workspace" data-ws="esp" type="button">
            <div class="pipeline-icon">📡</div>
            <div class="pipeline-title">${escapeHtml(espTitle)}</div>
            <div class="pipeline-meta">${dot(espOnline, espWarn, espOnline && hasLiveRate && espRateFromDiag)} ${escapeHtml(espStatus)}</div>
            <div class="pipeline-sub">${escapeHtml(espVisibleLine)}</div>
            <div class="pipeline-sub pipeline-device" title="${escapeHtml(primaryTopic || "")}">${escapeHtml(espDeviceLine)}</div>
          </button>
          <div class="pipeline-arrow"><span>${escapeHtml(rateLabel)}</span></div>
          <button class="${cls("mqtt")}" data-action="open-workspace" data-ws="mqtt" type="button">
            <div class="pipeline-icon">📨</div>
            <div class="pipeline-title">MQTT</div>
            <div class="pipeline-meta">${dot(!!model.mqtt_ok, false, !!model.mqtt_ok && hasLiveRate)} ${escapeHtml(model.mqtt_ok ? t("pipeline_mqtt_online", "online") : t("pipeline_mqtt_offline", "offline"))}</div>
            <div class="pipeline-sub">${escapeHtml((mqtt.host || "—") + (mqtt.port ? ":" + mqtt.port : ""))}</div>
          </button>
          <div class="pipeline-arrow"><span>${escapeHtml(rateLabel)}</span></div>
          <button class="${cls("wmbus")}" data-action="open-workspace" data-ws="wmbus" type="button">
            <div class="pipeline-icon">⚙</div>
            <div class="pipeline-title">wmbusmeters</div>
            <div class="pipeline-meta">${dot(wmbusOk, wmbusWarn, wmbusOk && hasLiveRate)} ${escapeHtml(wmbusLabel)}</div>
            <div class="pipeline-sub" title="${escapeHtml(t("pipeline_wmbus_tooltip", "received / decoded"))}">${escapeHtml(wmbusLine)}</div>
          </button>
          <div class="pipeline-arrow"><span>${escapeHtml(rateLabel)}</span></div>
          <button class="${cls("ha")}" data-action="open-workspace" data-ws="ha" type="button">
            <div class="pipeline-icon">🏠</div>
            <div class="pipeline-title">HA</div>
            <div class="pipeline-meta">${dot(!!model.discovery_ok, meterCount === 0, !!model.discovery_ok)} ${escapeHtml(haStatus)}</div>
            <div class="pipeline-sub">${meterCount} ${escapeHtml(t("pipeline_ha_entities_short", "entit."))}</div>
          </button>
        </div>
        ${pipelineWorkspace(model)}
      </section>
    `;
  }

  // Drill-down panel under the pipeline diagram. Shown only when a node is
  // selected (state.workspace != null). Closes via [← Powrót] button.
  function pipelineWorkspace(model) {
    if (!state.workspace) return "";
    const data = state.data || {};
    const back = `
      <div class="workspace-back">
        <button class="btn" data-action="close-workspace" type="button">← ${escapeHtml(t("workspace_back", "Back"))}</button>
      </div>`;
    let body = "";
    if (state.workspace === "esp") {
      const esp = data.esp || {};
      const sug  = esp.suggestion || {};
      const devices = asArray(esp.devices);
      // Multi-device table — one row per ESP receiver heard by the bridge.
      // Green = telegram heard within 2 minutes, orange = telegram silence
      // between 2 and 5 minutes, red = no telegram for more than 5 minutes.
      const activeDevs = devices.filter(d => d && d.active);
      const totalDevs  = devices.length;
      const counter    = (totalDevs > activeDevs.length)
        ? `${activeDevs.length} / ${totalDevs}`
        : `${totalDevs}`;
      const devicesTable = devices.length ? `
        <h4 style="margin-top:14px;">📡 ${escapeHtml(t("workspace_esp_devices_title", "Connected ESP devices"))}
          <span style="font-size:11px;color:#8ea4b1;font-weight:400;margin-left:6px;">${counter}</span>
        </h4>
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>${escapeHtml(t("workspace_esp_device_status", "Status"))}</th>
                <th>${escapeHtml(t("workspace_esp_device_name", "Device"))}</th>
                <th>${escapeHtml(t("workspace_esp_device_topic", "Topic"))}</th>
                <th style="text-align:right;">${escapeHtml(t("workspace_esp_device_telegrams", "Telegrams"))}</th>
                <th style="text-align:center;">${escapeHtml(t("workspace_esp_device_diag", "Diag"))}</th>
                <th>${escapeHtml(t("workspace_esp_device_last_event", "Last event"))}</th>
              </tr>
            </thead>
            <tbody>
              ${devices.map(d => {
                const epoch = Number(d.last_seen_epoch || 0);
                const when = epoch > 0 ? new Date(epoch * 1000).toLocaleString() : "—";
                const health = String(d.health || (d.active ? "online" : "offline"));
                const isOffline = health === "offline";
                const rowStyle = isOffline ? "opacity:0.65;" : "";
                const statusMeta = health === "online"
                  ? {cls: "ok live", label: t("pipeline_esp_active", "active")}
                  : (health === "warn"
                      ? {cls: "warn", label: t("silent_label", "silent")}
                      : {cls: "bad", label: t("offline_label", "offline")});
                const statusCell = `<span class="dot ${statusMeta.cls}" style="margin-right:5px;"></span>${escapeHtml(statusMeta.label)}`;
                const tgCount = Number(d.telegram_count || 0);
                const tgCell  = tgCount > 0 ? String(tgCount) : "—";
                const diagCell = d.has_diag
                  ? `<span class="pill ok" style="font-size:10px;">✓</span>`
                  : `<span class="pill muted" style="font-size:10px;">—</span>`;
                return `
                  <tr style="${rowStyle}">
                    <td style="white-space:nowrap;font-size:11px;">${statusCell}</td>
                    <td><strong>${escapeHtml(d.name || "—")}</strong></td>
                    <td class="mono" style="font-size:11px;color:#9eafba;">${escapeHtml(d.topic || "—")}</td>
                    <td style="text-align:right;font-family:monospace;font-size:12px;">${escapeHtml(tgCell)}</td>
                    <td style="text-align:center;">${diagCell}</td>
                    <td style="white-space:nowrap;font-size:11px;">${escapeHtml(when)}</td>
                  </tr>`;
              }).join("")}
            </tbody>
          </table>
        </div>
        ${totalDevs > activeDevs.length ? `<p style="font-size:11px;color:#8ea4b1;margin:8px 0 0;">⚠ ${escapeHtml(t("workspace_esp_stale_hint", "Stale entries are from MQTT retained messages or past sessions. They don't count toward the active ESP badge."))}</p>` : ""}` : "";
      body = `
        <h3>📡 ESP — ${escapeHtml(t("workspace_esp_title", "ESP diagnostics"))}</h3>
        ${devicesTable}
        ${Object.keys(sug).length ? `<h4 style="margin-top:14px;">💡 ${escapeHtml(t("webui_suggestion", "Suggestion"))}</h4>${objectKv(sug)}` : ""}
      `;
    } else if (state.workspace === "mqtt") {
      const mqtt = model.mqtt || {};
      const cfg  = model.cfg  || {};
      body = `
        <h3>📨 MQTT</h3>
        <div class="kv">
          <div>${escapeHtml(t("workspace_mqtt_host", "Broker"))}</div><div>${escapeHtml((mqtt.host || "—") + (mqtt.port ? ":" + mqtt.port : ""))}</div>
          <div>${escapeHtml(t("workspace_mqtt_state", "Connected"))}</div><div>${model.mqtt_ok ? "✓ yes" : "✗ no"}</div>
          <div>${escapeHtml(t("workspace_mqtt_raw_topic", "RAW topic"))}</div><div class="mono">${escapeHtml(cfg.raw_topic || "—")}</div>
          <div>${escapeHtml(t("workspace_mqtt_state_prefix", "State prefix"))}</div><div class="mono">${escapeHtml(cfg.state_prefix || "—")}</div>
          <div>${escapeHtml(t("workspace_mqtt_discovery_prefix", "Discovery prefix"))}</div><div class="mono">${escapeHtml(cfg.discovery_prefix || "—")}</div>
        </div>
      `;
    } else if (state.workspace === "wmbus") {
      const pipe = model.pipe || {};
      const meterCount = Number(model.meter_count || 0);
      const candidateCount = Number(model.candidate_count || 0);
      body = `
        <h3>⚙ wmbusmeters</h3>
        <div class="kv">
          <div>${escapeHtml(t("workspace_wmbus_decode", "DECODE instance"))}</div><div>${pipe.wmbusmeters_running ? "🟢 running" : "🔴 down"} — ${meterCount} ${escapeHtml(t("workspace_wmbus_meters_configured", "meters configured"))}</div>
          <div>${escapeHtml(t("workspace_wmbus_listen", "LISTEN instance"))}</div><div>🟢 ${escapeHtml(t("workspace_wmbus_listen_desc", "parallel — always-on candidate visibility"))}</div>
          <div>${escapeHtml(t("workspace_wmbus_candidates", "Candidates in air"))}</div><div>${candidateCount}</div>
          <div>${escapeHtml(t("workspace_wmbus_decoded_total", "Decoded telegrams (session)"))}</div><div>${Number(model.decoded_count || 0)}</div>
          <div>${escapeHtml(t("workspace_wmbus_last_decoded", "Last decoded"))}</div><div>${fmtTime(pipe.last_decoded_seen)}</div>
        </div>
        <div style="margin-top:14px;display:flex;gap:8px;flex-wrap:wrap;">
          <button class="btn warn" data-action="restart" type="button">${escapeHtml(t("restart_addon", "Restart add-on"))}</button>
        </div>
      `;
    } else if (state.workspace === "ha") {
      const cfg  = model.cfg || {};
      const meterCount = Number(model.meter_count || 0);
      body = `
        <h3>🏠 ${escapeHtml(t("workspace_ha_title", "Home Assistant"))}</h3>
        <div class="kv">
          <div>${escapeHtml(t("discovery_label", "Discovery"))}</div><div>${model.discovery_ok ? "✓ published" : "✗ pending"}</div>
          <div>${escapeHtml(t("workspace_ha_prefix", "Discovery prefix"))}</div><div class="mono">${escapeHtml(cfg.discovery_prefix || "—")}</div>
          <div>${escapeHtml(t("workspace_ha_state_prefix", "State prefix"))}</div><div class="mono">${escapeHtml(cfg.state_prefix || "—")}</div>
          <div>${escapeHtml(t("workspace_ha_entities", "Entities published"))}</div><div>${meterCount}</div>
        </div>
      `;
    }
    return `<div class="pipeline-workspace">${back}${body}</div>`;
  }

  // ──────────────────────────────────────────────────────────────────────
  // Sparkline — inline SVG polyline of the last 15 minutes of telegrams/min.
  // Bars (not line) chosen because rate fluctuates discretely per minute.
  // Hovering a bar shows the exact value as a native tooltip.
  // ──────────────────────────────────────────────────────────────────────
  function sparkline15min(history) {
    const rows = asArray(history);
    if (!rows.length) {
      return `<div style="font-size:11px;color:#607a88;">${escapeHtml(t("sparkline_no_data", "No data yet — wait for the first minute boundary"))}</div>`;
    }
    const max = Math.max(1, ...rows.map(r => Number(r.count || 0)));
    const W = 280, H = 56, gap = 2;
    const barW = Math.max(2, Math.floor((W - (rows.length - 1) * gap) / rows.length));
    const bars = rows.map((r, i) => {
      const v = Number(r.count || 0);
      const h = Math.max(1, Math.round((v / max) * (H - 4)));
      const x = i * (barW + gap);
      const y = H - h;
      return `<rect x="${x}" y="${y}" width="${barW}" height="${h}" fill="#00d4c8" rx="1"><title>${escapeHtml(String(v))} tel/min</title></rect>`;
    }).join("");
    return `
      <svg class="sparkline" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" style="width:100%;max-width:${W}px;height:${H}px;display:block;">
        ${bars}
      </svg>
      <div style="display:flex;justify-content:space-between;font-size:10px;color:#607a88;margin-top:2px;">
        <span>−${rows.length} min</span>
        <span>${escapeHtml(t("sparkline_axis_now", "now"))}</span>
      </div>
    `;
  }

  // ──────────────────────────────────────────────────────────────────────
  // Stats view (alternative to pipeline) — speed dial + sparkline + funnel.
  // Replaces the old mixed-style statsPanel. Funnel uses a consistent
  // "max = candidate_count" baseline so the relative coverage is obvious.
  // ──────────────────────────────────────────────────────────────────────
  function statsViewSpeedDial(model) {
    const cur  = Number(model.rate_current_min || 0);
    const prev = Number(model.rate_prev_min || 0);
    const avg  = Number(model.raw_per_min || 0);
    const delta = cur - prev;
    const trendColor = delta > 0 ? "#2de36f" : (delta < 0 ? "#ff646b" : "#8ea4b1");
    const trendArrow = delta > 0 ? "↑" : (delta < 0 ? "↓" : "→");
    const trendText  = `${delta > 0 ? "+" : ""}${delta}`;
    const source = model.rate_source || "bridge";
    const srcIcon  = source === "esp" ? "📡" : "⚙";

    return `
      <div class="speed-dial">
        <div class="speed-dial-main">
          <div class="speed-dial-value">${escapeHtml(String(cur))}</div>
          <div class="speed-dial-unit">${escapeHtml(t("rate_tel_min", "tel / min"))}</div>
        </div>
        <div class="speed-dial-side">
          <div>
            <span style="color:${trendColor};font-weight:800;font-size:18px;">${trendArrow} ${escapeHtml(trendText)}</span>
            <span style="font-size:11px;color:#8ea4b1;margin-left:6px;">${escapeHtml(t("rate_vs_prev", "vs previous"))} (${prev})</span>
          </div>
          <div style="font-size:11px;color:#8ea4b1;margin-top:6px;">
            ${escapeHtml(t("rate_session_avg_label", "session avg"))}: <strong style="color:#cbd9e1;">${escapeHtml(String(avg))}</strong> ${escapeHtml(t("rate_tel_min", "tel / min"))}
          </div>
          <div style="font-size:10px;color:#4d6875;margin-top:4px;">
            ${escapeHtml(t("rate_source_label", "Rate source"))}: <span style="color:${source === "esp" ? "#00bcd4" : "#607a88"};font-weight:700;">${srcIcon} ${escapeHtml(source)}</span>
          </div>
        </div>
      </div>
      <div style="margin-top:12px;">
        <div style="font-size:11px;color:#8ea4b1;margin-bottom:4px;">${escapeHtml(t("sparkline_title", "Last 15 minutes"))}</div>
        ${sparkline15min(model.rate_history_15m || [])}
      </div>
    `;
  }

  function statsViewFunnel(model) {
    const candidates = Number(model.candidate_count || 0);
    const meters     = Number(model.meter_count || 0);
    // "Decodes live" = configured meters with at least one telegram in last 15 min.
    // We approximate from session data — exact figure requires per-meter freshness check.
    const liveMeters = asArray((state.data || {}).meters).filter(m => Number(m.seen_15m || 0) > 0).length;
    const baseline   = Math.max(candidates, 1);
    const pct1       = candidates > 0 ? Math.round((meters / candidates) * 100) : 0;
    const pct2       = meters > 0     ? Math.round((liveMeters / meters) * 100) : 0;

    const barW = (n) => Math.max(2, Math.round((n / baseline) * 100));
    const row = (icon, label, value, pctOfTotal, pctOfPrev, pctLabel, color) => `
      <div class="funnel-row">
        <div class="funnel-row-head">
          <span class="funnel-icon">${icon}</span>
          <span class="funnel-label">${escapeHtml(label)}</span>
          <span class="funnel-value">${escapeHtml(String(value))}</span>
        </div>
        <div class="funnel-bar"><span style="width:${pctOfTotal}%;background:${color};"></span></div>
        ${pctLabel ? `<div class="funnel-pct">${escapeHtml(pctLabel)}</div>` : ""}
      </div>`;
    return `
      <h3 style="margin:0 0 12px;font-size:14px;color:#cbd9e1;">🎯 ${escapeHtml(t("funnel_title", "Coverage"))}</h3>
      ${row("📡", t("funnel_in_air",      "In air"),         candidates, 100,                  null, null, "#7e57c2")}
      <div class="funnel-arrow">↓ ${pct1}% ${escapeHtml(t("funnel_of_air", "of air → configured"))}</div>
      ${row("⚙",  t("funnel_configured",  "Configured"),     meters,     barW(meters),         null, null, "#26a69a")}
      <div class="funnel-arrow">↓ ${pct2}% ${escapeHtml(t("funnel_of_conf", "of configured → live"))}</div>
      ${row("✓",  t("funnel_live",        "Decodes live"),   liveMeters, barW(liveMeters),     null, null, "#2de36f")}
    `;
  }

  function dashboardStatsView(model) {
    return `
      <section class="section">
        <div class="card">
          ${statsViewSpeedDial(model)}
        </div>
      </section>
      <section class="section">
        <div class="card">
          ${statsViewFunnel(model)}
        </div>
      </section>
    `;
  }

  function dashboard() {
    const data = state.data || {};
    const model = data.model || {};
    const recentMeters = asArray(data.meters).slice(0, 6);
    const meterCount = Number(model.meter_count || 0);
    const candidateCount = Number(model.candidate_count || 0);

    const pending = pendingMeters();

    // Top section depends on selected dashboard view.
    const topSection = state.dashboardView === "stats"
      ? dashboardStatsView(model)
      : pipelineHeader(model);

    // When the user has no configured meters yet, the meters table would
    // be empty and we'd be showing the candidates table separately — which
    // duplicates the Discover (Odbierane) page. Instead show a single CTA
    // pointing the user to Odbierane so adding the first meter is one click
    // away. After meters are configured, this section shows them.
    const metersSection = meterCount === 0
      ? `
        <section class="section">
          <div class="empty" style="display:flex;flex-direction:column;align-items:center;gap:12px;padding:30px 20px;text-align:center;">
            <span style="font-size:32px;">📡</span>
            <div>
              <strong style="color:#cbd9e1;display:block;margin-bottom:4px;">${escapeHtml(t("dashboard_no_meters_title", "No configured meters yet"))}</strong>
              <div style="font-size:12px;color:#8ea4b1;">
                ${candidateCount > 0
                  ? escapeHtml(t("dashboard_no_meters_with_candidates", "We're hearing {n} IDs in the air. Go to Received / Search to identify and add yours.").replace("{n}", String(candidateCount)))
                  : escapeHtml(t("dashboard_no_meters_idle", "Waiting for telegrams. Make sure your ESP receiver is publishing to the configured MQTT topic."))}
              </div>
            </div>
            <a href="#discover" class="btn primary" style="text-decoration:none;">
              ${escapeHtml(t("dashboard_go_to_discover", "Go to Received / Search"))} →
            </a>
          </div>
        </section>`
      : `
        <section class="section">
          <div class="section-head"><h2>${escapeHtml(t("webui_recent_meters", "Recent meters"))}</h2><span>${recentMeters.length} ${escapeHtml(t("webui_shown", "shown"))}</span></div>
          ${meterTable(recentMeters, false)}
        </section>`;

    return `
      ${dashboardViewToggle()}
      ${topSection}

      ${dashboardPendingPanel(pending, model, data.analysis || {})}

      ${metersSection}

      <section class="section">
        <div class="section-head"><h2>${escapeHtml(t("recent_events_title", "Recent events"))}</h2><span>${asArray(data.events).length} ${escapeHtml(t("webui_total", "total"))}</span></div>
        ${eventsList(asArray(data.events).slice(0, 8))}
      </section>
    `;
  }

  function meterTable(rows, withActions = true) {
    if (!rows.length) return `<div class="empty">${escapeHtml(t("webui_no_meters", "No meters yet."))}</div>`;
    return `
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>${escapeHtml(t("webui_id", "ID"))}</th>
              <th>${escapeHtml(t("webui_name", "Name"))}</th>
              <th>${escapeHtml(t("driver", "Driver"))}</th>
              <th>${escapeHtml(t("manufacturer_col", "Manufacturer"))}</th>
              <th>${escapeHtml(t("webui_value", "Value"))}</th>
              <th>${escapeHtml(t("webui_last_seen", "Last seen"))}</th>
              <th>${escapeHtml(t("reception", "Reception"))}</th>
              ${withActions ? "<th></th>" : ""}
            </tr>
          </thead>
          <tbody>
            ${rows
              .map((row) => {
                const id      = row.id || row.meter_id || "";
                // Age-adjust seen_15m / seen_60m like old webui does:
                // if last_seen is older than the window, the counter is stale — zero it.
                const lastSeenDate = row.last_seen ? new Date(row.last_seen) : null;
                const ageS = (lastSeenDate && !isNaN(lastSeenDate))
                  ? (Date.now() - lastSeenDate.getTime()) / 1000
                  : Infinity;
                const seen15m = ageS > 15 * 60 ? 0 : Number(row.seen_15m || 0);
                const seen60m = ageS > 60 * 60 ? 0 : Number(row.seen_60m || 0);
                const {label: statusLabel, color: statusColor} = meterStatusLabel(seen15m, seen60m);
                const {icon: mIcon} = mediaIcon(row.media || "", row.driver || "");
                const mfrRaw     = String(row.manufacturer || "").trim();
                const mfrCompact = compactManufacturer(mfrRaw);
                const mfrCell    = mfrCompact
                  ? `<span style="font-size:12px;color:#9eafba;" title="${escapeHtml(mfrRaw)}">${escapeHtml(mfrCompact)}</span>`
                  : `<span style="color:#4a6070;">—</span>`;
                return `
                  <tr>
                    <td><strong>${escapeHtml(id)}</strong></td>
                    <td><span style="margin-right:5px;font-size:15px;vertical-align:middle;">${mIcon}</span>${escapeHtml(row.name || row.id || "-")}</td>
                    <td>${escapeHtml(row.driver || "-")}</td>
                    <td>${mfrCell}</td>
                    <td>
                      ${meterValueCell(row)}
                    </td>
                    <td>${fmtTime(row.last_seen)}</td>
                    <td style="white-space:nowrap;">
                      <span style="color:${statusColor};font-size:11px;font-weight:600;">${escapeHtml(statusLabel)}</span>
                      <span style="margin-left:5px;">${signalBars(seen15m)}</span>
                      <div style="font-size:10px;color:#607a88;">${escapeHtml(fmtInterval(row.avg_interval_s))}</div>
                    </td>
                    ${
                      withActions
                        ? `<td><div class="actions"><button class="btn danger" data-action="remove-meter" data-id="${escapeHtml(id)}">${escapeHtml(t("webui_remove", "Remove"))}</button></div></td>`
                        : ""
                    }
                  </tr>
                `;
              })
              .join("")}
          </tbody>
        </table>
      </div>
    `;
  }

  function candidateTable(rows, withActions = true) {
    if (!rows.length) return `<div class="empty">${escapeHtml(t("webui_no_candidates", "No visible candidates."))}</div>`;
    // analysis is keyed by meter ID
    const analysis = (state.data || {}).analysis || {};
    // Parallel LISTEN instance keeps candidate stats LIVE in decode mode too —
    // bridge.sh now runs a secondary wmbusmeters that always feeds candidate
    // TSV updates regardless of how many meters the user has configured.
    // No more "stale" warning needed.
    return `
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>${escapeHtml(t("webui_id", "ID"))}</th>
              <th>${escapeHtml(t("driver", "Driver"))}</th>
              <th>${escapeHtml(t("webui_type", "Type"))}</th>
              <th>${escapeHtml(t("media", "Medium"))}</th>
              <th>${escapeHtml(t("manufacturer_col", "Manufacturer"))}</th>
              <th>${escapeHtml(t("encryption_label", "Encryption"))}</th>
              <th>${escapeHtml(t("preview_value_col", "Preview value"))}</th>
              <th>${escapeHtml(t("webui_last_seen", "Last seen"))}</th>
              <th>15m</th>
              <th>60m</th>
              <th>${escapeHtml(t("reception", "Interval"))}</th>
              ${withActions ? "<th></th>" : ""}
            </tr>
          </thead>
          <tbody id="discover-candidates-tbody">
            ${rows
              .map((row) => {
                const id     = row.id || "";
                const driver = row.driver || "auto";
                const {mc}   = mediaIcon(row.type || "", driver);
                const mediaLabel = t(`media_${mc}`, mc);
                // look up analysis by id (may be stored lowercase or uppercase)
                const a    = analysis[id] || analysis[id.toUpperCase()] || row.analysis || {};
                const enc  = String(a.encryption || "").toLowerCase();
                const note = String(a.note || "");
                // Age-adjust seen_15m / seen_60m like old webui: stale counter from a
                // previous session must not be shown for a meter not seen recently.
                // Now safe to always apply — parallel LISTEN instance keeps the
                // candidates TSV fresh in both LISTEN and DECODE modes.
                const lastSeenDate = row.last_seen ? new Date(row.last_seen) : null;
                const ageS = (lastSeenDate && !isNaN(lastSeenDate))
                  ? (Date.now() - lastSeenDate.getTime()) / 1000
                  : Infinity;
                const seen15mAdj = ageS > 15 * 60 ? 0 : Number(row.seen_15m || 0);
                const seen60mAdj = ageS > 60 * 60 ? 0 : Number(row.seen_60m || 0);
                // Values are decoded automatically by the parallel LISTEN instance
                // for candidates that are not explicitly marked as AES/encrypted.
                const previewVal    = String(row.preview_value || "").trim();
                const previewKey    = String(row.preview_value_key || "").trim();
                const previewUnit   = previewKey ? unitFromKey(previewKey) : "";
                const previewState  = String(row.preview_state || "").trim();
                // Parallel LISTEN decoded a valid JSON telegram without an AES key →
                // encryption is resolved as no_aes. Override "unknown" for display only;
                // status_candidate_analysis.tsv is updated asynchronously by bridge.sh.
                const effectiveEnc  = (enc === "unknown" &&
                                       (previewState === "decoded_value" ||
                                        previewState === "decoded_without_numeric_value"))
                                      ? "no_aes"
                                      : enc;
                const aesRequired   = effectiveEnc === "encrypted" || effectiveEnc === "aes_required" || effectiveEnc === "aes";
                const previewCell   = previewVal
                  ? `<span style="font-weight:700;color:#4df08d;">${escapeHtml(previewVal)}</span>${previewUnit ? ` <span class="mono" style="color:#9eafba;font-size:11px;">${escapeHtml(previewUnit)}</span>` : ""}${previewKey ? `<div class="mono" style="font-size:10px;color:#4a6070;">${escapeHtml(previewKey)}</div>` : ""}`
                  : previewState === "decoded_without_numeric_value"
                      ? `<span style="font-size:11px;color:#9eafba;">${escapeHtml(t("preview_no_value", "no value in telegram"))}</span>`
                  : previewState === "no_decode_result"
                      ? `<span style="font-size:11px;color:#607a88;">${escapeHtml(t("preview_no_decode_result", "no decode result"))}</span>`
                  : (!aesRequired
                      ? `<span style="font-size:11px;color:#f3c84b;">${escapeHtml(t("preview_pending", "decoding…"))}</span>`
                      : `<span style="color:#4a6070;">—</span>`);
                const mfrRaw     = String(row.manufacturer || "").trim();
                const mfrCompact = compactManufacturer(mfrRaw);
                const mfrCell    = mfrCompact
                  ? `<span style="font-size:12px;color:#9eafba;" title="${escapeHtml(mfrRaw)}">${escapeHtml(mfrCompact)}</span>`
                  : `<span style="color:#4a6070;">—</span>`;
                return `
                  <tr data-value="${escapeHtml(previewVal)}">
                    <td><strong>${escapeHtml(id)}</strong></td>
                    <td>${escapeHtml(driver)}</td>
                    <td style="color:#9eafba;font-size:12px;">${escapeHtml(row.type || "-")}</td>
                    <td>${mediaIconHtml(row.type || "", driver)} ${escapeHtml(mediaLabel)}</td>
                    <td>${mfrCell}</td>
                    <td>${encBadge(effectiveEnc, note)}</td>
                    <td>${previewCell}</td>
                    <td>${fmtTime(row.last_seen)}</td>
                    <td>${escapeHtml(String(seen15mAdj))}</td>
                    <td>${escapeHtml(String(seen60mAdj))}</td>
                    <td style="color:#607a88;font-size:12px;">${escapeHtml(fmtInterval(row.avg_interval_s))}</td>
                    ${
                      withActions
                        ? `<td><div class="actions">
                            <button class="btn primary" data-action="open-add" data-id="${escapeHtml(id)}" data-driver="${escapeHtml(driver)}">${escapeHtml(t("webui_add", "Add"))}</button>
                            <button class="btn" data-action="ignore" data-id="${escapeHtml(id)}">${escapeHtml(t("ignore", "Ignore"))}</button>
                            ${row.preview_active === "true" ? `<button class="btn" data-action="cancel-preview" data-id="${escapeHtml(id)}">${escapeHtml(t("cancel_preview", "Cancel preview"))}</button>` : ""}
                          </div></td>`
                        : ""
                    }
                  </tr>
                `;
              })
              .join("")}
          </tbody>
        </table>
      </div>
    `;
  }

  function pendingMetersSection(rows, analysis) {
    const hasPreview = rows.some(row => pendingPreviewDecoded(row) || String(row.preview_value || "").trim());
    const sectionText = hasPreview
      ? t("pending_preview_confirmed", "Added to configuration — waiting for first official reading")
      : t("pending_waiting_first_official", "Waiting for first telegram");
    return `
      <div style="margin-top:20px;">
        <div class="section-head" style="margin-bottom:4px;">
          <h3 style="font-size:13px;color:#9eafba;margin:0;">
            ⏳ ${escapeHtml(t("waiting_for_telegrams_title", "Waiting for first telegram"))}
          </h3>
          <span>${rows.length}</span>
        </div>
        <p style="font-size:11px;color:#607a88;margin:0 0 10px;">${escapeHtml(sectionText)}</p>
        <div class="table-wrap">
          <table>
            <thead>
              ${pendingMeterHeader()}
            </thead>
            <tbody>
              ${rows.map(m => pendingMeterRow(m, analysis)).join("")}
            </tbody>
          </table>
        </div>
      </div>
    `;
  }

  function metersPage() {
    const data = state.data || {};
    const all = asArray(data.meters);
    const filtered = applyMediaFilter(all, "media");

    const pending = pendingMeters();

    return `
      ${pendingRestartBanner()}
      <section class="section">
        <div class="section-head">
          <h2>${escapeHtml(t("configured_meters", "Configured meters"))}</h2>
          <span>${filtered.length}${filtered.length !== all.length ? `/${all.length}` : ""} ${escapeHtml(t("webui_shown", "shown"))}</span>
        </div>
        ${filterChips()}
        ${meterTable(filtered, true)}
        ${pending.length ? pendingMetersSection(pending, data.analysis || {}) : ""}
      </section>
    `;
  }

  // Configured-meters panel on the Discover page — separate from the candidates
  // table. Shows the user's own meters with reception stats (15m/60m/interval)
  // sourced from status_meters.tsv (the DECODE-instance counters, kept live
  // by the primary wmbusmeters) AND the latest decoded value (e.g. 23.91 m³).
  // The value column lets the user identify which configured ID is which
  // physical meter by just reading the live counter.
  //
  // The "filter by value" bar on the Discover page replaces the legacy
  // SEARCH-mode workflow: instead of typing an expected value blind, the user
  // sees all live values and types a target — matching rows stay visible,
  // others hide. Filtering is pure client-side DOM (rows have data-value);
  // no re-render, no focus loss on every keystroke.
  function discoverValueFilterBar(rowCount) {
    if (!rowCount) return "";
    return `
      <section class="section">
        <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap;padding:8px 12px;background:#0e1a23;border:1px solid #1e3040;border-radius:6px;">
          <label for="discover-search-value" style="font-size:12px;color:#9eafba;">${escapeHtml(t("filter_by_value", "Filter by value"))}:</label>
          <input id="discover-search-value" type="text" inputmode="decimal" placeholder="e.g. 23.91"
            style="background:#0a1217;border:1px solid #2a4555;color:#e8f1f8;border-radius:4px;padding:5px 8px;font-size:12px;width:120px;font-family:monospace;"
            oninput="window.__discoverFilterByValue && window.__discoverFilterByValue()">
          <span style="font-size:12px;color:#607a88;">±</span>
          <input id="discover-search-tolerance" type="text" inputmode="decimal" value="0.05"
            style="background:#0a1217;border:1px solid #2a4555;color:#e8f1f8;border-radius:4px;padding:5px 8px;font-size:12px;width:70px;font-family:monospace;"
            oninput="window.__discoverFilterByValue && window.__discoverFilterByValue()">
          <button type="button" class="btn"
            style="font-size:11px;padding:4px 10px;"
            onclick="window.__discoverClearValueFilter && window.__discoverClearValueFilter();">${escapeHtml(t("filter_clear", "Clear"))}</button>
        </div>
      </section>
    `;
  }

  function discoverConfiguredPanel(rows) {
    if (!rows.length) return "";
    return `
      <section class="section">
        <div class="section-head">
          <h2>${escapeHtml(t("configured_meters_panel_title", "Configured meters on air"))}</h2>
          <span id="discover-configured-count" data-default="${rows.length}">${rows.length}</span>
        </div>
        <p style="font-size:11px;color:#607a88;margin:0 0 10px;">${escapeHtml(t("configured_meters_panel_sub", "These IDs are already in your options.json. The parallel listen instance keeps their reception stats live."))}</p>
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>${escapeHtml(t("webui_id", "ID"))}</th>
                <th>${escapeHtml(t("webui_name", "Name"))}</th>
                <th>${escapeHtml(t("driver", "Driver"))}</th>
                <th>${escapeHtml(t("manufacturer_col", "Manufacturer"))}</th>
                <th>${escapeHtml(t("media", "Medium"))}</th>
                <th>${escapeHtml(t("value_label", "Value"))}</th>
                <th>${escapeHtml(t("webui_last_seen", "Last seen"))}</th>
                <th>15m</th>
                <th>60m</th>
                <th>${escapeHtml(t("reception", "Interval"))}</th>
                <th></th>
              </tr>
            </thead>
            <tbody id="discover-configured-tbody">
              ${rows.map(row => {
                const id           = row.id || "";
                const lastSeenDate = row.last_seen ? new Date(row.last_seen) : null;
                const ageS         = (lastSeenDate && !isNaN(lastSeenDate))
                  ? (Date.now() - lastSeenDate.getTime()) / 1000
                  : Infinity;
                const seen15mAdj = ageS > 15 * 60 ? 0 : Number(row.seen_15m || 0);
                const seen60mAdj = ageS > 60 * 60 ? 0 : Number(row.seen_60m || 0);
                const {icon: mIcon, mc} = mediaIcon(row.media || "", row.driver || "");
                const mediaLabel = t(`media_${mc}`, mc);
                const valueStr   = (row.value && row.value !== "-") ? row.value : "—";
                // data-value carries the parsed numeric value for the filter.
                // Non-numeric ("—") becomes empty so the row is hidden when
                // any filter is active (no value to compare against).
                const numericVal = parseFloat(valueStr);
                const dataVal    = Number.isFinite(numericVal) ? String(numericVal) : "";
                const mfrRaw     = String(row.manufacturer || "").trim();
                const mfrCompact = compactManufacturer(mfrRaw);
                const mfrCell    = mfrCompact
                  ? `<span style="font-size:12px;color:#9eafba;" title="${escapeHtml(mfrRaw)}">${escapeHtml(mfrCompact)}</span>`
                  : `<span style="color:#4a6070;">—</span>`;
                return `
                  <tr data-value="${escapeHtml(dataVal)}">
                    <td><strong>${escapeHtml(id)}</strong></td>
                    <td><span style="margin-right:5px;font-size:15px;vertical-align:middle;">${mIcon}</span>${escapeHtml(row.name || id || "-")}</td>
                    <td>${escapeHtml(row.driver || "-")}</td>
                    <td>${mfrCell}</td>
                    <td>${escapeHtml(mediaLabel)}</td>
                    <td>
                      ${meterValueCell(row)}
                    </td>
                    <td>${fmtTime(row.last_seen)}</td>
                    <td>${escapeHtml(String(seen15mAdj))}</td>
                    <td>${escapeHtml(String(seen60mAdj))}</td>
                    <td style="color:#607a88;font-size:12px;">${escapeHtml(fmtInterval(row.avg_interval_s))}</td>
                    <td><div class="actions">
                      ${row.preview_active === "true" ? `<button class="btn" data-action="cancel-preview" data-id="${escapeHtml(id)}">${escapeHtml(t("cancel_preview", "Cancel preview"))}</button>` : ""}
                      <button class="btn danger" data-action="remove-meter" data-id="${escapeHtml(id)}">${escapeHtml(t("remove_from_config", "Remove from config"))}</button>
                    </div></td>
                  </tr>`;
              }).join("")}
            </tbody>
          </table>
        </div>
      </section>
    `;
  }

  // Live value filter for the Discover page tables.
  // Exposed on window so inline `oninput=` handlers in the rendered HTML
  // can call it without going through the IIFE closure. Operates on DOM
  // directly (display:none on non-matching rows) — no re-render, no focus
  // loss on every keystroke.
  window.__discoverFilterByValue = function () {
    const valInp = document.getElementById("discover-search-value");
    const tolInp = document.getElementById("discover-search-tolerance");
    const tables = [
      {tbody: document.getElementById("discover-configured-tbody"), count: document.getElementById("discover-configured-count"), suffix: ""},
      {tbody: document.getElementById("discover-candidates-tbody"), count: document.getElementById("discover-candidate-count"), suffix: ` ${t("webui_visible", "visible")}`},
    ].filter(x => x.tbody);

    const searchStr = ((valInp && valInp.value) || "").trim();
    const searchVal = parseFloat(searchStr.replace(",", "."));
    const tolerance = parseFloat(((tolInp && tolInp.value) || "0.05").replace(",", ".")) || 0.05;
    const active = searchStr !== "" && Number.isFinite(searchVal);

    tables.forEach(({tbody, count, suffix}) => {
      const trs = Array.from(tbody.querySelectorAll("tr"));
      const total = trs.length;
      if (!active) {
        trs.forEach(r => { r.style.display = ""; });
        if (count) count.textContent = count.dataset.default || `${total}${suffix}`;
        return;
      }

      let matched = 0;
      trs.forEach(r => {
        const rowVal = parseFloat(r.dataset.value);
        const match  = Number.isFinite(rowVal) && Math.abs(rowVal - searchVal) <= tolerance;
        r.style.display = match ? "" : "none";
        if (match) matched++;
      });
      if (count) count.textContent = `${matched} / ${total}${suffix}`;
    });
  };

  window.__discoverClearValueFilter = function () {
    const valInp = document.getElementById("discover-search-value");
    if (valInp) valInp.value = "";
    window.__discoverFilterByValue && window.__discoverFilterByValue();
  };

  function discoverPage() {
    const data = state.data || {};
    const allCandidates = asArray(data.candidates);
    const filteredCandidates = applyMediaFilter(allCandidates, "type");
    const allMeters = asArray(data.meters);
    const filteredMeters = applyMediaFilter(allMeters, "media");
    const pending = pendingMeters();
    const candidateCountLabel = `${filteredCandidates.length}${filteredCandidates.length !== allCandidates.length ? `/${allCandidates.length}` : ""} ${t("webui_visible", "visible")}`;
    return `
      ${discoverValueFilterBar(filteredMeters.length + filteredCandidates.length)}
      ${discoverConfiguredPanel(filteredMeters)}
      ${pending.length ? pendingMetersSection(pending, data.analysis || {}) : ""}
      <section class="section">
        <div class="section-head">
          <h2>${escapeHtml(t("detected_candidates", "Detected candidates"))}</h2>
          <span id="discover-candidate-count" data-default="${escapeHtml(candidateCountLabel)}">${escapeHtml(candidateCountLabel)}</span>
        </div>
        ${filterChips()}
        ${candidateTable(filteredCandidates, true)}
      </section>
      <section class="section">
        <div class="section-head">
          <h2>${escapeHtml(t("ignored", "Ignored"))}</h2>
          <span>${asArray(data.ignored).length} ${escapeHtml(t("webui_id", "ID"))}</span>
        </div>
        ${ignoredList(asArray(data.ignored))}
      </section>
    `;
  }

  function ignoredList(rows) {
    if (!rows.length) return `<div class="empty">${escapeHtml(t("webui_no_ignored", "No ignored candidates."))}</div>`;
    return `
      <div class="table-wrap">
        <table>
          <thead><tr><th>${escapeHtml(t("webui_id", "ID"))}</th><th></th></tr></thead>
          <tbody>
            ${rows
              .map(
                (id) => `
                  <tr>
                    <td><strong>${escapeHtml(id)}</strong></td>
                    <td><button class="btn" data-action="unignore" data-id="${escapeHtml(id)}">${escapeHtml(t("restore", "Restore"))}</button></td>
                  </tr>
                `,
              )
              .join("")}
          </tbody>
        </table>
      </div>
    `;
  }

  function searchPage() {
    const data = state.data || {};
    const cfg = data.search_config || {};
    const status = data.search_status || {};
    const active = !!cfg.search_mode || ["collecting", "search", "matched"].includes(String(status.phase || ""));
    return `
      <section class="section search-card card">
        <div class="section-head">
          <h2>${escapeHtml(t("search_config", "Search mode"))}</h2>
          ${active ? `<span class="pill warn"><span class="dot"></span>${escapeHtml(t("active", "Active"))}</span>` : `<span class="pill muted">${escapeHtml(t("webui_idle", "Idle"))}</span>`}
        </div>
        <form id="search-form" class="form-grid">
          <div class="field">
            <label for="expected">${escapeHtml(t("expected_label", "Expected m3"))}</label>
            <input id="expected" name="expected" inputmode="decimal" value="${escapeHtml(cfg.search_expected_value_m3 || "0")}">
          </div>
          <div class="field">
            <label for="tolerance">${escapeHtml(t("tolerance_m3_label", "Tolerance m3"))}</label>
            <input id="tolerance" name="tolerance" inputmode="decimal" value="${escapeHtml(cfg.search_tolerance_m3 || "0.05")}">
          </div>
          <div class="field">
            <label>&nbsp;</label>
            <div class="actions">
              <button class="btn primary" type="submit" name="action" value="start">${escapeHtml(t("webui_start", "Start"))}</button>
              <button class="btn" type="submit" name="action" value="stop">${escapeHtml(t("webui_stop", "Stop"))}</button>
            </div>
          </div>
        </form>
      </section>
      <section class="section grid two">
        <div>
          <div class="section-head"><h2>${escapeHtml(t("webui_search_cache", "Search cache"))}</h2><span>${asArray(data.search_candidates).length} ${escapeHtml(t("webui_rows", "rows"))}</span></div>
          ${simpleRows(asArray(data.search_candidates), ["id", "driver", "type"])}
        </div>
        <div>
          <div class="section-head"><h2>${escapeHtml(t("webui_matches", "Matches"))}</h2><span>${asArray(data.search_matches).length} ${escapeHtml(t("webui_rows", "rows"))}</span></div>
          ${simpleRows(asArray(data.search_matches), ["id", "driver", "value_m3", "diff_m3"])}
        </div>
      </section>
    `;
  }

  // ── ESP event table ───────────────────────────────────────────────────────
  const ESP_COLORS = {
    summary:            "#00bcd4",
    summary_15min:      "#0097a7",
    summary_60min:      "#006064",
    dropped:            "#f44336",
    truncated:          "#ff9800",
    rx_path:            "#9c27b0",
    suggestion:         "#ff5722",
    boot:               "#4caf50",
    busy_ether_changed: "#795548",
    meter_snapshot:     "#009688",
    meter_window:       "#3f51b5",
  };
  const ESP_ICONS = {
    summary:            "📊",
    summary_15min:      "📊",
    summary_60min:      "📊",
    dropped:            "✗",
    truncated:          "⚠",
    rx_path:            "📡",
    suggestion:         "💡",
    boot:               "🔄",
    busy_ether_changed: "📶",
    meter_snapshot:     "📸",
    meter_window:       "🪟",
  };
  const ESP_KEY_MAP = {
    summary:            ["listen_mode","total","ok","dropped","drop_pct","avg_ok_rssi","hint_en"],
    summary_15min:      ["listen_mode","total","ok","dropped","drop_pct","avg_ok_rssi","hint_en"],
    summary_60min:      ["listen_mode","total","ok","dropped","drop_pct","avg_ok_rssi","hint_en"],
    dropped:            ["stage","reason","detail","mode"],
    truncated:          ["stage","reason","detail","mode"],
    rx_path:            ["stage","mode","rssi"],
    suggestion:         ["chip","code","yaml_key","suggested_value"],
    boot:               ["radio","listen_mode","version"],
    busy_ether_changed: ["chip","state","drop_pct"],
    meter_snapshot:     ["trigger","elapsed_s"],
    meter_window:       ["trigger","id","mode","count_window","count_total","win_avg_rssi"],
  };

  function espEventSummary(payloadStr, evtype) {
    let d = {};
    try { d = JSON.parse(payloadStr || "{}"); } catch(_) { return (payloadStr || "").slice(0, 80); }
    const keys = ESP_KEY_MAP[evtype] || Object.keys(d).slice(0, 5);
    const parts = [];
    for (const k of keys) {
      const v = d[k];
      if (v !== undefined && v !== null && String(v) !== "" && String(v) !== "null") {
        parts.push(`${k}=${v}`);
      }
    }
    if (evtype === "meter_snapshot") {
      const meters = Array.isArray(d.meters) ? d.meters : [];
      if (meters.length) {
        const ids = meters.filter(m => m && m.id).map(m => m.id).join("  ");
        parts.push(`meters=${meters.length} [${ids}]`);
      }
    }
    const text = parts.join("  ");
    return text.slice(0, 140) || (payloadStr || "").slice(0, 80);
  }

  function espDeviceFromTopic(topic) {
    const parts = String(topic || "").split("/");
    return parts.length >= 3 && parts[0] === "wmbus" ? parts[1] : "";
  }

  function filterEspEventsByActiveDevices(rows, activeDevices) {
    if (!(activeDevices instanceof Set) || activeDevices.size === 0) return rows;
    return rows.filter(row => activeDevices.has(espDeviceFromTopic(row.topic)));
  }

  function espEventsTable(rows, activeDevices) {
    if (!rows.length) return `<div class="empty">${escapeHtml(t("webui_no_events", "No events yet."))}</div>`;
    // activeDevices may be a Set (new caller in espLogsPage) or a single
    // string (older callers, kept for back-compat). Normalise to a Set.
    const activeSet = activeDevices instanceof Set
      ? activeDevices
      : (typeof activeDevices === "string" && activeDevices ? new Set([activeDevices]) : new Set());
    const visibleRows = filterEspEventsByActiveDevices(rows, activeSet);
    if (!visibleRows.length) {
      return `<div class="empty">${escapeHtml(t("esp_no_active_events", "No events for the active ESP yet."))}</div>`;
    }
    return `
      <div class="table-wrap">
        <table class="esp-events-tbl">
          <thead>
            <tr>
              <th style="white-space:nowrap;">${escapeHtml(t("webui_time","Time"))}</th>
              <th>${escapeHtml(t("webui_type","Type"))}</th>
              <th>${escapeHtml(t("webui_topic","Topic"))}</th>
              <th>${escapeHtml(t("webui_summary","Summary"))}</th>
            </tr>
          </thead>
          <tbody>
            ${visibleRows.map(row => {
              const evtype     = row.evtype || "unknown";
              const color      = ESP_COLORS[evtype] || "#607a88";
              const icon       = ESP_ICONS[evtype]  || "·";
              const epoch      = Number(row.epoch || 0);
              const timeStr    = epoch ? new Date(epoch * 1000).toLocaleString() : "-";
              const topic      = (row.topic || "").split("/").slice(-3).join("/");
              const rowDevice  = espDeviceFromTopic(row.topic);
              const isActive   = rowDevice && activeSet.has(rowDevice);
              const activeDot  = isActive ? `<span style="color:#00e5ff;margin-left:3px;font-size:9px;" title="active ESP">●</span>` : "";
              const summary    = espEventSummary(row.payload || "", evtype);
              return `
                <tr>
                  <td style="white-space:nowrap;color:#9eafba;font-size:11px;">${escapeHtml(timeStr)}</td>
                  <td style="white-space:nowrap;">
                    <span style="color:${color};font-weight:700;">${icon} ${escapeHtml(evtype)}</span>
                  </td>
                  <td style="color:#9eafba;font-size:11px;white-space:nowrap;">${escapeHtml(topic)}${activeDot}</td>
                  <td style="font-size:12px;word-break:break-word;max-width:420px;">${escapeHtml(summary)}</td>
                </tr>`;
            }).join("")}
          </tbody>
        </table>
      </div>
    `;
  }

  function simpleRows(rows, fields) {
    if (!rows.length) return `<div class="empty">${escapeHtml(t("webui_no_rows", "No rows."))}</div>`;
    return `
      <div class="table-wrap">
        <table>
          <thead><tr>${fields.map((field) => `<th>${escapeHtml(field)}</th>`).join("")}</tr></thead>
          <tbody>
            ${rows
              .map((row) => `<tr>${fields.map((field) => `<td>${field === "id" ? `<strong>${escapeHtml(row[field] || "-")}</strong>` : escapeHtml(row[field] || "-")}</td>`).join("")}</tr>`)
              .join("")}
          </tbody>
        </table>
      </div>
    `;
  }

  function logsPage() {
    const data = state.data || {};
    // Legend ported from old webui page_logs: explains what "RAW" and
    // "candidate" entries mean in the event stream, plus a color key
    // matching the new event-level CSS classes (ok / warn / candidate /
    // error). Helps users read the log without having to learn the
    // colour code by trial and error.
    return `
      <section class="section">
        <div class="section-head"><h2>${escapeHtml(t("webui_runtime_events", "Runtime events"))}</h2><span>${asArray(data.events).length} ${escapeHtml(t("webui_rows", "rows"))}</span></div>
        <div style="margin-bottom:12px;padding:10px 14px;border:1px dashed #2c4555;border-radius:8px;color:#9eafba;font-size:12px;display:grid;gap:6px;">
          <div><b style="color:#cbd9e1;">${escapeHtml(t("webui_legend", "Legend"))}:</b></div>
          <div>${escapeHtml(t("raw_legend", "RAW telegram received = raw HEX frame arrived from MQTT."))}</div>
          <div>${escapeHtml(t("candidate_legend", "candidate = meter detected in LISTEN/SEARCH, but not configured in meters[]."))}</div>
          <div style="display:flex;gap:14px;flex-wrap:wrap;margin-top:4px;">
            <span><span style="display:inline-block;width:8px;height:8px;background:#2de36f;border-radius:50%;margin-right:5px;"></span>ok</span>
            <span><span style="display:inline-block;width:8px;height:8px;background:#f3c84b;border-radius:50%;margin-right:5px;"></span>warn / candidate</span>
            <span><span style="display:inline-block;width:8px;height:8px;background:#ff646b;border-radius:50%;margin-right:5px;"></span>error</span>
          </div>
        </div>
        ${eventsList(asArray(data.events))}
      </section>
    `;
  }

  function espLogsPage() {
    const data = state.data || {};
    const esp = data.esp || {};
    const suggestion = esp.suggestion || {};
    const events = asArray(esp.events);

    // Use the backend's single source of truth for ESP activity. It is based
    // on wmbus/+/telegram freshness; diag/summary and other diag events remain
    // log-only context and do not keep a device active.
    const devices = asArray(esp.devices);
    const activeDevices = new Set(
      devices
        .filter(d => d && d.active && d.name)
        .map(d => d.name)
    );
    const visibleEvents = filterEspEventsByActiveDevices(events, activeDevices);

    // Badge — one pill per active device. When the list is empty we don't
    // render any badge.
    const activeDeviceBadges = devices
      .filter(d => d && d.active && d.name)
      .map(d => `<span class="pill ${d.health === "warn" ? "warn" : "ok"}" style="font-size:11px;margin-left:6px;">📡 ${escapeHtml(t("active_filter", "Active"))}: ${escapeHtml(d.name)}</span>`)
      .join("");

    // Help notice — shown only when NO active ESP has diag enabled. When
    // at least one ESP is publishing diag events the notice becomes
    // counter-productive (it says "diagnostics required" while events
    // are clearly arriving). The flag is computed in webui.py's
    // _esp_payload() based on per-device has_diag + active state.
    const anyDiagActive = !!(esp.any_diag_active);
    const helpNotice = anyDiagActive ? "" : `
      <div class="notice" style="font-size:11px;color:#9eafba;padding:10px 14px;background:#0e1a23;border:1px dashed #2c4555;border-radius:6px;margin-bottom:14px;display:flex;gap:10px;align-items:flex-start;">
        <span style="font-size:16px;flex-shrink:0;">📝</span>
        <div>
          <strong style="color:#cbd9e1;display:block;margin-bottom:3px;">${escapeHtml(t("esp_diag_required_title", "ESP diagnostics required"))}</strong>
          <div>${escapeHtml(t("esp_diag_required_text", "These events only appear when diagnostic publishing is enabled in your ESP firmware (ESPHome config). If the table is empty even though telegrams arrive, check the ESP's YAML for the diag/* topics."))}</div>
          <div style="margin-top:4px;color:#7a8a96;">${escapeHtml(t("esp_diag_retained_hint", "ESP activity is detected from wmbus/+/telegram, with wmbus/+/diag/summary as an optional heartbeat. Other retained diag events are log-only."))}</div>
        </div>
      </div>`;

    return `
      <section class="section">
        <div class="section-head">
          <h2>${escapeHtml(t("webui_esp_events", "ESP events"))}</h2>
          <span>${visibleEvents.length} ${escapeHtml(t("webui_rows", "rows"))}${activeDeviceBadges}</span>
        </div>
        ${helpNotice}
        ${espEventsTable(events, activeDevices)}
      </section>
      <section class="section">
        <div class="section-head"><h2>${escapeHtml(t("webui_suggestion", "Suggestion"))}</h2></div>
        ${Object.keys(suggestion).length ? objectKv(suggestion) : `<div class="empty">${escapeHtml(t("webui_no_suggestion", "No tuning suggestion."))}</div>`}
      </section>
    `;
  }

  function objectKv(obj) {
    const entries = Object.entries(obj || {}).slice(0, 24);
    if (!entries.length) return `<div class="empty">No data.</div>`;
    return `
      <div class="kv">
        ${entries.map(([key, value]) => `<div>${escapeHtml(key)}</div><div>${escapeHtml(typeof value === "object" ? JSON.stringify(value) : value)}</div>`).join("")}
      </div>
    `;
  }

  // Port of old webui event_level_for_ui(): convert raw event level+message into
  // a UI-friendly (cssClass, label, displayMessage). "Detected unconfigured meter"
  // warnings are re-classified as "candidate" events and the message is rewritten
  // so users see them as informational candidate hits rather than warnings.
  function eventLevelForUi(level, message) {
    const lvl = String(level || "").toLowerCase();
    const msg = String(message || "");
    if (lvl === "warn" && msg.indexOf("Detected unconfigured meter") !== -1) {
      const label   = t("candidate_detected_label", "Candidate detected");
      const display = msg.replace("Detected unconfigured meter", label);
      return {cssClass: "candidate", label: label, message: display};
    }
    return {cssClass: lvl, label: lvl || "info", message: msg};
  }

  function eventsList(rows) {
    if (!rows.length) return `<div class="empty">${escapeHtml(t("webui_no_events", "No events yet."))}</div>`;
    return `
      <div class="event-list">
        ${rows
          .map((row) => {
            const ui = eventLevelForUi(row.level, row.message);
            return `
              <div class="event-row">
                <div>${fmtTime(row.time)}</div>
                <div class="event-level ${escapeHtml(ui.cssClass)}">${escapeHtml(ui.label)}</div>
                <div>${escapeHtml(ui.message)}</div>
              </div>
            `;
          })
          .join("")}
      </div>
    `;
  }

  function settingsPage() {
    const data = state.data || {};
    const model = data.model || {};
    const cfg = model.cfg || {};
    const mqtt = model.mqtt || {};
    const meta = data.meta || {};
    return `
      <section class="section grid two">
        <div>
          <div class="section-head"><h2>${escapeHtml(t("webui_runtime", "Runtime"))}</h2></div>
          <div class="kv">
            <div>Mode</div><div>${escapeHtml(meta.runtime || "-")}</div>
            <div>${escapeHtml(t("webui_base_path", "Base path"))}</div><div class="mono">${escapeHtml(meta.base || "-")}</div>
            <div>${escapeHtml(t("webui_raw_topic", "Raw topic"))}</div><div class="mono">${escapeHtml(cfg.raw_topic || "-")}</div>
            <div>State prefix</div><div class="mono">${escapeHtml(cfg.state_prefix || "-")}</div>
            <div>Discovery prefix</div><div class="mono">${escapeHtml(cfg.discovery_prefix || "-")}</div>
            <div>${escapeHtml(t("webui_search_mode", "Search mode"))}</div><div>${escapeHtml(String(cfg.search_mode ?? false))}</div>
          </div>
        </div>
        <div>
          <div class="section-head"><h2>MQTT</h2></div>
          <div class="kv">
            <div>Connected</div><div>${escapeHtml(String(!!model.mqtt_ok))}</div>
            <div>Host</div><div class="mono">${escapeHtml(mqtt.host || "-")}</div>
            <div>Port</div><div class="mono">${escapeHtml(mqtt.port || "-")}</div>
            <div>Mode</div><div>${escapeHtml(cfg.mqtt_mode || "-")}</div>
          </div>
        </div>
      </section>
      <section class="section">
        <div class="section-head"><h2>${escapeHtml(t("webui_options_snapshot", "Options snapshot"))}</h2></div>
        <div class="code">${escapeHtml(JSON.stringify(data.options || {}, null, 2))}</div>
      </section>
    `;
  }

  function aboutPage() {
    const data = state.data || {};
    const meta = data.meta || {};
    return `
      <section class="section grid two">
        <div class="card metric">
          <span class="label">Version</span>
          <span class="value">${escapeHtml(meta.version || "dev")}</span>
          <span class="sub">${escapeHtml(meta.runtime || "-")}</span>
        </div>
        <div class="card metric">
          <span class="label">${escapeHtml(t("webui_data_path", "Data path"))}</span>
          <span class="value" style="font-size:18px">${escapeHtml(meta.base || "-")}</span>
          <span class="sub">Runtime files used by the dashboard</span>
        </div>
      </section>
      <section class="section">
        <div class="section-head"><h2>${escapeHtml(t("webui_pipeline", "Pipeline"))}</h2></div>
        <div class="code">ESP32 / Gateway / Bridge
-> MQTT raw HEX
-> wmbusmeters stdin:hex
-> MQTT decoded JSON
-> Home Assistant Discovery</div>
      </section>
    `;
  }

  function renderModal() {
    const modal = state.modal || {};
    // Inline AES key validation script — runs in the same window context.
    // Strips non-hex chars, validates 0 or 32 hex chars, colours input,
    // shows char counter, enables/disables submit button (#4).
    const keyValidateJs = `(function(inp){
      var v = inp.value.replace(/[^0-9A-Fa-f]/g,'').slice(0,32);
      inp.value = v;
      var cnt = document.getElementById('aes-key-count');
      var btn = document.getElementById('add-meter-submit');
      if(v.length===0){
        inp.style.borderColor='';
        cnt.textContent='';
        btn.disabled=false;
      } else if(v.length===32){
        inp.style.borderColor='#1e6b3a';
        cnt.textContent='✓ 32';
        cnt.style.color='#4df08d';
        btn.disabled=false;
      } else {
        inp.style.borderColor='#6b4a1e';
        cnt.textContent=v.length+'/32';
        cnt.style.color='#f3c84b';
        btn.disabled=true;
      }
    })(this)`;
    return `
      <div class="modal-backdrop">
        <div class="modal" role="dialog" aria-modal="true" aria-labelledby="add-meter-title">
          <div class="modal-head">
            <h2 id="add-meter-title">${escapeHtml(t("webui_add_meter", "Add meter"))}</h2>
          </div>
          <form id="add-meter-form">
            <div class="modal-body">
              <div class="form-grid" style="grid-template-columns:1fr">
                <div class="field">
                  <label for="meter-id">${escapeHtml(t("meter_id", "Meter ID"))}</label>
                  <input id="meter-id" name="meter_id" value="${escapeHtml(modal.id || "")}" required pattern="(?:0[xX])?[0-9A-Fa-f\\s]{8,}">
                </div>
                <div class="field">
                  <label for="meter-name">${escapeHtml(t("webui_meter_name", "Name"))}</label>
                  <input id="meter-name" name="meter_name" value="${escapeHtml(modal.name || "")}">
                </div>
                <div class="field">
                  <label for="meter-driver">${escapeHtml(t("driver", "Driver"))}</label>
                  <input id="meter-driver" name="driver" value="${escapeHtml(modal.driver || "auto")}">
                </div>
                <div class="field">
                  <label for="meter-key">
                    ${escapeHtml(t("webui_aes_key", "AES key"))}
                    <span style="font-size:10px;color:#607a88;font-weight:400;margin-left:6px;">${escapeHtml(t("key_hint_short", "32 hex chars, or leave empty"))}</span>
                  </label>
                  <div style="display:flex;gap:8px;align-items:center;">
                    <input id="meter-key" name="key" autocomplete="off" value="" maxlength="32"
                      style="font-family:monospace;flex:1;"
                      placeholder="${escapeHtml(t("key_input_placeholder", "e.g. 00112233445566778899AABBCCDDEEFF"))}"
                      oninput="${escapeHtml(keyValidateJs)}">
                    <span id="aes-key-count" style="font-size:11px;font-weight:700;min-width:40px;text-align:right;"></span>
                  </div>
                  <div style="font-size:10px;color:#4a6070;margin-top:3px;">${escapeHtml(t("no_aes_key_note", 'key: "" = no key'))} · zero-key: <span class="mono">0000…0000</span></div>
                </div>
              </div>
            </div>
            <div class="modal-actions">
              <button class="btn" type="button" data-action="close-modal">${escapeHtml(t("webui_cancel", "Cancel"))}</button>
              <button id="add-meter-submit" class="btn primary" type="submit">${escapeHtml(t("webui_add", "Add"))}</button>
            </div>
          </form>
        </div>
      </div>
    `;
  }

  function renderRoute() {
    if (state.loading && !state.data) {
      return `
        <div class="boot">
          <div class="boot-mark"></div>
          <div><strong>wMBus MQTT Bridge</strong><span>${escapeHtml(t("webui_loading", "Loading dashboard..."))}</span></div>
        </div>
      `;
    }
    switch (state.route) {
      case "meters":
        return shell(metersPage());
      case "discover":
        return shell(discoverPage());
      case "search":
        return shell(searchPage());
      case "logs":
        return shell(logsPage());
      case "esp-logs":
        return shell(espLogsPage());
      case "settings":
        return shell(settingsPage());
      case "about":
        return shell(aboutPage());
      default:
        return shell(dashboard());
    }
  }

  function render() {
    const newHtml = renderRoute();
    if (typeof morphdom !== "undefined") {
      // morphdom patches only the DOM nodes that actually changed —
      // no flicker, no scroll reset, no lost input focus.
      const tmp = document.createElement("div");
      tmp.id = "app";
      tmp.innerHTML = newHtml;
      morphdom(app, tmp, {
        // Never replace the app root itself — only its children.
        onBeforeElUpdated(from, to) {
          // Skip elements the user is actively interacting with.
          if (from === document.activeElement) return false;
          // Skip identical nodes (morphdom checks attrs, this adds textContent check).
          if (from.isEqualNode(to)) return false;
          return true;
        },
      });
    } else {
      // Fallback when morphdom.min.js failed to load.
      app.innerHTML = newHtml;
    }
    if (state.route === "discover" && window.__discoverFilterByValue) {
      window.__discoverFilterByValue();
    }
  }

  document.addEventListener("click", async (event) => {
    const target = event.target.closest("[data-action]");
    if (!target) return;
    const action = target.dataset.action;

    if (action === "language") {
      const lang = target.dataset.lang || "";
      if (liveSource) {
        liveSource.close();
        liveSource = null;
      }
      if (lang) await fetchData(lang);
      return;
    }

    if (action === "media-filter") {
      state.mediaFilter = target.dataset.filter || "all";
      render();
      return;
    }

    if (action === "open-add") {
      const id     = target.dataset.id || "";
      const driver = target.dataset.driver || "auto";
      // Auto-suggest meter name based on media class + last 4 chars of ID (#3)
      const cand   = asArray((state.data || {}).candidates).find(c => c.id === id) || {};
      const mc     = mediaClass(cand.type || "", driver);
      const last4  = id.slice(-4).toUpperCase();
      const suggestedName = {
        water:       `Cold_Water_${last4}`,
        warm_water:  `Warm_Water_${last4}`,
        electricity: `Electricity_${last4}`,
        heat:        `Heat_${last4}`,
      }[mc] || (driver && driver !== "auto" ? `${driver}_${last4}` : `meter_${id}`);
      state.modal = {id, driver, name: suggestedName};
      render();
      return;
    }

    if (action === "close-modal") {
      if (event.target.classList.contains("modal-backdrop") || target.dataset.action === "close-modal") {
        state.modal = null;
        render();
      }
      return;
    }

    if (action === "remove-meter") {
      const id = target.dataset.id || "";
      if (!id || !window.confirm(t("webui_remove_confirm", "Remove meter {id}?", {id}))) return;
      try {
        await postApi("remove-meter", {meter_id: id});
        triggerSoftReload(`${t("webui_meter_removed", "Meter removed.")} ${t("reloading_pipeline", "Applying meter changes…")}`);
      } catch (error) {
        toast(error.message, true);
      }
      return;
    }

    // Dashboard view switcher — pure client-side, persisted to localStorage.
    if (action === "dashboard-view") {
      const v = target.dataset.view || "pipeline";
      if (v !== state.dashboardView) {
        state.dashboardView = v;
        saveDashboardView(v);
        // Switching view also clears any open pipeline drill-down.
        state.workspace = null;
        render();
      }
      return;
    }

    // Pipeline node click → open drill-down workspace.
    if (action === "open-workspace") {
      const ws = target.dataset.ws || null;
      state.workspace = (state.workspace === ws) ? null : ws;  // toggle off if same node clicked
      render();
      return;
    }

    if (action === "close-workspace") {
      state.workspace = null;
      render();
      return;
    }

    if (action === "ignore" || action === "unignore") {
      try {
        const result = await postApi(action, {id: target.dataset.id || ""});
        toast(result.message || t("webui_updated_ok", "Updated."));
        await fetchData(currentLang());
      } catch (error) {
        toast(error.message, true);
      }
      return;
    }

    if (action === "cancel-preview") {
      const id = target.dataset.id || "";
      if (!id) return;
      try {
        await postApi("cancel-preview", {id});
        toast(t("preview_removed", "Preview removed."));
        await fetchData(currentLang());
      } catch (error) {
        toast(error.message, true);
      }
      return;
    }

    if (action === "restart") {
      if (!window.confirm(t("webui_restart_confirm", "Restart the Home Assistant add-on?"))) return;
      // Docker standalone has no Supervisor API, so /api/restart-bridge can only
      // return a 400 — nothing actually restarts. Surface a clear instruction
      // instead of entering the "restarting" overlay and falsely reporting success.
      const meta = (state.data || {}).meta || {};
      if (meta.runtime === "docker") {
        toast(t("restart_docker_manual", "Cannot restart from the WebUI in Docker mode — run 'docker restart <container>' on the host."), true);
        return;
      }
      // Send restart request. A 502/network error is expected — the add-on goes down.
      // Treat any response (or connection drop) as "restarting", then poll until back.
      try {
        await postApi("restart-bridge", {});
      } catch (_) {
        // 502 / network error is expected when the add-on shuts down — not a real error.
      }
      // Enter restarting state: show overlay, close SSE stream, poll for recovery.
      state.restarting = true;
      state.liveConnected = false;
      if (liveSource) { liveSource.close(); liveSource = null; }
      render();
      (async () => {
        const start = Date.now();
        const MAX_WAIT = 90_000; // 90 s timeout
        while (Date.now() - start < MAX_WAIT) {
          await new Promise(r => setTimeout(r, 3000));
          try {
            const resp = await fetch("api/status", {cache: "no-store"});
            if (resp.ok) {
              state.restarting = false;
              await fetchData(currentLang());
              toast(t("restart_done", "Add-on restarted successfully."));
              return;
            }
          } catch (_) { /* still down — keep polling */ }
        }
        // Timeout — give up and let user refresh manually.
        state.restarting = false;
        state.error = t("restart_timeout", "Add-on did not come back in 90 s — refresh the page manually.");
        render();
      })();
    }
  });

  document.addEventListener("submit", async (event) => {
    if (event.target.id === "add-meter-form") {
      event.preventDefault();
      const form = new FormData(event.target);
      const payload = Object.fromEntries(form.entries());
      payload.meter_id = normalizeMeterId(payload.meter_id);
      try {
        await postApi("add-meter", payload);
        state.modal = null;
        // Soft pipeline reload so the new meter starts decoding without
        // a full container restart. bridge.sh's watcher picks up the
        // flag within 2 s, restarts the decode pipeline (~2-3 s), and
        // the new meter is live without touching the container.
        triggerSoftReload(`${t("webui_meter_added", "Meter added.")} ${t("reloading_pipeline", "Applying meter changes…")}`);
      } catch (error) {
        toast(error.message, true);
      }
    }

    if (event.target.id === "search-form") {
      event.preventDefault();
      const submitter = event.submitter;
      const form = new FormData(event.target);
      form.set("action", submitter?.value || "start");
      try {
        const result = await postApi("search-control", Object.fromEntries(form.entries()));
        const restartText = result.restart_ok ? ` ${result.restart_message || ""}` : "";
        toast(`${result.message || "Search updated."}${restartText}`);
        await fetchData(currentLang());
      } catch (error) {
        toast(error.message, true);
      }
    }
  });

  window.addEventListener("hashchange", () => {
    state.route = currentRoute();
    render();
  });

  fetchData();
  window.setInterval(() => {
    if (!document.hidden && !state.liveConnected) fetchData(currentLang());
  }, 15000);
})();
