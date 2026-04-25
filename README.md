# maestro-workflow

> 多模型協作的軟體工程 workflow plugin（for Claude Code）

讓不同階段使用不同 AI 模型發揮各自所長：Opus 規劃、Gemini + Codex + Opus 並行審議、Sonnet 實作、再用 MAGI 加權投票收斂結果。

## 現在進度

✅ **Phase A + B + C + D 完成**：orchestrator 底層 + 6 個核心 slash command + 4 個 web 領域 skill + 2 個 subagent。完整路線見 [`SPEC.md`](SPEC.md)。

目前已可用：

**核心**
- 多 CLI 並行 fan-out（claude / gemini / codex），事件流協定、quota / auth 自動降級
- MAGI 加權投票 4 種模式（majority / supermajority / unanimous / threshold）
- 6 個核心 slash command：`/maestro.setup`、`/maestro.plan`、`/maestro.tasks`、`/maestro.xreview-plan`、`/maestro.work`、`/maestro.review`
- 2 個 subagent：`maestro-developer`（Sonnet, TDD 實作）、`maestro-reviewer`（Opus, 唯讀審查）
- nvm 相容（避開 `#!/usr/bin/env node` 找錯版本的坑）

**Web 領域 add-ons（Phase D）**
- `/maestro.web.frontend.spec` — 元件樹、a11y checklist、Playwright e2e 計畫
- `/maestro.web.backend.spec` — OpenAPI / SDL 契約、migration、authz 矩陣、contract test
- `/maestro.web.infra.plan` — Terraform plan dry-run、IAM diff、Infracost、rollback
- `/maestro.web.ci.spec` — pipeline 階段、secrets handling、deployment 策略、smoke

**Override flags**
- `--model` / `--magi` / `--reviewers` / `--single` / `--parallel` / `--diff` / `--workdir` / `--milestone` / `--task` / `--reset` / `--recheck`

尚未可用：
- 團隊化 hooks 與 canonical AGENTS.md（Phase E）

## 安裝

### 作為 Claude Code plugin（推薦）

```bash
claude plugin add github:howar31/maestro-workflow
```

安裝後第一件事跑 setup wizard：

```
/maestro.setup
```

它會檢查你機器上的 `claude` / `gemini` / `codex`、詢問你想啟用哪幾位 reviewer 與權重、寫入 `~/.config/maestro-workflow/config.json`，最後跑一次 dry-run 驗證。

### 作為本機開發 / 直接跑 shell scripts

```bash
git clone https://github.com/howar31/maestro-workflow.git /opt/projects/maestro-workflow
cd /opt/projects/maestro-workflow
./scripts/shared/preflight.sh        # 健檢
./test/e2e-smoke.sh                  # 真 CLI 端到端
./test/e2e-fallback.sh               # mock adapter，免 token
```

## 使用流程

### 通用流程

```
/maestro.setup                        # 第一次先跑這個
/maestro.plan "<功能描述>"            # 產出 docs/<num>-<slug>/PLAN.md
/maestro.xreview-plan                 # 多 CLI MAGI 審 plan
/maestro.tasks                        # 拆 TASKS.md
/maestro.work                         # 派工 maestro-developer 實作
/maestro.review                       # 多 CLI MAGI 審 code（--single 退化單審）
                                      # 確認沒問題後手動 commit
```

### Web 領域進階流程（在 `/maestro.plan` 與 `/maestro.tasks` 之間插入）

```
/maestro.plan "<功能描述>"
/maestro.web.frontend.spec            # 補 frontend spec 段落（component / a11y / e2e）
/maestro.web.backend.spec             # 補 backend spec 段落（API contract / migration）
/maestro.web.infra.plan               # 產出 INFRA.md (terraform plan dry-run / IAM diff)
/maestro.web.ci.spec                  # 產出 CI.md + draft workflow YAML
/maestro.xreview-plan                 # 補完後再 review
/maestro.tasks
/maestro.work
/maestro.review
```

每一步都會在使用者面前停下來，等你說「OK 繼續」。Plugin 不會偷偷 commit / push、不會 apply infra、不會 trigger deploy。

### 環境需求

- macOS 或 Linux（已測試 macOS arm64）
- `bash` 3.2+（macOS 內建即可）
- `jq`、`gtimeout`（建議 `brew install jq coreutils`）
- `claude` CLI（必要）
- `gemini` CLI（選用，需 `GEMINI_API_KEY` env 或登入）
- `codex` CLI（選用）
- nvm + Node 20/22（用 npm-based CLI 時建議）

## 試跑

```bash
# Mock adapter 測試（不耗 token，驗證 fallback 邏輯）
./test/e2e-fallback.sh

# 真實 CLI 測試（每家 reviewer 跑一次 short prompt）
./test/e2e-smoke.sh
```

## 多模型架構速覽

```
你的需求
   │
   ▼
[Coordinator: Opus]            ← 你的 Claude Code session
   │ 規劃
   ▼
PLAN.md / SPEC.md
   │
   ▼
[orchestrator.sh]              ← 平行 fan-out
   ├─ claude:opus
   ├─ gemini:default
   └─ codex:default
   │
   ▼
[magi-consensus.sh]            ← 加權投票收斂
   │
   ▼
🧠 MAGI Report → 給 coordinator → 給你決策
```

## Config

預設 config 在 `config/default.json`。覆寫請放 `~/.config/maestro-workflow/config.json`。

```jsonc
{
  "xreview": {
    "reviewers": [
      {"cli": "claude", "model": "opus", "weight": 2, "required": true},
      {"cli": "gemini", "model": "default", "weight": 1, "required": false},
      {"cli": "codex",  "model": "default", "weight": 1, "required": false}
    ],
    "magi": {"mode": "majority", "degraded_mode": "warn_user"},
    "fallback_policy": "lenient",
    "min_successful_reviewers": 1
  },
  "node": {"use_nvm": true, "default_version": "22"}
}
```

完整 schema 見 [`SPEC.md`](SPEC.md)。

## 設計守則

- **顯式優先**：所有副作用大的動作都需手動觸發；plugin 不在背後悄悄改檔
- **退化透明**：reviewer 失敗時 MAGI 報告會明確標示「DEGRADED MODE」
- **領域中性**：核心流程（plan / tasks / work / review）不寫死任何技術領域；web 是第一個 add-on
- **不硬綁 Opus 4.7**：用短名 `opus` / `sonnet`，未來換代不需改 plugin

## License

MIT
