# wiz.nvim Implementation Plan

> **For the implementer:** work through this task by task. Each task is test-first: write the failing test, watch it fail, implement, watch it pass, commit. Don't skip the "run it and see it fail" step.

**Goal:** A LazyVim-friendly Neovim plugin that runs Wiz scans with `wizcli`, fetches structured results from the Wiz GraphQL API, and shows them as diagnostics, a picker, and a details float.

**Architecture:** Pure Lua. `wizcli` runs and uploads the scan. `curl` (through `vim.system`) talks to the Wiz OAuth + GraphQL endpoints. One findings store feeds diagnostics, picker, details and statusline. See `docs/specs/2026-11-27-wiz-nvim-design.md` (rev 2).

**Tech stack:** Neovim ≥ 0.10, Lua 5.1/LuaJIT, plenary.nvim (tests only), stylua, selene, GitHub Actions.

**Conventions**
- Module paths: `lua/wiz/<name>.lua`; tests: `tests/wiz/<name>_spec.lua`.
- Run all tests: `make test`. One file: `make test FILE=tests/wiz/config_spec.lua`.
- Every module that does I/O takes its dependencies through a small injectable table (`M._deps`) so tests can stub `vim.system`, time, and env.
- Never put secrets or tokens in argv, `vim.notify`, logs, or test fixtures.
- Commit after every task: `git commit -m "<type>(<scope>): <summary>"`.

---

## Task 0: Scaffold the repo

**Files:**
- Create: `Makefile`, `stylua.toml`, `selene.toml`, `.gitignore`, `tests/minimal_init.lua`, `plugin/wiz.lua`, `lua/wiz/init.lua`, `.github/workflows/ci.yml`, `tests/wiz/smoke_spec.lua`

**Step 1: test harness**

`tests/minimal_init.lua`:
```lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local plenary = os.getenv("PLENARY_DIR") or (root .. "/.deps/plenary.nvim")
if vim.fn.isdirectory(plenary) == 0 then
  vim.fn.system({ "git", "clone", "--depth=1", "https://github.com/nvim-lua/plenary.nvim", plenary })
end
vim.opt.rtp:prepend(plenary)
vim.opt.rtp:prepend(root)
vim.cmd("runtime plugin/plenary.vim")
vim.opt.swapfile = false
```

`Makefile`:
```make
FILE ?= tests/
test:
	nvim --headless --noplugin -u tests/minimal_init.lua \
	  -c "PlenaryBustedDirectory $(FILE) {minimal_init='tests/minimal_init.lua', sequential=true}"
lint:
	stylua --check lua tests && selene lua
```

**Step 2: failing smoke test** — `tests/wiz/smoke_spec.lua`:
```lua
describe("wiz", function()
  it("loads", function()
    assert.is_table(require("wiz"))
    assert.is_function(require("wiz").setup)
  end)
end)
```
Run `make test` → FAIL (`module 'wiz' not found`).

**Step 3: minimal module** — `lua/wiz/init.lua`:
```lua
local M = {}
function M.setup(opts) M.opts = opts or {} end
return M
```
`plugin/wiz.lua`: `if vim.g.loaded_wiz then return end; vim.g.loaded_wiz = 1`

Run `make test` → PASS.

**Step 4: CI** — `.github/workflows/ci.yml`: matrix `nvim: [stable, nightly]` using `rhysd/action-setup-vim`, then `make test`; a lint job with `JohnnyMorganz/stylua-action` + selene.

**Step 5: commit** — `chore: scaffold wiz.nvim with test harness and CI`

---

## Task 1: Discovery spike (no plugin code, run on Frans's Mac)

Answers the spec's open questions before we write the API layer. **Output: `docs/notes/api-discovery.md` + anonymized fixtures.**

