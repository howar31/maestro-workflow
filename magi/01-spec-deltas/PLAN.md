# Spec Deltas — 宣告式契約變更

## Context

magi-workflow 對「sprint 是否會改動專案級活文件（root `SPEC.md` / `CLAUDE.md` / `magi/PRD.md` / `magi/TECHSTACK.md`）」目前採 **被動偵測**：

- `/magi:plan` 階段：完全沒寫，PLAN.md / SPEC.md 只描述 feature 本身
- `/magi:commit` 階段：靠 Level 1/2 啟發式（dep 變更、關鍵字掃描、per-sprint SPEC vs root SPEC 矛盾比對）猜測該不該改 root docs
- `/magi:review-plan` 階段：reviewer 看不到任何「這個 sprint 預期改動哪些 root 章節」的訊號

問題：reviewer 盲點、多 sprint 並行盲點、heuristic miss/false-positive。

OpenSpec 的核心啟發是每個 change 在提案階段就 **明確宣告** spec deltas。本 sprint 把該機制 **輕量化** 引入：

- 在 PLAN.md / SPEC.md（major scale）導入「Spec deltas 宣告」一節
- `/magi:review-plan` reviewer 評估宣告是否合理
- `/magi:commit` 從 heuristic 偵測升級為 **核對宣告 vs 實際 diff**
- DRIFT.md 仍負責 post-hoc 偵測；deltas = 預期、drift = 偏離

非目標：不引入 OpenSpec 的 capability-organized specs；不改 trivial / hotfix；不取代 DRIFT.md。

## Goals & Non-Goals

**Goals**
- PLAN.md / SPEC.md 模板新增 `## Spec deltas` section，固定四個子標題對應四份專案級活文件
- `/magi:plan` 起草 deltas（coordinator 自問四題、允許全 `(none)`）
- `/magi:review-plan` reviewer prompt 加入評估 deltas 的指示
- `/magi:commit` sprint mode 新增 §2.5 Delta verification（D1/D2/D3 分類），預設 lenient；新增 `--strict-deltas` 旗標
- `/magi:commit` Level 2 root-sync 在 deltas 已宣告且 verification 通過時降為 fallback；Level 1 不變
- `--no-root-sync` 同時跳過 §2.5（保留逃生口）

**Non-Goals**
- TICKET.md / HOTFIX.md 不加 deltas（兩類本來就不該動 root docs）
- 不新增獨立 SPEC_DELTA.md 檔（嵌入式設計，零新檔）
- 不動 detect-state.sh
- 不動 magi-developer / magi-reviewer agent 行為

## Design options considered

| 選項 | 結論 |
|------|------|
| (A) 嵌入 PLAN/SPEC 內一節 ✅ | 採用。零新檔；不動 detect-state；自然跟著 plan review 走 |
| (B) 獨立 SPEC_DELTA.md | 棄。需改 detect-state.sh + 4 個 skill；mtime 追蹤目前用不到 |
| (C) 在 magi/BACKLOG.md 旁開 magi/DELTAS.md 集中管理 | 棄。跨 sprint 集中管理目前沒實際 use case |

`/magi:commit` strict 模式預設選擇：
| 選項 | 結論 |
|------|------|
| 預設 lenient ✅ | 採用。D1/D2 提示而非 abort，與既有 UX 一致；`--strict-deltas` 啟用嚴格模式 |
| 預設 strict | 棄。增加新概念的學習成本，違反現有 lenient 風格 |

## Recommended approach

### Schema

PLAN.md / SPEC.md 模板尾端（`## Verification` 之前）新增：

```markdown
## Spec deltas

宣告本 sprint 預期修改的專案級活文件章節。`/magi:review-plan` 會以此評估
本提案對既有契約的衝擊；`/magi:commit` 會核對實際 diff 是否一致。

> 若本 sprint 不修改任何 root / magi 級文件，每個子標題都寫 `(none)`。

### root `SPEC.md`
- **Section: <章節名>** — <add | modify | remove>
  Why: <為何需要這個變更>
  New content: <一句話描述改完後的樣子>

### root `CLAUDE.md`
(none)

### magi/`PRD.md`
(none)

### magi/`TECHSTACK.md`
(none)
```

四個固定子標題，空著就寫 `(none)`，不要省略子標題（解析穩定性）。

### `/magi:plan` 改動

