# magi-workflow

[![License: MIT](https://img.shields.io/github/license/howar31/magi-workflow?color=blue)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/howar31/magi-workflow?style=social)](https://github.com/howar31/magi-workflow/stargazers)
[![Last commit](https://img.shields.io/github/last-commit/howar31/magi-workflow)](https://github.com/howar31/magi-workflow/commits/main)
[![Open issues](https://img.shields.io/github/issues/howar31/magi-workflow)](https://github.com/howar31/magi-workflow/issues)
[![Built for Claude Code](https://img.shields.io/badge/built%20for-Claude%20Code-CC785C)](https://claude.com/claude-code)
[![Sponsor on Ko-fi](https://img.shields.io/badge/sponsor-Ko--fi-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/howar31)

> 多模型協作的軟體工程 workflow plugin（for Claude Code）

讓不同階段使用不同 AI 模型發揮各自所長：Opus 規劃、Gemini + Codex + Opus 並行審議、Sonnet 實作、再用 MAGI 加權投票收斂結果。

## 特色

- **🧭 自動引導，不用記指令** — 每個 skill 都做狀態 preflight；如果你跑了不對的指令，它告訴你正確的下一步。每個 skill 結束時主動建議下個動作。**你不用記 plan → tasks → work → review → commit 這套儀式，workflow 自己引導**
- **🎯 智慧型 dispatcher** — `/magi.plan "<任何描述>"` 自動分類 type（feat/fix/hotfix/refactor/chore/docs/...）× scale（trivial/minor/major），路由到對應 artifact（PLAN/SPEC/TICKET/HOTFIX/no-artifact）。改 typo 不會跑出完整 PLAN.md，緊急修復走 fast-path
- **多 CLI 並行審議** — `claude` / `gemini` / `codex` 在同一道閘門平行 fan-out，事件流協定 + quota / auth 自動降級
- **MAGI 加權投票** — 4 種模式（majority / supermajority / unanimous / threshold）；reviewer 失敗時退化模式透明標示
- **契約即真理 + 自動 drift 偵測** — `/magi.plan` 寫的 PLAN/SPEC/TICKET/HOTFIX 是凍結契約；`/magi.review-code` 自動比對 code 與契約，輸出 `DRIFT.md`（A 類違反 / B 類自由 / C 類觀察）；`/magi.commit` sprint mode 引導使用者把 A 類回填、C 類升級到 `docs/BACKLOG.md`
- **雙模式 commit** — `/magi.commit` 自動偵測 sprint context；feature work 走 sprint mode、chore/docs/小 fix 走 standalone mode，單一指令通吃所有 commit 情境
- **領域中性** — 核心 slash command（init / plan / tasks / review-plan / go / review-code / commit / setup）不綁特定技術棧
- **Web 領域 add-ons** — frontend / backend / infra / ci 四個專用 spec skill，補強標準 SPEC.md
- **零自動副作用** — 不偷偷 commit / push、不 apply infra、不 trigger deploy；每一步都會停下等使用者確認
- **nvm 相容** — 避開 `#!/usr/bin/env node` 找錯版本的坑（macOS 常踩）
- **團隊化選配** — `references/AGENTS.md` 跨專案守則 SSOT、可選 git hooks（Conventional Commits / lint / WIP 警示）

實作完成度與設計細節見 [`SPEC.md`](SPEC.md)。

## 安裝

```bash
claude plugin marketplace add howar31/howar31-marketplace
claude plugin install magi-workflow@howar31
```

或在 Claude Code session 裡用 slash command：

```
/plugin marketplace add howar31/howar31-marketplace
/plugin install magi-workflow@howar31
```

安裝後第一件事跑 setup wizard：

```
/magi.setup
```

它會檢查你機器上的 `claude` / `gemini` / `codex`、詢問你想啟用哪幾位 reviewer 與權重、寫入 `~/.config/magi-workflow/config.json`，最後跑一次 dry-run 驗證。

新專案第一次採用 magi-workflow 時跑：

```
/magi.init
```

會偵測缺哪些專案文件（root `CLAUDE.md` / `README.md` / `SPEC.md`、`docs/PRD.md` / `docs/TECHSTACK.md` / `docs/BACKLOG.md`）並逐項問你要不要建立 scaffold。idempotent；既有檔案絕不覆寫。

### 作為本機開發 / 直接跑 shell scripts

```bash
git clone https://github.com/howar31/magi-workflow.git /opt/projects/magi-workflow
cd /opt/projects/magi-workflow
./scripts/shared/preflight.sh        # 健檢
./test/e2e-smoke.sh                  # 真 CLI 端到端
./test/e2e-fallback.sh               # mock adapter，免 token
```

## 環境需求

支援平台：macOS（已測 arm64）、Linux。

| 類別 | 工具 | 用途 / 安裝 |
|------|------|-------------|
| **必要** | `claude` CLI | Coordinator — 主要對話介面。安裝：[claude.ai/download](https://claude.ai/download) 或 npm 套件 `@anthropic-ai/claude-code`。 |
| **必要** | `bash` 3.2+ | 已內建於 macOS / Linux。 |
| **必要** | `jq` | 處理 config / 事件流 JSON。`brew install jq` 或 `apt install jq`。 |
| **選用** | `gemini` CLI | 第二位 reviewer。需 `GEMINI_API_KEY` env 或登入。安裝：[github.com/google-gemini/gemini-cli](https://github.com/google-gemini/gemini-cli)。 |
| **選用** | `codex` CLI | 第三位 reviewer。安裝：[github.com/openai/codex](https://github.com/openai/codex)。 |
| **建議** | `gtimeout`（coreutils） | 子程序逾時控制；macOS 透過 `brew install coreutils` 提供。 |
| **建議** | nvm + Node 20/22 | 給 npm-based CLI（gemini / codex）用，避開系統 node 版本問題。 |

未裝 `jq` 或 `gtimeout` 時 `/magi.setup` 的 preflight 會顯示提示，不會默默壞掉。`gemini` / `codex` 任一個失敗，MAGI 會走退化模式繼續（見下方 Troubleshooting）。

## 使用流程

### 通用流程

```
/magi.setup                        # 第一次先跑這個（global，per-user）
/magi.init                         # 新專案第一次跑這個（per-project bootstrap）

/magi.plan "<功能描述>"            # 產出 docs/<num>-<slug>/PLAN.md 或 SPEC.md（依複雜度自動判斷）
                                   # 或乾跑 /magi.plan 從 docs/BACKLOG.md 挑待 promote 項目
/magi.review-plan                  # 多 CLI MAGI 審 plan
/magi.tasks                        # 拆 TASKS.md
/magi.go                         # 派工 magi-developer 實作
/magi.review-code                  # 多 CLI MAGI 審 code 並自動產出 DRIFT.md（--single 退化單審）
/magi.commit                       # sprint mode：A 類回填 PLAN/SPEC、C 類升級到 BACKLOG、可選 root 同步、conventional commits
                                   # standalone mode：chore/docs/小 fix 直接 commit（無 sprint context 時自動切換）
```

> 想 walk-away 一次跑完？看 [yolo 模式](#yolo-模式無人值守)：`/magi.yolo "<描述>"` 從頭跑、`/magi.yolo --resume` 接續現有 sprint。

### Web 領域進階流程（在 `/magi.plan` 與 `/magi.tasks` 之間插入）

```
/magi.plan "<功能描述>"
/magi.web.frontend.spec            # 補 frontend spec 段落（component / a11y / e2e）
/magi.web.backend.spec             # 補 backend spec 段落（API contract / migration）
/magi.web.infra.plan               # 產出 INFRA.md (terraform plan dry-run / IAM diff)
/magi.web.ci.spec                  # 產出 CI.md + draft workflow YAML
/magi.review-plan                  # 補完後再 review
/magi.tasks
/magi.go
/magi.review-code
```

每一步都會在使用者面前停下來，等你說「OK 繼續」。

## 工作流總覽

magi-workflow 的核心是 `/magi.plan` 智慧型 dispatcher——它根據你的描述分類 type × scale，路由到四條不同重量的流程：

```mermaid
flowchart TD
    Start([需求]) --> SetupGate{首次安裝?}
    SetupGate -- 是 --> Setup["/magi.setup<br/>healthcheck + config<br/>(per-machine, 一次)"]
    SetupGate -- 否 --> InitGate
    Setup --> InitGate

    InitGate{專案 init 過?} -- 否 --> Init["/magi.init<br/>scaffold root + docs/<br/>(per-project, 一次)"]
    InitGate -- 是 --> Plan
    Init --> Plan

    subgraph Dispatch["🎯 /magi.plan 智慧型 dispatcher"]
        Plan["/magi.plan &quot;&lt;任何描述&gt;&quot;<br/>type × scale 語意分類<br/>(zh-TW / en / 混雜均可)"]
        Plan --> Route{路由 + user 確認}
    end

    Route -- "major feat / refactor" --> ArtBig["PLAN.md 或 SPEC.md"]
    Route -- "minor / 中等任務" --> ArtMid["TICKET.md"]
    Route -- hotfix --> ArtHot["HOTFIX.md"]
    Route -- "trivial chore / docs / typo" --> ArtTiny["(無 artifact)"]

    ArtBig -. optional .-> RP["/magi.review-plan<br/>多 CLI MAGI fan-out<br/>→ MAGI_PLAN_REVIEW.md"]
    ArtBig --> Tasks
    ArtMid --> Tasks
    ArtHot --> Go
    ArtTiny --> Stand
    RP --> Tasks

    Tasks["/magi.tasks<br/>→ TASKS.md (含 🔀 lane)"]
    Tasks --> Go

    Go["/magi.go<br/>magi-developer (Sonnet) × TDD<br/>auto-parallel disjoint tasks<br/>→ WORKS.md"]
    Go --> RC

    RC["/magi.review-code (mandatory)<br/>多 CLI MAGI 或 --single<br/>→ MAGI_CODE_REVIEW.md + DRIFT.md"]
    RC --> Verdict{verdict / drift?}
    Verdict -- "REQUEST-CHANGES" --> Go
    Verdict -- 通過 --> Sprint

    Sprint["/magi.commit (sprint mode)<br/>A 類回填 PLAN/SPEC<br/>C 類 → docs/BACKLOG.md<br/>root sync 偵測"]
    Stand["/magi.commit (standalone mode)<br/>chore / docs / 小 fix<br/>root sync 偵測"]

    Sprint --> Done([git commit])
    Stand --> Done

    classDef optional stroke-dasharray: 5 5
    class RP optional
```

讀法：
- **每個指令都有 state preflight**：跑錯就拒絕、告訴你下一步。圖上沒畫 preflight 邏輯（每個節點都有，畫了會爆）
- **虛線 = optional**：`/magi.review-plan` 可以省略——人類自己審 PLAN 也行，省 token
- **實線 = mandatory**：`/magi.review-code` 不能省——產出 `DRIFT.md` 是 `/magi.commit` sprint mode 的必需輸入
- **dispatcher 四條路**：trivial 完全跳過 sprint folder；hotfix 連 `/magi.tasks` 也跳；TICKET 跳 review-plan；只有 major 走完整流程
- **MAGI fan-out**：兩個 review skill 在內部都是「多 CLI 平行 + 加權投票」（claude / gemini / codex），實際啟用哪幾家由 `~/.config/magi-workflow/config.json` 控制

### Web add-ons 插入點

四個 web 領域 spec skill 只在 PLAN.md / SPEC.md / TICKET.md 路徑插入（hotfix / trivial 路徑跳過）。在 `/magi.plan` 之後、`/magi.review-plan` 或 `/magi.tasks` 之前手動觸發：

```mermaid
flowchart LR
    PlanArt["PLAN.md / SPEC.md / TICKET.md"] --> FE["/magi.web.frontend.spec<br/>(component / a11y / e2e)"]
    FE --> BE["/magi.web.backend.spec<br/>(API / migration / authz)"]
    BE --> INF["/magi.web.infra.plan<br/>→ INFRA.md"]
    INF --> CI["/magi.web.ci.spec<br/>→ CI.md"]
    CI --> Next["/magi.review-plan 或 /magi.tasks"]
```

只用到的 add-on 才需要跑；四個彼此獨立。每個都會做 state preflight，沒 PLAN/SPEC/TICKET 就 refuse。

### 外部 CLI reviewer 怎麼跑

每個 reviewer **不是常駐 process，也不是另一個 slash command** — 是 `orchestrator.sh` 在你手動觸發 `/magi.review-plan` 或 `/magi.review-code` 那一刻才 spawn 出來的 subprocess：

1. 你打 `/magi.review-plan`（或 `/magi.review-code`）
2. Coordinator 讀 `~/.config/magi-workflow/config.json` 的 `xreview.reviewers` 列表
3. `orchestrator.sh` 平行 spawn 每位啟用的 reviewer：
   - `claude --print "<prompt>"`
   - `nvm exec 22 gemini -p "<prompt>"`
   - `nvm exec 22 codex exec "<prompt>"`
4. 每位 reviewer 獨立跑、互相看不到、各自寫到 `<workdir>/<cli>-<model>.final.txt`
5. 任一位失敗（quota / auth / 真錯誤）→ 標記 SKIP/FAIL，其他繼續
6. 全部完成後，`magi-consensus.sh` 收齊 `.final.txt` + 加權投票 → 產出 `magi-report.md`
7. Coordinator 套 `references/MAGI_VOTING.md` 規則做語意去重 + 最終裁決
8. 結果回給你

換言之，**config 控制的是 fan-out 的「組成」與「失敗策略」，不是「啟動時機」**。沒有 cron、沒有 hook、沒有背景 daemon — 一切從你打那條 slash 開始。

## 角色分工

magi-workflow 內部有三個角色，**Reviewer 角色有兩種實作模式**——MAGI（多 CLI 並行）跟 `--single`（in-session subagent）：

| 角色 | 模型 | 職責 | 不做 |
|------|------|------|------|
| **Coordinator**（main agent） | Opus（你的 Claude Code session） | 規劃、派工、驗收、dispatcher 分類、MAGI 投票收斂、drift 處理、commit 訊息產生 | 不寫 production code |
| **Developer**（`magi-developer` subagent） | Sonnet | TDD 實作（紅 → 綠 → 重構）、產出 DONE / BLOCKED 報告 | 不做架構決策、不擴大範圍、不 commit |
| **Reviewer**（兩種實作） | 看模式 | review code + drift detection 並產 `DRIFT.md` | 不修改檔案 |

### Reviewer 兩種實作模式

| 模式 | 觸發 | 實作 | 輸出 | 何時用 |
|------|------|------|------|------|
| **MAGI mode**（default） | `/magi.review-code`、`/magi.review-plan` | 多個外部 CLI（claude / gemini / codex）平行 fan-out + 加權投票 | `MAGI_PLAN_REVIEW.md` / `MAGI_CODE_REVIEW.md` + `DRIFT.md`（含跨模型共識） | 大部分情況；多模型角度互補 |
| **`--single` mode** | `/magi.review-code --single` | `magi-reviewer` subagent（in-session Opus） | `SINGLE_CODE_REVIEW.md` + `DRIFT.md`（單一 reviewer） | 想省 token、外部 CLI 都不可用、debug |

兩個模式都產出 `DRIFT.md`，所以下游 `/magi.commit` sprint mode 不需要關心是哪個模式產的。

### 為什麼選這組 model mix？

- **Opus 當 Coordinator** — 規劃、派工、dispatcher 分類、收斂多家審議結果需要長上下文與穩定推理；副作用大、值得用最強模型把關
- **Sonnet 當 magi-developer** — TDD 實作多是寫測試 + 產 code，需要快速迭代、低成本；Sonnet 對寫 code 已夠強，留 Opus 給更需要判斷的角色
- **三家並行審議**（MAGI mode） — 不同 LLM 觀點不同，會抓到不同類型的問題（claude 嚴謹、gemini 廣度、codex 偏實作細節）；單一模型容易盲點。MAGI 加權投票讓「多家共識」自動勝出，「單家極端意見」需要被多數推翻才採納

> 想加新的 reviewer CLI（例如 `cursor` / `qwen`）？看 [`SPEC.md` § Adapter contract](SPEC.md#adapter-contract)，照契約實作 `--healthcheck` 與 `run` 兩個模式即可。

## Override flags

每個指令支援的 flag 子集如下：

| Flag | 適用指令 | 範例 / 說明 |
|------|---------|------------|
| `--model <name>` | plan / tasks / work / review-* | `--model opus` — 暫時換 coordinator 模型 |
| `--magi <mode>` | review-plan / review-code | `--magi supermajority`（≥2/3 才採納） |
| `--reviewers <list>` | review-plan / review-code | `--reviewers claude,gemini` — 暫時關掉 codex |
| `--single` | review-code | 退化成 `magi-reviewer` (Opus) 單審 |
| `--diff <range>` | review-code | `--diff origin/main..HEAD` |
| `--staged` | review-code | 只審 staged 變動 |
| `--workdir <path>` | review-plan / review-code | 重用之前的 workdir，跳過 fan-out 只重跑 consensus |
| `--milestone N` | work | `--milestone 2` — 派工指定 milestone |
| `--task T<m>.<n>` | work | `--task T2.3` — 派工單一任務 |
| `--parallel` | work | 同 milestone 中標 🔀 的任務並行派工 |
| `--reset` / `--recheck` | setup | 清掉 config 重做 / 不清 config 重驗 |

完整 flag 規格見 [`SPEC.md` § Override flags](SPEC.md#override-flags-phase-b)。

## yolo 模式（無人值守）

按完就要離開、不想被指令打斷？用 `/magi.yolo`，**兩種模式**：

```bash
# Fresh：從頭跑一個新 sprint
/magi.yolo "<任何描述>"            # 跑完整流程到 commit，停在 local
/magi.yolo "<描述>" --push         # commit 後直接 push（除非你在 default branch）

# Resume：接續現有 sprint
/magi.yolo --resume                       # 接最新 sprint，從當前 state 繼續跑
/magi.yolo --resume --sprint 03-foo       # 指定 sprint
/magi.yolo --resume --push                # 接續 + 跑完後 push
```

**Fresh** 從 `/magi.plan` 開始一路跑到 `/magi.commit`。**Resume** 偵測 sprint 當前 state 自動跳過已做完的 phase——例如「`/magi.plan` 寫完 → `/magi.review-plan` 嫌煩 → 直接 `/magi.yolo --resume` 後面不想管」這種典型 walk-away 場景，yolo 從 `/magi.tasks` 接著跑到 commit。

兩種模式都**任何階段都不問你**。給 walk-away 場景或 CI/scheduled job 用。

### 自動決策（保守，避免破壞性操作）

| 情境 | 正常 mode | yolo mode |
|------|----------|----------|
| Drift A 類（重大契約偏離） | 逐項問 user 要不要回填 | **auto-ignore**（留 DRIFT.md，不改契約——agent 不在無監督下改 PLAN/SPEC） |
| Drift C 類（out-of-scope 觀察） | 逐項問 | **auto-promote** 到 `docs/BACKLOG.md`（append-only，無破壞） |
| Root 文件同步 | 偵測到觸發訊號 → 問 user | **auto-skip**（root 文件影響全專案，不在無監督下動） |
| Commit 訊息 | user 確認 | main agent 自動產 Conventional Commits、不問 |
| Push（如果有 `--push`） | git push | **default branch 拒推**，除非加 `--allow-push-to-default-branch` |

### 失敗 = 立即 abort

任何階段失敗（reviewer FAIL、developer BLOCKED、test 沒過、verdict REQUEST-CHANGES）→ yolo 立即停下，**保留中間狀態給人接手**。`<sprint>/YOLO_LOG.md` 寫明：在哪一階段中斷、原因、建議怎麼從這狀態恢復。yolo 不會自己 retry / auto-fix 任何錯誤。

### 何時用、何時別用

- ✅ 簡單 / 機械性任務（dep upgrade、typo fixes、auto-generated patches）
- ✅ CI / scheduled job（沒有 human session 可以 prompt）
- ✅ 你已經想清楚要做什麼、信任 magi-workflow 對結果分類正確
- ❌ 重要架構變動（沒人盯著危險）
- ❌ 你還在來回改 plan、想看 review 結果再決定的探索性任務
- ❌ 不熟悉 magi-workflow 的人（先用正常流程跑幾次、累積信任再用 yolo）

完整規格（auto-decision 清單、YOLO_LOG schema、abort recovery hint）見 [`SPEC.md` § yolo mode](SPEC.md)。

## 啟用模式（重要）

**每個 slash command 都必須手動輸入 `/magi.<name>` 才會啟動。** 所有 skill 都帶 `disable-model-invocation: true`，意思是即使你在 plain chat 跟 Claude 說「幫我 plan 一下」，也不會自動觸發 `/magi.plan`。

設計理由：
- **可預期** — 每次 fan-out 都會花 token、可能改檔，自動觸發風險高
- **顯式優先** — 你想用就用，不想用就閒置
- **可在 chat 裡先聊** — 想清楚要規劃什麼再下 `/magi.plan`

> **`/magi.yolo` 也適用此規則**：雖然 yolo 是「無人值守」模式，但它本身仍是 `disable-model-invocation: true` 的 slash command——必須使用者明確打 `/magi.yolo "<描述>"` 或 `/magi.yolo --resume` 才會啟動。LLM 不會在 plain chat 裡聽到「幫我跑完整個」就偷偷觸發 yolo。**「無人值守」指啟動之後不問你問題，不是 LLM 自己決定要不要啟動。**

> **進階**：要切成 LLM 可自動 invoke，移掉 `skills/<name>/SKILL.md` frontmatter 裡的 `disable-model-invocation: true`（每個 skill 各自獨立控制）。

## Config

預設 config 在 `config/default.json`。覆寫請放 `~/.config/magi-workflow/config.json`。

修改設定的兩種方式：
- **互動式**：重跑 `/magi.setup`（會引導你重設 reviewer 名單、權重、MAGI mode 等）。
- **手動**：直接編輯 `~/.config/magi-workflow/config.json`（完整 schema 見 [`SPEC.md` § Config schema](SPEC.md#config-schema)）。

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

## 選配：團隊 Git Hooks

```bash
# 在你想啟用的專案裡：
bash /opt/projects/magi-workflow/hooks/install.sh

# 或是手動 copy：
cp /opt/projects/magi-workflow/hooks/{commit-msg,pre-commit,pre-push} .git/hooks/
chmod +x .git/hooks/{commit-msg,pre-commit,pre-push}
```

這會啟用：
- `commit-msg` — 強制 Conventional Commits 格式
- `pre-commit` — 自動偵測並執行專案的 lint / typecheck（pnpm/npm/ruff/mypy/go vet/cargo clippy）
- `pre-push` — WIP / FIXME 警示（不阻擋）

緊急 bypass：`MAGI_SKIP_HOOKS=1 git commit ...`

## 我跑了不對的指令會怎樣？

不會壞——每個 magi.* skill 進入時都會跑 `scripts/shared/detect-state.sh` 偵測專案當前狀態，發現你跑的指令不適用會明確告訴你「應該先跑哪個」。例如：

```
$ /magi.go
Cannot run /magi.go: no TASKS.md and not a hotfix sprint (state=PLANNING)
Suggested: /magi.tasks
```

或：

```
$ /magi.review-code
Cannot run /magi.review-code: no diff to review (working tree clean)
Suggested: make some changes or stage them first
```

每個指令結束時也會建議下一步——你可以單純照建議跑就好，不用記順序。

需要繞過 preflight？所有 skill 都支援 `--force`（極少用，例如修壞的 sprint 從中段恢復）。

## Troubleshooting

### Reviewer 失敗時會發生什麼？

`orchestrator.sh` 會把每位 reviewer 標記為 `RETURN`（成功）/ `SKIP`（quota / auth / missing）/ `FAIL`（其他錯誤），並繼續跑其他位。MAGI 報告開頭會明確標示 **DEGRADED MODE**（可用 reviewer 少於配置數量，或只剩 1 位）。

### 常見狀況對應

| 狀況 | 處理 |
|------|------|
| Claude quota 用完 | 等冷卻 / 換帳號，或暫時跑 `/magi.review-code --reviewers gemini,codex` 跳過 claude |
| Gemini auth 失敗 | `gemini` CLI 自己重登（`GEMINI_API_KEY` 或交互式 login），或 `--reviewers claude,codex` 跳過 |
| Codex 沒裝 | preflight 會直接 SKIP，其他兩家照跑 |
| 三家都不可用 | 用 `/magi.review-code --single` 退化成 `magi-reviewer` (Opus) 單審 |
| nvm node 版本不對 | 編 `~/.config/magi-workflow/config.json` 的 `node.default_version`，或設 `xreview.node_version_per_cli.<cli>` |
| `jq` / `gtimeout` 沒裝 | `brew install jq coreutils`（macOS）或 `apt install jq coreutils`（Linux） |

### 健檢 / 重設

- `./scripts/shared/preflight.sh` — 跑一次健檢，看哪幾位 reviewer 可用
- `/magi.setup --recheck` — 不清 config，只重驗證一次
- `/magi.setup --reset` — 清掉 config 重做 wizard

### 輸出檔位置

依 **Project document tiers** 三層歸屬：

**Tier 1 — Root**（高頻入口參考；`/magi.init` 一次建立、`/magi.commit` 持續同步）

| 檔案 | 角色 |
|------|------|
| `CLAUDE.md` | AI agent 索引 |
| `README.md` | human-readable 說明 |
| `SPEC.md` | architecture spec |

**Tier 2 — `docs/`**（流程支援檔；`/magi.init` 建空骨架）

| 檔案 | 角色 |
|------|------|
| `docs/PRD.md` | 產品需求 |
| `docs/TECHSTACK.md` | 技術棧約束 |
| `docs/BACKLOG.md` | 待 promote 項目（`/magi.commit` 寫入；`/magi.plan` 乾跑時讀取） |

**Tier 3 — `docs/<num>-<slug>/`**（per-feature；`/magi.plan` 建立、sprint 結束凍結）

| 指令 | 輸出 |
|------|------|
| `/magi.plan` | `PLAN.md` 或 `SPEC.md`（依複雜度自動判斷） |
| `/magi.tasks` | `TASKS.md` |
| `/magi.go` | `WORKS.md` |
| `/magi.review-plan` | `MAGI_PLAN_REVIEW.md` |
| `/magi.review-code`（MAGI） | `MAGI_CODE_REVIEW.md` + `DRIFT.md`（一律產出，`Status: NONE`/`DETECTED`） |
| `/magi.review-code --single` | `SINGLE_CODE_REVIEW.md` + `DRIFT.md` |
| `/magi.web.infra.plan` | `INFRA.md`（含 `plan.tfplan` / `plan.json`） |
| `/magi.web.ci.spec` | `CI.md` + draft workflow YAML |

## 升級與移除

```bash
# 拉最新 marketplace 內容
claude plugin marketplace update howar31

# 升級 plugin 到最新版
claude plugin update magi-workflow

# 升級後若 schema 有變動，重跑 setup 重新驗證
/magi.setup --recheck

# 移除 plugin（保留 marketplace 註冊）
claude plugin uninstall magi-workflow

# 連 marketplace 一起移除
claude plugin marketplace remove howar31
```

> 預設不會自動更新；要 marketplace 啟動時自動拉新版，在 Claude Code 內跑 `/plugin marketplace`，找到 `howar31` 把 auto-update 開起來，更新後它會提示 `/reload-plugins`。

config 在 `~/.config/magi-workflow/config.json`，移除 plugin 不會自動刪 config — 想完全清乾淨手動 `rm -rf ~/.config/magi-workflow/`。

## 試跑

```bash
# Mock adapter 測試（不耗 token，驗證 fallback 邏輯）
./test/e2e-fallback.sh

# 狀態偵測單元測試（不耗 token，驗證 detect-state.sh 在 8 種 state + warning 情境輸出正確）
./test/e2e-state.sh

# 真實 CLI 測試（每家 reviewer 跑一次 short prompt）
./test/e2e-smoke.sh
```

## 尚未涵蓋的情境（已知限制）

magi-workflow 目前刻意不處理以下兩個情境，等實際使用累積到痛點才回頭補。列在這裡是為了避免使用者誤以為「我哪裡用錯了」。

### 多人團隊並行 sprint 的衝突

magi-workflow 目前的 state 偵測（`detect-state.sh`）以「最新 sprint」為 default。當多人在同一 repo 平行跑不同 feature branch、各自有 active sprint 時，可能出現：
- `/magi.commit` 自動偵測模式時挑錯 sprint（不過已有 `--sprint <slug>` 手動指定當 escape hatch）
- 兩個 sprint 都改了 root SPEC.md，merge 時要怎麼整合
- 跨 sprint 的 review 共識、commit 順序協調

**目前解法**：用 `--sprint <slug>` 明確指定，或約定每個 branch 只跑一個 sprint。等團隊化使用累積到實際痛點再做完整方案。

### B 類偏離的累積回饋（Reflexion 強化）

`/magi.review-code` 的 DRIFT.md 把 B 類條目（implementation 在契約之下的自由選擇）留在檔內當 audit trail，不主動提醒 user 處理。但長期下來，**如果某一類 B 條目反覆出現**，意味著契約對該層其實還不夠具體，PLAN/SPEC 應該往下挖一階。

**目前解法**：B 類靜態保留；user 自己讀 DRIFT.md 發現 pattern 後手動 `/magi.plan --into <sprint>` 修契約。等真實 sprint 累積出 B 類密度數據再評估自動化提醒的閾值。

## 設計守則

- **顯式優先** — 所有副作用大的動作都需手動觸發；plugin 不在背後悄悄改檔、不偷偷 commit / push、不 apply infra、不 trigger deploy。**例外**：[`/magi.yolo`](#yolo-模式無人值守) 是明確 opt-in 的「無人值守」模式，使用者打那個指令本身就是顯式同意；yolo 在無監督下仍對 destructive 操作（A 類 drift 回填、root 文件修改、force push）做保守 auto-skip 處理，並全程寫 audit log。**沒打 `/magi.yolo` 的話，顯式優先守則 100% 適用**——這是兩條獨立軌道，不是守則被破壞
- **退化透明** — reviewer 失敗時 MAGI 報告會明確標示「DEGRADED MODE」
- **領域中性** — 核心流程（plan / tasks / work / review）不寫死任何技術領域；web 是第一個 add-on
- **不硬綁 Opus 4.7** — 用短名 `opus` / `sonnet`，未來換代不需改 plugin
- **狀態純從檔案推導** — magi-workflow 不存任何 state 檔；每次指令前 `scripts/shared/detect-state.sh` 即時計算當前 state，意味著你切 git branch、改檔、刪檔，magi 都跟著反映、不會有 stale 假設

## License

MIT
