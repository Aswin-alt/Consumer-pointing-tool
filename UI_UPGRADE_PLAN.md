# Microz Consumer Tool — UI Upgrade & Multi-Select Plan

## 1. Current State Analysis

### Components
| Layer | File | Responsibility |
|---|---|---|
| Frontend page | [MicrozConsumerTool/MicrozConsumerChange.jsp](MicrozConsumerTool/MicrozConsumerChange.jsp) | Shell HTML, loads jQuery/Select2, hosts empty `#formData` + `#responseContainer` |
| Frontend JS | [MicrozConsumerTool/js/MicrozAjax.js](MicrozConsumerTool/js/MicrozAjax.js) | Loads form via AJAX, triggers enable action |
| Form HTML builder | [src/MicrozChangeUtil.java](src/MicrozChangeUtil.java) | Generates `<select>` dropdowns server-side |
| Servlet | [src/MicrozConsumerServlet.java](src/MicrozConsumerServlet.java) | Handles `loadAppServerIp` and `enableConsumer` actions |
| Config | [MicrozToolProperties/appserver.properties](MicrozToolProperties/appserver.properties), [MicrozToolProperties/DeskConsumer.properties](MicrozToolProperties/DeskConsumer.properties) | Source of dropdown data |
| Remote hook | [MicrozToolProperties/enableLocalIDCConsumer.sh](MicrozToolProperties/enableLocalIDCConsumer.sh) | SSH execution |

### Current UX Pain Points
1. **Visual**: Generic 2010-era styling, uppercase-heavy headings, large green button, no spacing discipline.
2. **Functional**: Only **one** consumer can be enabled per click — forces repeated submissions for bulk operations.
3. **Feedback**: Result is a flat HTML blob; no loading indicator, no per-consumer progress, no error details.
4. **Accessibility**: No labels properly associated with inputs, no keyboard focus states, no responsiveness.
5. **Structure**: Markup is embedded inside Java strings, which is hard to style and maintain.

---

## 2. Goals

1. **Aesthetic, modern UI** — card-based layout, clean typography, soft shadows, consistent spacing, accessible color contrast.
2. **Multi-select DeskConsumers** — allow a user to pick one **or many** consumer groups in a single action.
3. **Server-side multi-consumer handling** — iterate over the array of consumers and run the enable flow for each one, aggregating results.
4. **Better feedback** — per-consumer status table with success/failed badges; show loading spinner during processing.
5. **Progressive enhancement** — keep jQuery + Select2 (already present), no new heavy framework.
6. **No regressions** — existing `/MicrozConsumerChange` servlet URL, existing properties files, existing shell hook unchanged.

---

## 3. Target UI Design

### Layout
```
┌──────────────────────────────────────────────────────────┐
│                Microz Consumer Pointing Tool             │  ← centered header
│       Enable consumer groups across local app servers    │  ← subtitle
├──────────────────────────────────────────────────────────┤
│  ┌──── Card ──────────────────────────────────────────┐  │
│  │ App Server                                         │  │
│  │ [ Select app server ........................ ▼ ]  │  │  ← Select2 single
│  │                                                    │  │
│  │ Consumers                                          │  │
│  │ [ × SocialMicroz  × FeedsMicroz  + add more... ]   │  │  ← Select2 multi
│  │ Tip: You can select multiple consumers.            │  │
│  │                                                    │  │
│  │                       [ Enable Consumers ]         │  │  ← primary button
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  ┌──── Results ───────────────────────────────────────┐  │
│  │ Consumer            | Status                       │  │
│  │ SocialMicroz        | ✓ Enabled                    │  │
│  │ FeedsMicroz         | ✕ Failed — timeout           │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

### Revision (2026-04-24) — Aesthetic refinement

- **Layout**: two-column grid inside `<main class="config-grid">`. Form panel is a fixed-width card (`flex: 0 0 400px`, enlarged from 340px) pinned to the left; result panel flexes to fill the remaining space. Collapses to a single column below 720px.
- **Form panel styling**: layered white → blue-tint → lavender gradient surface, 1 px frosted white border, gradient accent rim via `::before` masked border; elevated blue/indigo drop shadow (`rgba(10,132,255,.10)` + `rgba(94,92,230,.14)`).
- **Page background**: richer multi-stop radial stack (indigo, blue, rose, violet) over a pastel linear gradient `#eef2ff → #f5e9ff → #ffe9f1`; ambient orbs deepened to blue + violet at 0.60 opacity for more vibrancy while keeping content legible.
- **Result panel**: unchanged glass treatment; continues to use the shared `.panel` style so the visual weight sits naturally next to the more colourful form panel.

