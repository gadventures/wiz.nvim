# wiz.nvim — Design Spec

- **Status:** Approved design (2026-11-27) — implementation plan pending
- **Owner:** Frans Neyra
- **Goal:** Bring the Wiz IDE experience (as in the Wiz VS Code extension) to Neovim/LazyVim: scan code for IaC misconfigurations, secrets, vulnerable dependencies, and container base images, and surface findings where developers work.

## 1. Requirements (refined)

| Area | Decision |
|---|---|
| Engine | Wrap the `wizcli` binary; parse its JSON output. No direct Wiz API calls. |
| Auth | Reuse wizcli's own login (`wizcli auth`); plugin stores no credentials. |
| wizcli install | Expected on `PATH` (or `wizcli_path`); `:checkhealth wiz` reports missing/old/unauthenticated. |
| Scan types (v1) | IaC misconfigs, secrets, vulnerabilities (SCA), container base images. |
| Triggers | On save (current file), on-demand commands, once on project open, git pre-commit hook helper. |
| Image scans | On demand only (`:Wiz scan image` from a Dockerfile). Never automatic. |
| UI | `vim.diagnostic` (works with `]d`/`[d`, Trouble), picker list, details float. |
| Picker | Auto-detect: Snacks → fzf-lua → Telescope → `vim.ui.select`. |
| Extras (v1) | Severity threshold, ignore findings, lualine statusline counts, open in Wiz portal. |
| Distribution | Standalone GitHub repo (`wiz.nvim`), installed via a lazy.nvim spec; LazyVim extra later. |
| Keymaps | `<leader>z` prefix (configurable / disableable). |
| Out of scope v1 | Disk cache of results (v1.1), SAST, auto-download of wizcli, Mason package, AI fix suggestions. |

## 2. Approach

