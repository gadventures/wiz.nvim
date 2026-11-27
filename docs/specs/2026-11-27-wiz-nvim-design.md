# wiz.nvim — Design Spec

- **Status:** Approved design, **rev 2 (2026-11-27)**: hybrid wizcli + Wiz API
- **Owner:** Frans Neyra
- **Goal:** Bring the Wiz IDE experience (as in the Wiz VS Code extension) to Neovim/LazyVim: scan code for IaC misconfigurations, secrets, vulnerable dependencies, and container base images, and surface findings where developers work.

## Revision history

- **rev 1:** parse wizcli JSON output directly.
- **rev 2:** wizcli v1.86's terminal output has no structured, explanatory results to parse. The plugin now uses wizcli only to *run and upload* the scan, then fetches structured results (descriptions, remediation, links) from the **Wiz GraphQL API** using the scan ID. Authentication for both is via environment variables.

## 1. Requirements (refined)

| Area | Decision |
|---|---|
| Engine | **Hybrid.** `wizcli scan dir` / `wizcli scan container-image` runs the scan and uploads it to Wiz. The plugin extracts the scan ID and queries the Wiz GraphQL API for structured results. |
| Auth | Env vars only; the plugin stores nothing. `WIZ_CLIENT_ID`, `WIZ_CLIENT_SECRET` (shared by wizcli and the API), `WIZ_API_ENDPOINT` (e.g. `https://api.us17.app.wiz.io/graphql`), optional `WIZ_AUTH_URL` (default `https://auth.app.wiz.io/oauth/token`) and `WIZ_AUTH_AUDIENCE` (default `wiz-api`). |
| wizcli | v1.x (`wizcli scan …` syntax), expected on `PATH` or set with `wizcli_path`. |
| Scan types (v1) | IaC misconfigs, secrets, vulnerabilities (SCA), container base images. |
| Triggers | On save (current file, **opt-in**), on-demand commands, once on project open, git pre-commit hook helper. |
| Image scans | On demand only (`:Wiz scan image` from a Dockerfile). |
| UI | `vim.diagnostic`, picker list, details float. |
| Picker | Auto-detect: Snacks → fzf-lua → Telescope → `vim.ui.select`. |
| Extras (v1) | Severity threshold, ignore findings, lualine statusline counts, open in Wiz portal. |
| Distribution | `gadventures/wiz.nvim` (private) via a lazy.nvim spec. |
| Keymaps | `<leader>z` prefix. |
| Out of scope v1 | Disk cache (v1.1), "what Wiz Code already reports for this repo" view (v1.1, since the GitHub org is connected to Wiz Code), SAST, wizcli auto-install. |

**Why on-save is opt-in:** every wizcli scan is uploaded to the G Adventures Wiz tenant and takes a network round-trip. Scanning on every save would flood the tenant's CI/CD scan history and be slow. Users can enable it with `scan_on_save = true` (debounced).

## 2. Approach

Pure Lua, no extra Lua dependencies. External processes: `wizcli` and `curl`, both run with `vim.system` (async). One normalized findings store feeds every UI surface.

Minimum Neovim: **0.10**.

## 3. Architecture

```
lua/wiz/
  init.lua          -- setup(), public API
  config.lua        -- defaults + validation
  env.lua           -- read + validate WIZ_* env vars (never logs values)
  http.lua          -- async curl wrapper; secrets passed on stdin, never argv
  auth.lua          -- OAuth client-credentials token, cached in memory until expiry
  api.lua           -- GraphQL request, pagination, 401 → refresh once
  queries.lua       -- GraphQL query strings (verified in the discovery spike)
  cli.lua           -- run wizcli scans, cancel/timeout, extract scan ID
  parser.lua        -- API scan result → wiz.Finding[]
  scan.lua          -- orchestrator: cli → scan ID → poll API → parse → store
  store.lua         -- findings by scope, filters (ignore, min_severity), events
  diagnostics.lua   -- vim.diagnostic namespace "wiz"
  picker/           -- init.lua (auto-detect) + snacks/fzf/telescope/select
  details.lua       -- float with full finding details
  ignore.lua        -- .wiz-nvim-ignore.json load/match/add
  statusline.lua    -- lualine component
  hook.lua          -- pre-commit hook installer
  autocmds.lua, commands.lua, keymaps.lua, health.lua
plugin/wiz.lua
tests/              -- plenary/busted specs, API fixtures, fake wizcli + fake curl
```

### Normalized Finding

```lua
---@class wiz.Finding
---@field id string          -- fingerprint: rule_id|file|lnum|hash(title)
---@field type "iac"|"secret"|"vuln"|"image"
---@field severity "CRITICAL"|"HIGH"|"MEDIUM"|"LOW"|"INFO"
---@field title string
---@field rule_id string?
---@field file string        -- absolute path
---@field lnum integer       -- 0-based
---@field end_lnum integer?
---@field col integer?
---@field description string?
---@field remediation string?
---@field package string?    -- vuln: name@version
---@field fixed_version string?
---@field cve string?
---@field url string?        -- Wiz portal / advisory link
```