### Design Tokens
| Token | Value |
|---|---|
| Primary color | `#2563eb` (blue-600) |
| Success | `#16a34a` (green-600) |
| Danger | `#dc2626` (red-600) |
| Background | `#f8fafc` (slate-50) |
| Card | `#ffffff` with `box-shadow: 0 1px 3px rgba(0,0,0,.08), 0 4px 20px rgba(0,0,0,.04)` |
| Border radius | `12px` cards, `8px` inputs, `10px` buttons |
| Font | `-apple-system, "Segoe UI", Roboto, sans-serif` |
| Type scale | `14px` body, `13px` label, `24px` h1, `15px` subtitle |
| Spacing | 4/8/12/16/24 rhythm |

### Micro-interactions
- Submit button shows spinner + "Enabling…" label while awaiting response.
- Per-row status badge animates in.
- Inline toast for overall success/failure summary at the top of the results card.

---

## 4. Functional Changes

### 4.1 Consumer multi-select
- Upgrade the consumer `<select>` to `multiple` and initialize Select2 with `multiple: true, placeholder: "Select one or more consumers"`.
- Keep `AppServerName` as single-select (one target at a time, as today).

### 4.2 Payload change
Old:
```
action=enableConsumer&AppServerName=performance&ConsumerName=IndexProducts
```
New:
```
action=enableConsumer&AppServerName=performance&ConsumerName=IndexProducts&ConsumerName=SocialMicroz
```
Servlet reads via `request.getParameterValues("ConsumerName")`.

### 4.3 Servlet behaviour
- Fetch `String[] consumers = request.getParameterValues("ConsumerName")`.
- For each consumer, run the existing fan-out loop over `appServerProp.keySet()`.
- Accumulate a per-consumer result record: `{ consumer, success, firstError, hostsTried, hostsSucceeded }`.
- Return a compact JSON payload for the UI to render the result table.

### 4.4 Response format
```json
{
  "appServer": "performance",
  "results": [
    { "consumer": "IndexProducts", "success": true,  "message": "Enabled on 2/58 hosts" },
    { "consumer": "SocialMicroz",  "success": false, "message": "Permission denied on 3 hosts" }
  ]
}
```
Rationale: HTML-only responses don't scale once the UI needs status badges and summary counts.

---

## 5. File-by-file Change List

### [MicrozConsumerTool/MicrozConsumerChange.jsp](MicrozConsumerTool/MicrozConsumerChange.jsp)
- Replace inline `<style>` block with a link to a new stylesheet `css/microz.css`.
- Replace heading + containers with semantic markup (header, main, section).
- Add favicon + viewport meta.
- Keep `#formData` and `#responseContainer` IDs to minimize JS changes.

### `MicrozConsumerTool/css/microz.css` *(new)*
- Design tokens as CSS variables.
- Card, label, Select2 overrides, button, table, badge, spinner styles.
- Responsive breakpoint at `600px`.

### [MicrozConsumerTool/js/MicrozAjax.js](MicrozConsumerTool/js/MicrozAjax.js)
- On `loadAppServerIp` success: init Select2 for `#AppServerName` (single) and `#ConsumerName` (multiple).
- `enableConsumer()` sends `ConsumerName` as array (use `$.param({...}, true)`).
- Add loading state on the submit button.
- Render JSON response into a `<table>` instead of `innerHTML = responseText`.
- Show a toast summary.

### [src/MicrozChangeUtil.java](src/MicrozChangeUtil.java)
- `loadMicrozFormData()` returns a cleaner markup:
  - Wrap inputs in labelled rows with class hooks.
  - Consumer select gets `multiple="multiple"`.
  - Replace inline button with `id="enableBtn"` and remove `onclick=` (JS will bind handler).
- Add a small helper `escapeHtml(String)` to harden against malformed property keys.