- §2 read context：當 artifact ∈ {PLAN.md, SPEC.md} 時，**額外** 讀取 root `SPEC.md`（其他三份已在讀）
- §3 draft：尾段新增「draft Spec deltas」子步驟。Coordinator 對四份文件各自自問「本 feature 的 design 是否要求修改這份文件的某個章節？」並寫成 deltas section
- §4 write：不變
- §5 hand-off：訊息提示使用者「審 deltas 一節」之後再決定是否跑 review-plan
- TICKET.md / HOTFIX.md 模板不動

### `/magi:review-plan` 改動

`xreview-prompt.md` builder 末尾追加固定段落，要求 reviewer 評估 deltas 是否合理、有無漏宣告、是否破壞既有契約。`MAGI_PLAN_REVIEW.md` schema 不需改。

### `/magi:commit` 改動

- 新增 §2.5 Delta verification（drift handling 之後、root-sync 之前）：
  - 解析本 sprint PLAN.md / SPEC.md 的 `## Spec deltas` section → expected set
  - `git diff --name-only HEAD` 對四份專案級活文件 → actual set
  - 三類偏離：
    - **D1 Declared but missing**：宣告會改但 diff 沒看到 → 提示「忘了更新？」
    - **D2 Modified but undeclared**：diff 改了但沒宣告 → 提示「補宣告？或這是意外？」
    - **D3 Match**：吻合 → 靜默通過
  - 互動：D1/D2 對應 (y backfill / n proceed-anyway / e edit)；`--strict-deltas` 任何 D1/D2 直接 abort
- §3 root-sync 降級：若 deltas verification 通過 → 跳過 Level 2 啟發式（已有更可靠訊號）。Level 1（dep 變更、Dockerfile 等）仍跑（涵蓋 deltas 抓不到的東西）
- 新增 `--strict-deltas`：D1/D2 → exit 非零、不互動。預設 off
- `--no-root-sync` 行為延伸：同時跳過 §2.5（保留逃生口）

## Open questions

- D2 偵測精度：目前以檔案級判斷（`git diff --name-only`），未做章節級 hunk 比對。第一版接受這個粗粒度；若後續發現誤報太多，再加 hunk-level header diff
- yolo 模式下 D1/D2 的處理：本 sprint 暫不改 yolo skill；yolo 共用 commit skill，自然繼承 lenient 行為（D1/D2 提示但不 abort）。**待 yolo 真實使用時再決定** 是否需要 yolo-specific auto-decision

## Verification

實作完後依序：
1. `bash -n` 對所有改過的 SKILL.md 內嵌 bash 區塊
2. `./test/e2e-state.sh` — state model 不退化（未動 detect-state，全綠）
3. `./test/e2e-fallback.sh` — orchestrator + MAGI 報告仍正確
4. 手動 dogfood：在本 repo 跑 `/magi:plan "..."` 確認模板含 deltas section
5. 三類偏離手測：D1（宣告但不改）/ D2（改但不宣告）/ D3（吻合）
6. `--strict-deltas` 應 exit 非零；`--no-root-sync` 應跳過 §2.5

## Spec deltas

宣告本 sprint 預期修改的專案級活文件章節。

### root `SPEC.md`
- **Section: Slash commands**（命令列表）— modify
  Why: `/magi:plan` 與 `/magi:commit` 的 body summary 需更新，反映 deltas section 與 `--strict-deltas` 旗標
  New content: `/magi:plan` 條目補「PLAN/SPEC 模板含 Spec deltas section」；`/magi:commit` 條目補 §2.5 delta verification 與 `--strict-deltas`

- **Section: Override flags**（旗標表）— modify
  Why: 新增 `--strict-deltas`
  New content: 新增一列：`--strict-deltas | commit | D1/D2 偏離 → abort`

- **Section: Implementation phases**（階段表）— modify
  Why: 標記 F-Phase 4 完成
  New content: 新增 F-Phase 4 row：`Spec deltas — declarative root-doc contract`（status ✅ done）

- **Section: 新增 ## Spec deltas**（v0.9 機制描述）— add
  Why: 文件化新機制，包含 schema、適用範圍、verification 流程
  New content: 一節描述 schema、Type×Scale 適用範圍、`/magi:plan` 起草、`/magi:review-plan` 評估、`/magi:commit` D1/D2/D3 verification

### root `CLAUDE.md`
(none)

### magi/`PRD.md`
(none)

### magi/`TECHSTACK.md`
(none)