**Step 1: capture wizcli output**
```bash
export WIZ_CLIENT_ID=… WIZ_CLIENT_SECRET=…   # from your secret store
cd ~/projects/some-terraform-repo
wizcli scan dir --help > /tmp/wiz-help.txt
wizcli scan dir . 2>&1 | tee /tmp/wiz-scan-dir.txt
wizcli scan dir ./main.tf 2>&1 | tee /tmp/wiz-scan-file.txt   # single file?
echo "exit=$?"
```
Record: the line or URL containing the scan ID, exit codes for pass/fail, whether single-file works, any flags for policy, JSON/SARIF, or "no publish".

**Step 2: get a token and introspect the API** — `scripts/wiz-api.sh` (committed; reads env, sends the secret on stdin):
```bash
#!/usr/bin/env bash
set -euo pipefail
: "${WIZ_CLIENT_ID:?}" "${WIZ_CLIENT_SECRET:?}" "${WIZ_API_ENDPOINT:?}"
AUTH_URL="${WIZ_AUTH_URL:-https://auth.app.wiz.io/oauth/token}"
TOKEN=$(printf 'grant_type=client_credentials&audience=%s&client_id=%s&client_secret=%s' \
  "${WIZ_AUTH_AUDIENCE:-wiz-api}" "$WIZ_CLIENT_ID" "$WIZ_CLIENT_SECRET" |
  curl -sS -X POST "$AUTH_URL" -H 'Content-Type: application/x-www-form-urlencoded' --data @- |
  python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
QUERY_FILE="$1"; VARS="${2:-{}}"
python3 -c 'import json,sys;print(json.dumps({"query":open(sys.argv[1]).read(),"variables":json.loads(sys.argv[2])}))' "$QUERY_FILE" "$VARS" |
  curl -sS -X POST "$WIZ_API_ENDPOINT" -H 'Content-Type: application/json' \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN") --data @-
```
Then:
- Find query fields related to CLI/CI-CD scans: introspect `__schema { queryType { fields { name description } } }` and grep for `scan|cicd|cli`. If introspection is disabled, use the **API Explorer** in the Wiz portal (Settings → API / Tenant docs).
- Fetch the scan from Step 1 by ID. Save the response to `tests/fixtures/api/scan_dir_result.json` after anonymizing: repo names, paths, emails, IDs, and **any secret snippet**.
- Repeat for a container-image scan → `tests/fixtures/api/scan_image_result.json`.
- Record the status field and its values (e.g. running/success/failed), the pagination shape, the required service-account scopes, and the portal URL pattern for a scan and for a rule.

**Step 3: write `docs/notes/api-discovery.md`** with the confirmed query text, the scan-ID regex, field mapping → `wiz.Finding`, and status values. **Update `lua/wiz/queries.lua` (Task 6) and the parser (Task 8) from this file, not from guesses.**

**Step 4: commit** — `docs: record wizcli + Wiz API discovery results`

> **Gate:** don't start Task 6 until this is merged.

---

## Task 2: `config`

**Files:** `lua/wiz/config.lua`, `tests/wiz/config_spec.lua`

**Tests (write first):**
```lua
local config = require("wiz.config")
describe("config", function()
  before_each(function() config.setup({}) end)
  it("has defaults", function()
    assert.equals("wizcli", config.get().wizcli_path)
    assert.is_false(config.get().scan_on_save)
    assert.equals("LOW", config.get().min_severity)
  end)
  it("deep-merges user opts", function()
    config.setup({ min_severity = "HIGH", env = { client_id = "MY_ID" } })
    assert.equals("HIGH", config.get().min_severity)
    assert.equals("MY_ID", config.get().env.client_id)
    assert.equals("WIZ_CLIENT_SECRET", config.get().env.client_secret)
  end)
  it("rejects bad severity", function()
    assert.has_error(function() config.setup({ min_severity = "SPICY" }) end)
  end)
end)
```

**Implementation:** `M.defaults` = the table in spec §7; `M.setup(opts)` = `vim.tbl_deep_extend("force", {}, M.defaults, opts or {})`, then validate `min_severity ∈ SEVERITIES`, `picker ∈ {auto,snacks,fzf,telescope,select}`, and numeric timeouts. Export `M.SEVERITIES = { "INFO","LOW","MEDIUM","HIGH","CRITICAL" }` and `M.rank(sev)`.