**A — Lua-native wrapper around wizcli** (chosen). Pure Lua; async jobs via `vim.system`; one normalized findings store that feeds every UI surface. Rejected: nvim-lint/none-ls source (can't do project scans, picker, details, ignore, auth); disk cache deferred to v1.1.

Minimum Neovim: **0.10** (for `vim.system`, `vim.ui.open`, modern diagnostics API).

## 3. Architecture

```
lua/wiz/
  init.lua          -- setup(), public API
  config.lua        -- defaults + validation (vim.validate)
  cli.lua           -- locate wizcli, detect version, build argv, run async (cancel/timeout)
  parser.lua        -- wizcli JSON -> Finding[]
  store.lua         -- findings by file, scan state, change events
  diagnostics.lua   -- vim.diagnostic namespace "wiz"
  picker/init.lua   -- backend auto-detect
  picker/{snacks,fzf,telescope,select}.lua
  details.lua       -- float with full finding details
  ignore.lua        -- ignore rules (load/match/add)
  statusline.lua    -- lualine component
  hook.lua          -- pre-commit hook installer
  autocmds.lua      -- BufWritePost / VimEnter triggers
  commands.lua      -- :Wiz user command + completion
  health.lua        -- :checkhealth wiz
plugin/wiz.lua      -- lazy-load guard
tests/              -- plenary/busted specs + JSON fixtures + fake wizcli
```

### Normalized Finding

```lua
---@class wiz.Finding
---@field id string          -- stable fingerprint: rule_id|file|lnum|hash(title)
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

1. Trigger (autocmd, command, or VimEnter) → `cli.scan({ kind, path })`.
2. `cli` builds argv for the detected wizcli version, runs it with `vim.system` (cwd = project root, JSON to stdout or a temp file).
3. On exit, `parser.parse(json, kind)` → `Finding[]`. Exit codes that indicate "policy failed" but produced JSON are treated as success.
4. `store.replace(scope, findings)` — scope is a file path or the project root.
5. `store` applies `ignore` + `min_severity` filters, then notifies: `diagnostics.refresh(bufnrs)`, statusline redraw, `User WizScanDone` autocmd.

**On-save scans:** debounced (~1000 ms); an in-flight scan for the same file is cancelled; only for supported filetypes/patterns (`*.tf`, `*.tfvars`, `*.yaml/yml` (k8s/CFN/Helm), `*.json` (CFN/ARM), `Dockerfile*`, `*.bicep`, lockfiles/manifests); any file for secrets.
**Project-open scan:** once per git root per session, only if `scan_on_open = true` and wizcli is authenticated.

## 5. Commands & keymaps

| Command | Keymap | Action |
|---|---|---|
| `:Wiz scan file` | `<leader>zs` | Scan current file |
| `:Wiz scan project` | `<leader>zS` | Scan git root / cwd |
| `:Wiz scan image` | `<leader>zi` | Scan base image(s) of current Dockerfile |
| `:Wiz findings [severity]` | `<leader>zf` | Picker of all findings |
| `:Wiz details` | `<leader>zd` | Float for finding(s) under cursor |
| `:Wiz ignore` | `<leader>zx` | Ignore finding under cursor (with reason) |
| `:Wiz open` | `<leader>zo` | Open finding/policy in browser (`vim.ui.open`) |
| `:Wiz auth` | `<leader>za` | Run `wizcli auth` in a terminal split |
| `:Wiz install-hook` | — | Install git pre-commit hook |
| `:Wiz clear` | `<leader>zc` | Clear findings |
| `:checkhealth wiz` | — | Health report |

## 6. Configuration (defaults)

```lua
{
  wizcli_path = "wizcli",
  extra_args = {},              -- e.g. { "--policy", "Default IaC policy" }
  scan_types = { "iac", "secret", "vuln" },  -- "image" only via command
  scan_on_save = true,
  scan_on_open = true,
  debounce_ms = 1000,
  timeout_ms = 120000,
  min_severity = "LOW",
  diagnostics = { virtual_text = true, signs = true, underline = true },
  picker = "auto",              -- "snacks" | "fzf" | "telescope" | "select"
  portal_url = nil,             -- e.g. "https://app.wiz.io"
  ignore_file = ".wiz-nvim-ignore.json",
  keymaps = { prefix = "<leader>z" },  -- false to disable
  statusline = { icons = { CRITICAL = "", HIGH = "", MEDIUM = "", LOW = "" } },
}
```

LazyVim spec:

```lua
{
  "gadventures/wiz.nvim",
  cmd = "Wiz",
  event = { "BufReadPost", "BufWritePost" },
  opts = { min_severity = "MEDIUM" },
}
```

## 7. Ignore

- Default: project file `.wiz-nvim-ignore.json` (`[{ rule_id, path_glob, fingerprint?, reason, author, date }]`), committed to the repo so the team shares it.
- If wizcli supports native inline/file ignores (to verify), prefer those and treat the JSON file as a fallback.

## 8. Error handling & safety

- wizcli missing / unauthenticated / unsupported version → one actionable `vim.notify` per session + `:checkhealth` detail.
- Timeout → cancel job, notify, keep previous findings marked stale.
- Malformed JSON → log a parse error with the first N chars **with secret-like strings redacted**; never log raw wizcli output to `:messages` or files.
- Never write secret values into diagnostics text — use wizcli's redacted snippet or the rule title only.
- Concurrency: at most one project scan + one scan per file at a time.

## 9. Testing

- **Unit (plenary/busted, headless nvim):** parser against recorded fixtures for each scan type (use DefectDojo's public wizcli dir-scan samples as a starting point, then real anonymized output), config validation, severity filter, ignore matching, fingerprinting.
- **Integration:** `tests/bin/wizcli` fake script that emits fixtures/exit codes; tests drive `:Wiz scan` and assert diagnostics.
- **CI:** GitHub Actions matrix on Neovim stable + nightly; stylua + luacheck/selene.

## 10. Open questions (verify against the installed wizcli version)

1. Exact subcommands/flags: legacy `wizcli dir scan --path . -f json` / `wizcli iac scan` / `wizcli docker scan --image` vs newer `wizcli scan dir` / `wizcli scan container-image`. → `cli` will detect version and map accordingly.
2. Can wizcli scan a single file, or only a directory? (If dir-only: scan parent dir with file filter, or project scan + filter.)
3. JSON output schema per scan type (line numbers, rule IDs, portal links).
4. Native ignore mechanism, if any.
5. Portal deep-link URL format.
6. Whether scans upload results to Wiz by default and whether a no-publish flag exists (privacy / noise).

## 11. Roadmap

- **v1.0:** everything above.
- **v1.1:** disk cache keyed by git HEAD + file hash; LazyVim extra PR.
- **Later:** SAST if wizcli supports it; code actions for dependency bumps; Mason registry entry.