## 4. Data flow

1. Trigger → `scan.run({ kind = "dir"|"image", target })`.
2. `cli` runs `wizcli scan dir <path>` (or `scan container-image <image>`) with the `WIZ_*` env passed through, cwd = project root.
3. `cli` extracts the **scan ID** from wizcli's output (the results URL it prints; exact pattern confirmed in the discovery spike).
4. `scan` polls `api` for that scan until it's complete (backoff 1s → 5s, capped by `timeout_ms`).
5. `parser` maps the API result to `Finding[]`, resolving file paths relative to the scanned root.
6. `store.replace(scope, findings)` → filters → `diagnostics.refresh`, statusline redraw, `User WizScanDone`.

Concurrency: at most one project scan and one scan per file at a time; a new scan of the same scope cancels the older one.

## 5. Auth & API

- Token: `POST WIZ_AUTH_URL` with `grant_type=client_credentials&client_id=…&client_secret=…&audience=…` (form-encoded). The **body is passed to curl on stdin** (`--data @-`), so secrets never appear in the process list.
- Tokens are cached in memory with their expiry (refreshed 5 minutes early). On HTTP 401 the plugin refreshes once and retries.
- GraphQL: `POST WIZ_API_ENDPOINT` with `Authorization: Bearer <token>`, passed to curl through a config on stdin (`-K -`), never argv.
- The service account needs read scopes for scan results (exact scopes confirmed in the spike; likely the same account wizcli uses).

## 6. Commands & keymaps

| Command | Keymap | Action |
|---|---|---|
| `:Wiz scan file` | `<leader>zs` | Scan current file |
| `:Wiz scan project` | `<leader>zS` | Scan git root / cwd |
| `:Wiz scan image` | `<leader>zi` | Scan base image(s) in current Dockerfile |
| `:Wiz findings [severity]` | `<leader>zf` | Picker of all findings |
| `:Wiz details` | `<leader>zd` | Float for finding(s) under cursor |
| `:Wiz ignore` | `<leader>zx` | Ignore finding under cursor (with reason) |
| `:Wiz open` | `<leader>zo` | Open finding / scan in Wiz portal |
| `:Wiz install-hook` | — | Install git pre-commit hook |
| `:Wiz clear` | `<leader>zc` | Clear findings |
| `:checkhealth wiz` | — | Env vars set, token fetch OK, API reachable, wizcli version |

## 7. Configuration (defaults)

```lua
{
  wizcli_path = "wizcli",
  wizcli_args = {},             -- extra args for every scan, e.g. policy flags
  scan_types = { "iac", "secret", "vuln" },
  scan_on_save = false,         -- opt-in: each scan uploads to Wiz
  scan_on_open = true,
  debounce_ms = 2000,
  timeout_ms = 300000,
  poll = { initial_ms = 1000, max_ms = 5000 },
  min_severity = "LOW",
  env = {                       -- env var NAMES (not values)
    client_id = "WIZ_CLIENT_ID",
    client_secret = "WIZ_CLIENT_SECRET",
    api_endpoint = "WIZ_API_ENDPOINT",
    auth_url = "WIZ_AUTH_URL",
    audience = "WIZ_AUTH_AUDIENCE",
  },
  diagnostics = { virtual_text = true, signs = true, underline = true },
  picker = "auto",
  portal_url = "https://app.wiz.io",
  ignore_file = ".wiz-nvim-ignore.json",
  keymaps = { prefix = "<leader>z" },
}
```

## 8. Error handling & safety

- Missing env vars → one notification naming the missing variable(s), never their values.
- Token failure (401/403) → "check WIZ_CLIENT_ID/SECRET and service account scopes".
- wizcli non-zero exit **with** a scan ID → still fetch results (policy failures exit non-zero).
- No scan ID found → error with the last few lines of wizcli output, redacted.
- Poll timeout → keep previous findings, mark stale, notify.
- Never log tokens, secrets, raw API bodies, or secret snippets. Redaction helper applied to every error message.

## 9. Testing

- Unit (plenary/busted, headless): config, env validation, token caching/expiry, GraphQL error mapping, scan-ID extraction, parser (fixtures recorded in the spike, anonymized), store filters, ignore matching.
- Integration: `tests/bin/wizcli` and `tests/bin/curl` fakes on `PATH`; drive `:Wiz scan project` end to end and assert diagnostics.
- CI: GitHub Actions on Neovim stable + nightly; stylua + selene.

## 10. Open questions (answered by the discovery spike, plan Task 1)

1. Exact text/URL wizcli prints that contains the scan ID.
2. GraphQL query (and fields) that returns a CLI scan's results by ID, and its status values.
3. Whether `wizcli scan dir` accepts a single file path.
4. Required service-account scopes.
5. Portal deep-link format for a scan and for a finding/rule.
6. Native ignore support in wizcli/Wiz policies.

## 11. Roadmap

- **v1.0:** everything above.
- **v1.1:** "Repo findings" view from Wiz Code (latest default-branch findings for the current repo); disk cache.
- **Later:** code actions for dependency bumps; LazyVim extra.