**Commit:** `feat(config): defaults, merge and validation`

---

## Task 3: `env` + redaction

**Files:** `lua/wiz/env.lua`, `lua/wiz/redact.lua`, tests for both.

**Tests:**
- `env.read()` with stubbed `vim.env` returns `{ client_id, client_secret, api_endpoint, auth_url, audience }`, applying defaults for `auth_url` (`https://auth.app.wiz.io/oauth/token`) and `audience` (`wiz-api`).
- Missing vars → `nil, { "WIZ_CLIENT_ID", ... }` (names only).
- `api_endpoint` without `/graphql` gets it appended; a non-https endpoint is rejected.
- `redact.text(s)` masks `Bearer …`, `client_secret=…`, JWT-shaped strings, and AWS-key-shaped strings; `redact.text` is idempotent.

**Implementation sketch:**
```lua
local M = {}
M._getenv = function(name) return vim.env[name] end
function M.read(names)
  local cfg = require("wiz.config").get().env
  names = names or cfg
  local v = {}
  local missing = {}
  for key, var in pairs(names) do v[key] = M._getenv(var) end
  for _, key in ipairs({ "client_id", "client_secret", "api_endpoint" }) do
    if not v[key] or v[key] == "" then table.insert(missing, names[key]) end
  end
  if #missing > 0 then return nil, missing end
  v.auth_url = v.auth_url or "https://auth.app.wiz.io/oauth/token"
  v.audience = v.audience or "wiz-api"
  if not v.api_endpoint:match("/graphql/?$") then v.api_endpoint = v.api_endpoint:gsub("/$", "") .. "/graphql" end
  if not v.api_endpoint:match("^https://") then return nil, { names.api_endpoint .. " (must be https)" } end
  return v
end
return M
```

**Commit:** `feat(env): read WIZ_* env vars; add redaction helper`

---

## Task 4: `http` (async curl, secrets on stdin)

**Files:** `lua/wiz/http.lua`, `tests/wiz/http_spec.lua`, `tests/bin/curl` (fake)

**Tests:** stub `M._system` to capture `cmd` and `opts.stdin`:
- `http.post_form(url, fields, cb)` → argv contains no field values; `stdin` holds the url-encoded body; `--data @-` is present.
- `http.post_json(url, body, { bearer = "tok" }, cb)` → the token appears only in stdin config (`-K -`), never argv; the JSON body goes in a temp file passed via `--data-binary @<tmpfile>` that is deleted afterwards (stdin is used by `-K -`).
- Parses `-w '\n%{http_code}'` trailer → `cb(nil, { status = 200, body = decoded })`.
- Non-2xx → `cb({ status = 401, message = <redacted> })`.
- `timeout` honored via `vim.system(..., { timeout = ms })`.

**Implementation notes:**
- Use `curl -sS --fail-with-body -X POST -w '\n%{http_code}'`.
- URL-encode with a local `urlencode` (`%%%02X`) helper.
- Decode with `vim.json.decode(body, { luanil = { object = true, array = true } })`.
- Callbacks are wrapped in `vim.schedule_wrap`.

**Commit:** `feat(http): async curl wrapper with secrets via stdin`

---

## Task 5: `auth` (token cache)

**Files:** `lua/wiz/auth.lua`, `tests/wiz/auth_spec.lua`

**Tests:** stub `http.post_form` and `M._now`:
- First `auth.token(cb)` calls the token endpoint with `grant_type=client_credentials`, `client_id`, `client_secret`, `audience`.
- Second call within expiry returns the cached token without HTTP.
- Expiry minus 300s triggers a refresh.
- `auth.invalidate()` forces a refresh.
- Concurrent callers during an in-flight fetch share one request (queue callbacks).
- Missing env → `cb({ kind = "env", missing = {...} })`.

