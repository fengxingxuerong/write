# InkSmith (墨匠) — a local-first, one-click novel writing tool

[![CI](https://github.com/fengxingxuerong/write/actions/workflows/ci.yml/badge.svg)](https://github.com/fengxingxuerong/write/actions/workflows/ci.yml) ![Coverage](https://img.shields.io/badge/coverage-80%25%20gate-brightgreen) ![Tests](https://img.shields.io/badge/tests-CI-blue) ![Dart](https://img.shields.io/badge/dart-3.12%2B-blue) ![Flutter](https://img.shields.io/badge/flutter-3.44%2B-blue) ![License](https://img.shields.io/badge/license-MIT-green)

> A single-codebase Flutter / Dart application. Offline by default with zero external APIs: it only goes online when you explicitly enable a cloud LLM, crash reporting, or AI requests from the web workbench.
> Supports local large models (llama.cpp / Ollama) for AI-assisted writing; the built-in template engine remains fully usable when networking is disabled.

> **AI-assisted creation · author sovereignty · human gatekeeping.** InkSmith is a writing *assistant*, not an autopilot ghostwriter. The toolchain is **draft generation → machine gate → human read-through review → contract-worthiness assessment**. Before publishing, the author must complete their own review and revision.

[简体中文](README.md)

---

## Table of contents

- [Features](#features)
- [Connecting a local model](#connecting-a-local-model)
- [Export](#export)
- [Repository layout](#repository-layout)
- [Quality criteria and thresholds (single source of truth)](#quality-criteria-and-thresholds-single-source-of-truth)
- [Build & run](#build--run)
- [Verification, tests and CI](#verification-tests-and-ci)
- [Where data is stored](#where-data-is-stored)
- [Secrets & security](#secrets--security)
- [Architecture notes](#architecture-notes)
- [Scope and limitations](#scope-and-limitations)

---

## Features

### Writing experience

- **Three-pane workspace**: chapter list / editor / characters·worldbuilding·settings panel.
- **Style reference (learns the distribution, never copies sentences).** Import a web novel you like (`.txt`/`.md`, or paste it directly) from the settings panel and InkSmith extracts a **nine-dimension style fingerprint** (mean sentence length and its variance, dialogue ratio, mean paragraph length, single-sentence paragraphs, 「的」 density, reduplicative words, sentence-initial connectives, metaphor density) and stores it with the project. During generation the fingerprint is injected into the writer prompt so the book's **sentence rhythm and paragraph breathing** drift toward the reference text. A dialog lets you preview both the exact prompt block that will be injected and the **distance between your existing prose and the reference**. Only the distribution numbers are stored — **the original text is never kept** — and two guardrails are attached (no copying, and "when in conflict, the house style rules win", to prevent learning the distribution but also learning "low dialogue ratio" by accident). Samples under 500 characters are rejected.
- **Externally-visible payoff loop (no faking payoff with "a warmth in the palm").** Every chapter contains at least one payoff the reader can actually perceive (face-slapping / gaining a reward / a revelation / public reaction). ① Scene planning marks the "turn" scene as the payoff scene and mandates writing an onlooker reaction; ② when several consecutive chapters contain no externally-visible payoff, it is flagged as a **payoff drought** and raised as an alarm in the whole-book health check and the contract-worthiness assessment; ③ an automatic patch-up pass runs at chapter end (it only adds externally-visible payoff — main plot and setting rules are untouched, and the original prose is never degraded).
- **Editor**: 3-second debounced autosave plus an immediate save on blur/exit; live word count with a **word-goal progress bar**; font size (10–28) and line height (1.4–2.0) adjustment.
- **Writing statistics**: current chapter word count / paragraphs / sentences / words written today / mean sentence length.
- **Chapter splitting**: split a long chapter into multiple chapters by blank-line block in one click (order is re-indexed automatically).
- **Find & replace (Ctrl+F)**: live match count, ↑/↓ cyclic jumping, replace current / replace all; a sensitive-word recheck is triggered automatically after replacement.
- **Whole-book search**: search chapter prose, chapter titles, chapter outlines, character profiles and worldbuilding settings, showing the hit source and a context snippet.
- **Pomodoro timer**: 25-minute focus timer, toggleable at any time while editing.
- **Sensitive-word check**: a built-in lexicon of 100+ terms in 5 categories (gore / sexual content / profanity / illegal content / advertising spam). Hits are shown with context, per-category counts, a **historical cumulative TOP ranking**, and support for adding/removing custom terms; rechecked automatically on save/replace.
- **AI assist**: in-editor 「✨ Continue」 (streaming mid-sentence continuation with a chosen length) / 「📝 Rewrite」 (rewrite the selected text) / 「🔍 Proofread」 (typos / malformed sentences / repetition, apply what you check). All three inject the character's dialogue style into the prompt.
- **Drafts box**: stash prose you're unhappy with in one click, managed from a workspace dialog (promote / delete).
- **Focus mode (F11)**: hide the sidebar for immersive writing.
- **Shortcuts**: `Ctrl+S` save / `Ctrl+B` generate / `Ctrl+E` export / `Ctrl+N` new chapter / `Ctrl+F` find & replace in the editor / `Ctrl+Shift+F` whole-book search / `F11` focus mode.

### Novel management

- **JSON file storage**: one `.json` file per project (`meta` + `chapters` + `characters` + `worldSettings`). Copy the file to another machine and you have migrated.
- **Manuscript import**: the shelf's **Import** action accepts **TXT / Markdown**, recognizes 「第 X 章 / 序章 / 楔子 / 番外」 and Markdown headings, previews the chapter split and word count, then creates a new work. The source file is read-only and existing projects are never overwritten. UTF-8 (with BOM) and UTF-16 LE/BE (with BOM; BOM-less ASCII is also sniffed) are supported; GBK files get an actionable "save as UTF-8" message rather than being silently decoded into mojibake.
- **Project list**: title search, filtering (all / in progress / archived), cards showing genre·chapter count·word count·last update; supports **archive / unarchive** (no data is deleted); deleted works go to a **trash** kept for 30 days and can be restored or permanently removed.
- **Backup & restore**: import a JSON backup directly from the shelf. Importing copies it as a new work and rewrites the internal IDs, so existing projects are never overwritten.
- **Characters / worldbuilding / outlines**: structured editing, maintained continuously as chapters advance. A **volume outline overview** dialog aggregates the outline key points of every chapter and can copy them in one click as the input for multi-chapter continuous writing.
- **Project info**: title, genre, tone and per-chapter word target can be changed at any time; the target drives chapter progress and writing statistics (0 = no target), instead of mistaking the generation cap for a writing goal.
- **Reading mode**: a built-in reader (white / beige / night themes; font size, line height and serif are adjustable and persisted).

### Generation engine (pluggable)

- A `GenerationEngine` abstraction with two implementations:
  - **TemplateEngine**: fully offline, zero dependencies. Ships a built-in Chinese web-novel corpus (5 genres × 30+ names / 20+ place names / 40+ sentence patterns / 10+ plot skeletons). Runs in an Isolate, is cancellable, reports progress, and uses seed-controlled randomness.
  - **LlmEngine**: connects to a local large model (llama-server / Ollama, OpenAI-compatible protocol) with streaming output, progress reporting and an 8-second connection timeout.
- **AI generation config**: genre (xuanhuan / urban / sci-fi / romance / suspense), tone, target word count, randomness, protagonist name, outline-driven generation, and an **AI outline-expansion switch**.
- **Writing style control**: paragraph structure (standard / terse short sentences / long and detailed / dialogue-dense) × prose style (web novel / Gu Long / Jin Yong / Japanese light novel), combined orthogonally into the prompt, with preferences persisted per project.
- **Multi-chapter continuous writing**: generate 1–10 chapters at once, each continuing from the end of the previous one (continuation), with the volume outline distributed line-by-line across chapters. Each chapter title is summarized by AI (with automatic fallback on timeout).
- **AI chapter titles**: an 8–15 character title is summarized in parallel after the prose is generated; failure never blocks.
- **AI memory**: automatically extracts new characters and settings and accumulates them, injected into the context at generation time (waits up to 8 seconds; on timeout it continues in the background).
- **20,000-character per-chapter ceiling**: a generation performance safety line (configurable constant).

## Connecting a local model

Qwen3-2B is recommended.

1. Start a local inference server (e.g. llama-server on port 19110).
2. InkSmith → AI generation settings → 「Detect local model」 auto-fills `Qwen3-2B` + `http://127.0.0.1:19110`.
3. Save, and AI generation is ready.

> ⚠️ **Note:** local models go through the "cloud API" provider branch with the Base URL pointed at localhost. llama-server only supports the OpenAI-format `/v1/chat/completions`. For reasoning models (such as the Qwen3 series) you must disable the thinking chain (`enable_thinking: false`), otherwise the thinking chain eats the whole token budget and the prose comes back blank.
>
> 🚀 **GPU acceleration:** llama-server ships a Vulkan backend. On an NVIDIA card you can start it with `--n-gpu-layers 999 --device Vulkan0`, taking a 2B model from ~10 chars/s to **~140 chars/s** (a 2,000-character chapter in about 15 seconds).

## Export

- **Plain text (.txt)** / **Markdown (.md)** / **EPUB ebook (.epub, a hand-written pure-Dart zip)** / **Word (.docx, a hand-written pure-Dart OOXML)** / **JSON backup (.json)** — five formats.
- Supports **attaching character and worldbuilding appendices** (txt/md/docx), and **exporting all formats at once** (skipped items are summarized). Export preferences (last format / whether to attach settings) are remembered automatically.
- `file_picker` lets the user choose the save path.

## Repository layout

```
lib/
├── main.dart / app.dart            # entry point and root widget
├── core/                           # routing / theme / DI / constants / exceptions
│   └── di/providers.dart           # Riverpod DI (engine switching, settings, sensitive words, ...)
├── models/                         # Novel / Chapter / Character / WorldSetting / GenerationConfig / LlmConfig
├── storage/                        # AppDatabase (JSON) + Novel/Chapter/Setting repositories
├── engine/                         # generation engine abstraction + TemplateEngine + LlmEngine + corpus + seeded RNG + constraints
├── services/                       # sensitive-word check / search service
├── features/                       # project_list / workspace / editor / generate / export / reader
│   ├── project_list/               # project list (search / filter / archive)
│   ├── generate/                   # generation dialog + GenerateViewModel (multi-chapter loop / AI titles / AI memory)
│   ├── editor/                     # editor (find & replace / pomodoro / sensitive words / stats / chapter split)
│   ├── export/                     # export page + five formats + cover generation
│   └── workspace/                  # three-pane workspace + settings panel + LLM settings + volume outline / stats
└── widgets/                        # shared components
```

`SKILL.md` packages this project's core capabilities as a coding-agent-callable skill (directly discoverable in ecosystems such as Claude Code / OpenClaw), including common commands, how to read the artifacts and a troubleshooting table — **a manual written for agents, and a cheat sheet for humans too**.

> 📚 Documentation entry point: [`docs/README.md`](docs/README.md) — organized by "what problem are you trying to solve", and marking which documents are historical archives (do not edit code based on them).

## Quality criteria and thresholds (single source of truth)

The lexicons (hooks / payoffs / power-ups / side reactions / opening strength / the three-part set / first-screen conflict signals … **867 words** in 31 groups, as reported by `rules_codegen.py --check`) and the thresholds (dialogue floor, filler-paragraph ceiling, the three drought parameters, the minimum patch-up length, the minimum editor acceptance … **10 items**) exist in exactly one place: `rules/quality_rules.json`.

```bash
# To change a criterion: edit only the JSON, then regenerate the three artifacts
# (Dart constants / Python constants / a human-readable summary table)
python scripts/rules_codegen.py

# Verify (CI gate): the generated artifacts must match the JSON character-for-character, or this fails
python scripts/rules_codegen.py --check

# To find out where the two sides' lexicons differ and whether they should be merged,
# use a real A/B on produced books (measurement only, never edits the table)
python scripts/ab_rules_parity.py

# To find out whether the current "passing line" is aligned with human evaluation
# (currently: 0 real annotations = not aligned)
python scripts/quality_validation.py
```

| If you want to know | Look here |
|---|---|
| What the current thresholds are and why they are those numbers | `docs/quality-rules-current.md` (generated — do not hand-edit) |
| Whether the two sides' constants were hand-edited | `test/engine/quality/quality_rules_parity_test.dart` + `scripts/test_quality_rules_parity.py` |
| Where the two lexicons differ and how large the merge surface is | `python scripts/ab_rules_parity.py` (conclusions from a real corpus, not inference) |
| Whether the metrics actually correlate with human evaluation (should we use them at all) | `docs/human-eval-workflow.md` + `python scripts/quality_validation.py` |
| Whether the two sides' **algorithms** agree on real produced books | `tool/verify_*_parity_test.dart`; the **payscene and drought suites run in CI** (executed explicitly by the `Dual-end parity (corpus-free)` step) — they read frozen baselines committed to the repo, `rules/payoff_scene_parity.json` / `rules/payoff_drought_parity.json`, guarded on the Python side by `scripts/test_payoff_scene_parity.py` and `scripts/test_drought_parity.py`. The stylefp suite still depends on the `data/generated/` corpus (its input is full prose, so it cannot be frozen without committing generated artifacts); run `python tool/gen_parity_baselines.py` locally to generate the baseline, and `--check` recomputes the comparison |

> The `flutter test` run in CI **no longer** includes "missing baseline → SKIP → pass" cases — such checks have moved into `tool/`, where a missing dependency fails the build outright. This avoids the false green of "all tests pass but the two sides' criteria actually disagree".

## Build & run

### Prerequisites

- Install [Flutter 3.44+ / Dart 3.12+](https://docs.flutter.dev/get-started/install) and the Windows toolchain. **Windows desktop is the primary platform** (the repo maintains the `windows/` runner and CI builds and verifies it); there is also a standalone web workbench; other platforms are not shipped with the repo.
- Chinese mainland mirror (optional):
  ```powershell
  $env:PUB_HOSTED_URL='https://pub.flutter-io.cn'
  $env:FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn'
  ```

### Install dependencies

```bash
flutter pub get
```

### Run

```bash
flutter run -d windows   # Windows desktop (primary platform)
```

> There is also a standalone web workbench: `web/index.html` + `web/app.js` + `web/ai.js`. Open it directly in a browser. It is **not** a Flutter Web build artifact, and its feature set is not identical to the desktop app. From the workbench you can open the **relation map** (`web/relations.html`, also usable standalone): a visual canvas for character relationships, plot threads, and foreshadowing, with auto-seeding from book data and import from desktop project JSON.
>
> Android / iOS / macOS / Linux runners are not shipped with the repo and are not verified in CI. To add support, generate the runners yourself with `flutter create .` and adapt them (see below).

### Platform runners (needed the first time)

The `windows/` and `web/` runners ship with the repo. If those directories are missing, or you need another platform, run:

```bash
flutter create .
```

This fills in the platform runners and configuration according to the current `pubspec.yaml` and **will not overwrite the `lib/` code you wrote**.

### Core verification (same core gates as CI)

```bash
# Windows portable package: CI uploads the ZIP and a same-named .sha256
flutter build windows --release

# Quality-rules single-source-of-truth check (same as CI):
# the generated artifacts must match rules/quality_rules.json
python scripts/rules_codegen.py --check

# Full local verification: analyze, tests/coverage, Python, Web, Windows build
powershell -ExecutionPolicy Bypass -File verify-novel.ps1
```

> CI produces `InkSmith-<version>-windows-x64.zip` plus a SHA-256 checksum file. `installer.iss` is an optional Inno Setup installer script; compiling it requires Inno Setup installed locally.

### Local verification options

```powershell
powershell -ExecutionPolicy Bypass -File verify-novel.ps1                      # analyze + Flutter tests/coverage + Python + Web + Windows build
powershell -ExecutionPolicy Bypass -File verify-novel.ps1 -SkipBuild           # skip the Release build
powershell -ExecutionPolicy Bypass -File verify-novel.ps1 -SkipPython -SkipWeb # analyze + Flutter tests only
```

> Logs are written to `verify-logs/`. Flutter tests produce `coverage/lcov.info`; both the local script and CI require line coverage ≥ 80%.

## Verification, tests and CI

### Static analysis and tests

```bash
flutter analyze
flutter test
```

Current test and coverage figures are whatever CI actually reports. CI requires line coverage of collected production files to be at least **80%**, and verifies that 12 key security / storage / quality-gate files appear in the LCOV report (`secret_store` / `llm_config` / `novel` / `pipeline_storage` / `composite_quality_gate` / `app_database` / `chapter_repository` / `chapter_snapshot_service` / `novel_repository` / `setting_repository` / `novel_quality_checker` / `fanqie_gate_checker`). Tests cover model serialization, template generation, storage reliability, export, the AI pipeline, resume-from-checkpoint, import idempotency, privacy copy, the Windows DPAPI channel, and **dual-end reconciliation of the quality lexicon and thresholds** (`quality_rules_parity_test`).

**Writing-ability floor guardrail** (`test/engine/quality/writing_ability_test.dart`): instead of merely proving "the engine runs", it asserts that **the novels the engine actually produces meet a quality floor** — 5 genres × 2-chapter continuous writing, pinning per chapter that the fanqie gate is met (score ≥ 80 with no blocking items / vetoes), prose hygiene score, AI-flavour density, adjacent-paragraph repetition ratio, dialogue ratio and final chapter length; and pinning at book level that the sensitive-word check is clean, that cross-chapter consistency is zero (worldbuilding / plot / protagonist continuity) and that the protagonist genuinely lands. The same file carries **negative controls** (filler prose and AI-flavour-stuffed prose must fall *below* the ability line), ensuring these score assertions are not tautologies that would still pass if the quality checker itself were broken. All thresholds are taken from measured baselines with margin left over, and only intercept ability-collapse-class regressions. The offline smoke tests (three-chapter `test/smoke/write_demo_novel_test.dart` and ~10k-character `test/smoke/write_long_novel_test.dart`) and the full-chain E2E test (`test/features/full_novel_e2e_test.dart`) verify the score floors under the same criteria.

### CI pipeline

The repo is configured with GitHub Actions (`.github/workflows/ci.yml`): it runs automatically on push / PR to `main` or `master`. The Windows build waits for the Flutter tests and the web regression to pass completely before packaging and uploading.

1. **`dart analyze --fatal-infos`** — zero static-analysis findings (any info, including deprecations, counts as failure)
2. **Python-side gates** — `compileall` + `ruff --select=F` + **`rules_codegen.py --check` (generated artifacts consistent with the data source)** + the full `unittest` suite + a `--help` entry-point regression per module + an offline three-chapter book-generation smoke test
3. **`flutter test --coverage`** — the full test suite + an **80%** coverage gate, plus verification that the 12 key security / storage / quality-gate files appear in LCOV
4. **Web regression** — the shelf, the editor, the AI guard, import atomicity and error paths
5. **`flutter build windows --release`** — Windows portable ZIP + SHA-256 checksum, uploaded automatically

The local equivalent is `powershell -ExecutionPolicy Bypass -File verify-novel.ps1` (by default it includes analyze, Flutter tests/coverage, Python, the web regression and the Windows build).

## Where data is stored

- Project data: `applicationSupportDirectory/novels/` on each platform — one `<id>.json` file per project plus an `index.json` index; deleted projects are kept in `novels/trash/` (30 days or at most 50 entries, restorable from the shelf's **Trash**).
- AI settings: `llm_settings.json` (written atomically via tmp+rename; the Windows desktop build encrypts the API key with DPAPI, and local Ollama addresses need no API key).
- Reader settings: `app_settings.json` (theme / font size / line height / serif).
- Sensitive words: `sensitive_words.json` (custom terms) + `sensitive_stats.json` (historical hit statistics).
- Cross-platform migration: copy the corresponding `<id>.json` file into the `novels/` directory on the target device; alternatively use **Import** on the shelf to restore a JSON backup as a new work, or import a TXT / Markdown manuscript and keep writing.

## Secrets & security

- **Templates in the repo, real values out.** Copy `.env.example` to `.env.local` and fill in the real key. `.gitignore`'s `.env.*` rule covers it, and `scripts/test_secret_hygiene.py` (run in CI) asserts that it really is ignored and scans **committed files** for high-entropy key-like strings (guarding against `git add -f` and accidental pasting).
- **Running real books costs nothing by default.** `python tool/live_run.py` only performs a key health check and a cost estimate — it sends no requests at all. Only after confirming do you explicitly pass `--yes` to launch `novel_pipeline.py`.
- **Credential encryption**: the app's in-app AI settings encrypt the API key with DPAPI on Windows desktop (`lib/core/security/secret_store.dart`); no plaintext JSON is written. The DPAPI channel itself has unit tests.
- This repo **forbids** writing real keys into code / docs / logs. If `.env.local` was ever shared or committed, rotate your keys on the respective platforms.

## Architecture notes

- **Engine switching**: `generationEngineProvider` switches between `LlmEngine` and `TemplateEngine` based on the `useLlm` setting.
- **Windows single instance**: the runner uses the `Local\MoJiangInkSmith_SingleInstance` mutex to avoid multiple instances competing over project files.
- **Degradation paths**: AI title failure falls back to "Chapter N"; AI memory timeout continues in the background; connection timeout is 8 seconds; cancelling generation keeps the chapters already generated.
- **Local model connection**: goes through the "cloud API" provider branch with Base URL `http://127.0.0.1:19110` (llama-server) or `http://localhost:11434` (Ollama).

## Scope and limitations

- This project is the continuously-evolving successor to an MVP baseline. Template generation quality depends on the size of the built-in corpus, which can be expanded further with more genres and sentence patterns.
- InkSmith is a **writing assistant**, not an autopilot ghostwriter. The chain is "draft generation → machine gate → **human read-through review** → contract-worthiness assessment"; the author must complete their own review before publishing.
- The quality metrics are **not aligned with human evaluation** (see `docs/human-eval-workflow.md`). Until real human evaluation is added, a "passing score" only proves internal self-consistency, not reader approval.
- There is currently **no RAG or vector-retrieval long-range memory**; long-range continuity relies on the structured state ledger injected into context. At several hundred chapters this will drift, and this is the main known architectural gap.
- Tests are owned by QA; see the individual unit / widget tests.
- License: [MIT](LICENSE).