### [src/MicrozConsumerServlet.java](src/MicrozConsumerServlet.java)
- Branch `enableConsumer`:
  - Use `getParameterValues("ConsumerName")`.
  - Loop over consumers, call existing fan-out per consumer.
  - Capture process `exitCode`, aggregate success count per consumer.
  - Build JSON response (use manual string builder to avoid new deps, or org.json if present).
  - `response.setContentType("application/json; charset=utf-8")`.
- Keep the existing file-based execution log; add per-consumer section headers.

### [MicrozToolProperties/enableLocalIDCConsumer.sh](MicrozToolProperties/enableLocalIDCConsumer.sh)
- **No change required** — args `$1..$4` unchanged.

---

## 6. Backward Compatibility

| Concern | Plan |
|---|---|
| Old clients hitting `ConsumerName=single` | `getParameterValues` returns single-element array — still works. |
| JSON content type break | Only the `enableConsumer` response changes; `loadAppServerIp` stays HTML. |
| Existing properties files | Untouched. |
| Existing URL mapping in [MicrozConsumerTool/WEB-INF/web.xml](MicrozConsumerTool/WEB-INF/web.xml) | Untouched. |

---

## 7. Risks & Mitigations

1. **Large fan-out per consumer** — selecting 10 consumers × 58 hosts = 580 SSH attempts. Mitigation: show live count, keep sequential execution (existing behavior), log each line; consider parallel execution as a future enhancement.
2. **Response payload size** — aggregated results could get big. Mitigation: include per-consumer summary only, not per-host detail; full detail remains in the server log.
3. **Select2 CSS collisions** — custom button/input styling may conflict with Select2 defaults. Mitigation: scope overrides under `.microz-form`.
4. **JSON parsing failures** — if legacy browsers hit the endpoint. Mitigation: `Accept` header check; fall back to plain HTML if `application/json` not acceptable.

---

## 8. Build & Deploy Steps

1. Edit the JSP and add [MicrozConsumerTool/css/microz.css](MicrozConsumerTool/css/microz.css).
2. Edit [MicrozConsumerTool/js/MicrozAjax.js](MicrozConsumerTool/js/MicrozAjax.js).
3. Edit [src/MicrozChangeUtil.java](src/MicrozChangeUtil.java) and [src/MicrozConsumerServlet.java](src/MicrozConsumerServlet.java).
4. Compile:
   ```bash
   javac -cp /opt/homebrew/opt/tomcat@9/libexec/lib/servlet-api.jar \
         -d src src/MicrozConsumerServlet.java src/MicrozChangeUtil.java
   ```
5. Update WAR:
   ```bash
   cd /tmp/microz_build
   cp "…/src/*.class" WEB-INF/classes/
   cp "…/MicrozConsumerChange.jsp" .
   mkdir -p css && cp "…/MicrozConsumerTool/css/microz.css" css/
   cp "…/MicrozConsumerTool/js/MicrozAjax.js" js/
   zip -r "…/MicrozConsumerTool.war" .
   ```
6. Redeploy:
   ```bash
   cp …/MicrozConsumerTool.war /opt/homebrew/opt/tomcat@9/libexec/webapps/
   rm -rf /opt/homebrew/opt/tomcat@9/libexec/webapps/MicrozConsumerTool
   brew services restart tomcat@9
   ```
7. Smoke-test at http://localhost:8080/MicrozConsumerTool/MicrozConsumerChange.jsp.

---

## 9. Acceptance Criteria

- [ ] UI matches the new visual design (card, modern typography, spacing, responsive at 600px).
- [ ] `AppServerName` is a single-select, `ConsumerName` is a multi-select with chips.
- [ ] Submitting with 2+ consumers triggers one enable flow per consumer, across all hosts.
- [ ] Result table shows one row per selected consumer with a success/failed badge.
- [ ] A loading spinner shows while the request is in flight; the button is disabled during that time.
- [ ] The existing single-consumer behavior still works end-to-end.
- [ ] `/tmp/microz_logs/microz_execution.log` continues to capture per-host output.

---

## 10. Out of Scope (for this iteration)

- Parallel SSH execution.
- Replacing password-based SSH with keys.
- Auth/authorization on the servlet.
- Extracting property-file paths to a config.
- Full frontend framework (React/Vue) migration.