**Commit:** `feat(auth): OAuth client-credentials token with in-memory cache`

---

## Task 6: `api` + `queries` (after Task 1)

**Files:** `lua/wiz/api.lua`, `lua/wiz/queries.lua`, `tests/wiz/api_spec.lua`

**Tests:**
- `api.graphql(query, vars, cb)` posts `{query, variables}` with a bearer token from `auth`.
- GraphQL `errors` array → `cb({ kind = "graphql", messages = {...} })`.
- HTTP 401 → `auth.invalidate()` then one retry; second 401 → error `kind = "auth"`.
- `api.paginate(query, vars, path, cb)` follows `pageInfo { hasNextPage endCursor }` until done (cap 50 pages).
- `api.get_scan(id, cb)` uses `queries.SCAN_RESULT` (text from `docs/notes/api-discovery.md`) and returns `{ status, result }`.

**Commit:** `feat(api): GraphQL client with retry, pagination and scan query`

---

## Task 7: `cli` (run wizcli, extract scan ID)

**Files:** `lua/wiz/cli.lua`, `tests/wiz/cli_spec.lua`, `tests/bin/wizcli` (fake that prints `tests/fixtures/cli/*.txt` and exits with `$FAKE_EXIT`), `tests/fixtures/cli/scan_dir_pass.txt`, `scan_dir_fail.txt` (from Task 1, anonymized)

**Tests:**
- `cli.build_argv({ kind = "dir", target = "/repo" })` → `{ "wizcli", "scan", "dir", "/repo", <wizcli_args...> }`; `kind = "image"` → `{ "wizcli", "scan", "container-image", "<image>" }`.
- `cli.extract_scan_id(output)` returns the ID from both fixtures; `nil` for unrelated output.
- `cli.run(opts, cb)` passes `env` = current env (so `WIZ_CLIENT_ID/SECRET` reach wizcli) and `cwd`; it returns a handle with `:cancel()`.
- Non-zero exit **with** an ID → `cb(nil, { scan_id, exit_code })`; without an ID → `cb({ kind = "cli", tail = <last 10 lines, redacted> })`.
- `cli.version(cb)` parses `Wiz CLI v1.86.0-3ca0a46` → `"1.86.0"`.

**Commit:** `feat(cli): run wizcli scans and extract scan IDs`

---

## Task 8: `parser`

**Files:** `lua/wiz/parser.lua`, `tests/wiz/parser_spec.lua`

**Tests (fixtures from Task 1):**
- `parser.parse(api_result, { root = "/repo", kind = "dir" })` returns `wiz.Finding[]` with types `iac`, `secret` and `vuln` present in the fixture, absolute `file` paths, 0-based `lnum`, normalized `severity` (upper-case; unknown → `INFO`).
- Secret findings never contain the secret value (assert against a sentinel planted in the fixture).
- `id` is stable across two parses of the same input and differs when the line changes.
- Image results → `type = "image"`, `file` = the Dockerfile that triggered the scan, `lnum` = the `FROM` line.

**Commit:** `feat(parser): map Wiz API scan results to findings`

---

## Task 9: `store`, `ignore`, severity filter

**Files:** `lua/wiz/store.lua`, `lua/wiz/ignore.lua`, specs.

**Tests:**
- `store.replace(scope, findings)` replaces only findings under that scope (a file scan doesn't wipe other files).
- `store.list({ min_severity = "HIGH" })` filters; `store.by_file(path)`.
- `store.on_change(fn)` fires once per replace.
- `ignore.load(root)` reads `.wiz-nvim-ignore.json`; `ignore.match(finding)` matches by `fingerprint`, or by `rule_id` + `path_glob` (`vim.glob.to_lpeg`).
- `ignore.add(finding, reason)` appends an entry with `author = git config user.name` and today's date, and pretty-prints the JSON.

**Commit:** `feat(store): findings store with ignore and severity filters`

---

## Task 10: `diagnostics`

**Files:** `lua/wiz/diagnostics.lua`, spec.

**Tests:**
- Severity map: CRITICAL/HIGH → `ERROR`, MEDIUM → `WARN`, LOW → `INFO`, INFO → `HINT`.
- `diagnostics.refresh()` sets diagnostics only for loaded buffers whose name matches a findings file; `source = "wiz"`, `code = rule_id`, and `user_data.wiz_id = finding.id`.
- Message format: `"[<TYPE>] <title>"` (+ ` (<package> → <fixed_version>)` for vulns).
- A `BufReadPost` of a file with findings gets diagnostics (autocmd registered in setup).

**Commit:** `feat(diagnostics): publish findings as vim.diagnostic`

---

## Task 11: `scan` orchestrator

**Files:** `lua/wiz/scan.lua`, `tests/wiz/scan_spec.lua` (integration: fake `wizcli` + stubbed `api.get_scan`)

**Tests:**
- `scan.run({ kind = "dir", target = root })` → cli → scan ID → polls `api.get_scan` until the status is complete (fake returns running, running, done) → `store.replace` → `User WizScanDone` fires with `{ scope, count }`.
- Backoff: 1s, 2s, 4s, 5s, 5s… (fake timer via `M._defer`).
- Timeout → `vim.notify` warn once, store unchanged, `state = "stale"`.
- A second `run` on the same scope cancels the first (fake wizcli handle's `cancel` called).
- `scan.state()` → `{ running = n, last = { scope, finished_at, counts } }` for the statusline.

**Commit:** `feat(scan): orchestrate wizcli run, API polling and store update`

---

## Task 12: commands, keymaps, autocmds, `setup()`

**Files:** `lua/wiz/commands.lua`, `lua/wiz/keymaps.lua`, `lua/wiz/autocmds.lua`, update `lua/wiz/init.lua`, specs.

**Tests:**
- `:Wiz` subcommand completion lists `scan findings details ignore open install-hook clear`, and `scan` completes `file project image`.
- `setup({ keymaps = false })` creates no `<leader>z` maps; the default creates the maps from spec §6, each with a `desc` (so which-key shows them).
- `scan_on_save = true` → `BufWritePost` debounced by `debounce_ms` (fake timer); `false` → no autocmd.
- `scan_on_open = true` → one project scan per git root per session (`VimEnter` + `DirChanged`).
- `:Wiz scan image` in a non-Dockerfile → error notification; in a Dockerfile it parses `FROM` lines (ignoring `--platform`, stage aliases, and `scratch`) and scans each image.

**Commit:** `feat: user commands, keymaps and scan triggers`

---

## Task 13: picker

**Files:** `lua/wiz/picker/{init,snacks,fzf,telescope,select}.lua`, spec for `init` + `select`.

**Tests:**
- `picker.backend()` picks the first available of snacks → fzf-lua → telescope → select (stub `pcall(require, …)`); `config.picker` overrides.
- Each entry shows `SEVERITY  type  relpath:line  title`; confirming opens the file at the line.
- `:Wiz findings HIGH` pre-filters.
- Snacks/fzf/telescope adapters: manual check (documented in the PR) + a smoke test that the module loads when its dependency is stubbed.

**Commit:** `feat(picker): findings picker with backend auto-detect`

---

## Task 14: details float + open in portal

**Files:** `lua/wiz/details.lua`, spec.

**Tests:**
- `details.render(finding)` returns markdown lines: title, severity/type/rule, file:line, description, remediation, and vuln package/fixed version/CVE.
- `:Wiz details` with no finding under the cursor → info notification; with several → all are shown, separated by `---`.
- `:Wiz open` builds the URL from `portal_url` + the pattern in `api-discovery.md` and calls `vim.ui.open` (stubbed).
- The float uses `vim.lsp.util.open_floating_preview` with `filetype = "markdown"` and closes on cursor move.

**Commit:** `feat(details): finding details float and open-in-portal`

---

## Task 15: statusline

**Files:** `lua/wiz/statusline.lua`, spec.

**Tests:** `statusline.component()` returns `""` with no findings; `"󰂃 2 1"` style counts per severity ≥ `min_severity`; a spinner glyph while `scan.state().running > 0`; `statusline.lualine()` returns `{ fn, cond, color }` for lualine.

Document the LazyVim snippet in the README:
```lua
{ "nvim-lualine/lualine.nvim", opts = function(_, opts)
  table.insert(opts.sections.lualine_x, 1, require("wiz.statusline").lualine())
end }
```

**Commit:** `feat(statusline): lualine component with finding counts`

---

## Task 16: pre-commit hook

**Files:** `lua/wiz/hook.lua`, spec.

**Tests (temp git repo):**
- `:Wiz install-hook` writes `.git/hooks/pre-commit` (executable) that runs `wizcli scan dir --` on the **staged files only** and blocks the commit on failure.
- An existing hook isn't overwritten: the user is asked, and `pre-commit.wiz-backup` is written first.
- If the repo uses `core.hooksPath`, the hook is written there.

**Commit:** `feat(hook): install git pre-commit hook running wizcli`

---

## Task 17: health

**Files:** `lua/wiz/health.lua`, spec.

**Checks:** Neovim ≥ 0.10; `curl` on PATH; `wizcli` on PATH and version ≥ 1.0 (`wizcli version`); each `WIZ_*` var set (report **names only**); token fetch OK (no token printed); a minimal API query succeeds; picker backend detected; `ignore_file` parses.

**Commit:** `feat(health): :checkhealth wiz`

---

## Task 18: docs + install in Frans's config

**Files:** `README.md`, `doc/wiz.txt` (vimdoc), `CHANGELOG.md`; on the Mac: `~/.config/nvim/lua/plugins/wiz.lua`.

`~/.config/nvim/lua/plugins/wiz.lua` while developing:
```lua
return {
  "gadventures/wiz.nvim",
  dir = "~/projects/wiz.nvim",   -- local clone; remove once released
  cmd = "Wiz",
  event = { "BufReadPost", "BufWritePost" },
  opts = { min_severity = "MEDIUM" },
}
```
Released version: replace `dir` with `url = "git@github.com:gadventures/wiz.nvim.git"`.

Env vars: export them from a secret manager in `~/.zshrc` (e.g. `export WIZ_CLIENT_SECRET="$(op read op://…)"`), **not** in the nvim config.

**Manual acceptance checklist (record results in the PR):**
1. `:checkhealth wiz` is all OK.
2. `:Wiz scan project` on a Terraform repo → diagnostics appear and `]d` jumps between them.
3. `<leader>zf` lists findings; Enter jumps to the line.
4. `<leader>zd` shows description and remediation.
5. `<leader>zx` adds an entry to `.wiz-nvim-ignore.json` and the diagnostic disappears.
6. `:Wiz scan image` on a Dockerfile shows base-image CVEs on the `FROM` line.
7. Unset `WIZ_CLIENT_SECRET` → one clear notification naming the variable.
8. `:messages` and `~/.local/state/nvim/` contain no tokens or secrets.

**Commit:** `docs: README, vimdoc and install instructions`

---

## Order & estimates

| # | Task | Depends on | Est. |
|---|---|---|---|
| 0 | Scaffold | — | 0.5h |
| 1 | Discovery spike | 0 | 1–2h (needs Mac + creds) |
| 2–5 | config, env, http, auth | 0 | 3h |
| 6 | api + queries | 1, 5 | 1.5h |
| 7 | cli | 1 | 1.5h |
| 8 | parser | 1 | 2h |
| 9–10 | store/ignore, diagnostics | 8 | 2h |
| 11 | scan orchestrator | 6, 7, 9 | 2h |
| 12 | commands/keymaps/autocmds | 11 | 2h |
| 13–17 | picker, details, statusline, hook, health | 12 | 4–5h |
| 18 | docs + install | all | 1h |

Tasks 2–5 can run in parallel with Task 1.
