# AMD Enterprise AI — Operations Lab & Solo-POC Build-Out Plan

Status: v0.1 (planning) · Scope: L2 guided operations lab + L3 solo-POC automation
Source of truth for behavior: the scripts in `scripts/` and the working manifests
(`scripts/poc-models.yaml`). This document is a build plan and curriculum outline;
no automation is implemented yet.

---

## 1. Purpose & Audiences

The repo's six scripts already implement the full operational loop. This lab layer wraps
them into guided, checkpointed, gradable experiences — it does **not** fork their logic.

| Script | Loop stage | Lab block |
| :--- | :--- | :--- |
| `install.sh` | install | Block 1 |
| `uninstall.sh` | reset | Block 2 |
| `start.sh` | start | Block 3 |
| `check.sh` | check | Block 4 |
| `benchmark.sh` | benchmark | Block 5 |
| `debug.sh` | debug | Block 6 |

- **L2 — Guided Operations Lab:** a practitioner runs each block with guardrails,
  hits verifiable checkpoints, and produces Definition-of-Done artifacts without guessing
  commands. Delivered across 2×2h sessions.
- **L3 — Solo POC:** the same person drives an end-to-end POC unattended, captures a
  shareable results bundle, and self-diagnoses failures.

The **only** runtime difference between L2 and L3 is `--guided` (pause at checkpoints) vs
`--auto` (run unattended). Same scripts, same checks.

---

## 2. Locked Decisions & Constraints

| # | Decision | Implication |
| :--- | :--- | :--- |
| 1 | Artifacts live in-repo under `lab/` and `poc/` | Versioned alongside the scripts they wrap |
| 2 | **Mixed environment** | Install/reset (Blocks 1–2) assume a **dedicated node** (destructive OK). Start/check/benchmark/debug (Blocks 3–6) assume a **shared cluster, namespace-isolated** — **never** run host/platform teardown there |
| 3 | One harness, `--guided` / `--auto` | L2 = guided, L3 = auto |
| 4 | Output: Markdown + printable PDF | Author in Markdown; export via `pandoc` (or print-to-PDF). Keep handouts ≤ 2 pages |
| 5 | **Llama-3.3-70B only** for core blocks | Fast, reliable, non-gated-by-default in this stack. GPT-OSS-120B (Xet/custom downloader) and Mixtral-8x22B (8-GPU) become **optional advanced appendices** |
| 6 | Don't modify existing `docs/` | New lab material uses the verified `spec.model.ref` schema from `scripts/poc-models.yaml`; it must not contradict the older `docs/` examples |
| 7 | Deliver this plan/curriculum doc first | Scripts built after sign-off |

> **Note on schema drift:** the existing `docs/QUICKSTART.md` and `docs/DEBUG.md` show an
> older AIMService schema (`spec.model.name` / `allowUnoptimized`). The lab uses the schema
> the scripts actually apply (`spec.cacheModel`, `spec.model.ref`, `spec.resources`). We are
> intentionally **not** reconciling the old docs in this effort.

---

## 3. Proposed Repo Layout

```text
lab/
  PLAN.md                        # this document
  README.md                      # how the lab works, prereqs, time budget, env matrix
  common/
    lab-lib.sh                   # checkpoint(), expect(), capture_artifact(), banner(), timeout_watch()
    env-check.sh                 # preflight: kubectl/jq/curl, disk (lsblk/df), GPUs, DNS/TLS
    grade.sh                     # checks Definition-of-Done artifacts per block
    metrics-glossary.md          # student fills in: "explain each metric to a PM"
  block0-orientation/   instructor.md  student.md  run.sh
  block1-install/       instructor.md  student.md  run.sh
  block2-reset/         instructor.md  student.md  run.sh
  block3-start/         instructor.md  student.md  run.sh
  block4-check/         instructor.md  student.md  run.sh
  block5-benchmark/     instructor.md  student.md  run.sh
  block6-debug/         instructor.md  student.md  run.sh
  block7-debrief/       instructor.md  student.md  collect-artifacts.sh  report-template.md
  export/
    Makefile                     # `make pdf` -> handouts/*.pdf via pandoc
poc/
  run-poc.sh                     # L3 orchestrator: env-check -> install -> start -> check -> benchmark -> bundle
  poc-config.example.env
  scenarios/
    single-model-baseline.env
    (advanced) model-switch.env
    (advanced) stress.env
  bundle.sh                      # zip results + debug snapshot + environment fingerprint
results/
  lab/<student>/<block>/...      # captured artifacts (gitignored)
  poc/<run-id>/...
```

Each block ships three files:
- **`instructor.md`** — talking points, expected timings, "break-it-on-purpose" exercises, common stumbles.
- **`student.md`** — the handout: objective, steps, exact verification command, artifact to save (≤ 2 pages).
- **`run.sh`** — guided/auto harness that calls the real script and validates checkpoints.

---

## 4. Harness Design (`lab/common/lab-lib.sh`)

A small sourced library so every block has identical ergonomics:

| Function | Purpose |
| :--- | :--- |
| `banner "<title>"` | Visual block separator |
| `checkpoint "<expected state>"` | Print expected state; pause for ENTER if `--guided`, continue if `--auto` |
| `expect "<cmd>" "<regex>" "<fail hint>"` | Run a verification (wraps the same `kubectl/jq/curl` checks in `check.sh`/`debug.sh`); clear PASS/FAIL with remediation hint |
| `capture_artifact <name> <path>` | Copy into `results/lab/<student>/<block>/` for grading + debrief |
| `timeout_watch <sec> "<no-progress hint>"` | Implements Block 1's "no log progress for N min = stuck" rule |

`run.sh` skeleton (per block):

```bash
source ../common/lab-lib.sh        # parses --guided/--auto, --student, --namespace
banner "Block N — <name>"
checkpoint "Cluster healthy; namespace <ns> exists"
../../scripts/<the-real-script>.sh <flags>     # the one and only source of truth
expect "kubectl get aimservice ... -o json | jq ..." "Ready" "See Block 6 debug flow"
capture_artifact "summary" "<file>"
```

---

## 5. Curriculum (Block-by-Block)

Each block below lists: **Objective · Env · Wraps · Steps · Verify · Artifact · Instructor notes**.
Improvements from review feedback are folded in and marked _(refinement)_.

### Block 0 — Orientation
- **Objective:** know the loop, the default lab model, and the cluster's shape.
- **Env:** any.
- **Wraps:** `lab/common/env-check.sh`.
- **Steps:** verify `kubectl/jq/curl`; node & GPU inventory; DNS/TLS reachability; _(refinement)_ **storage sanity** (`lsblk`, `df -h` on root + data NVMe).
- **Verify:** `env-check.sh` exits 0.
- **Artifact:** `env-fingerprint.txt` (ROCm version, GPU count, disk sizing).
- **Instructor notes:** state the expected sizing — **500+ GB root, 2–4 TB raw NVMe** — and which models are gated vs default.

### Block 1 — Install & Verify  *(dedicated node)*
- **Objective:** install Enterprise AI and distinguish "cluster foundation" vs "EAI components."
- **Wraps:** `install.sh` (idempotent; `.state/` skips completed phases).
- **Steps:** place `.env`; run install; watch the 6 phases; run verification.
- **Verify:** nodes Ready, GPUs allocatable, platform pods Running.
- **Artifact:** `install-verify.txt`.
- **Instructor notes:** _(refinement)_ rule of thumb — **if a single phase shows no log progress for > N min, treat as stuck and investigate** (encoded via `timeout_watch`). Foundation-vs-components framing helps debug partial installs.

### Block 2 — Uninstall / Reset Hierarchy  *(dedicated node for platform/host levels)*
- **Objective:** choose the **minimum** destructive level for a given problem.
- **Wraps:** `uninstall.sh` (+ `start.sh`'s stop-previous logic for AIM-level).
- **Reset hierarchy:** AIM → namespace → platform → host.
- **Safety rules:** PVC/PV deletion is irreversible; on shared clusters, **only AIM/namespace level is allowed**.
- **Verify:** the chosen level leaves higher levels intact.
- **Artifact:** `reset-decision.md` (which level + why).
- **Instructor notes:** _(refinement)_ concrete decision — *"model misbehaving but platform healthy → AIM-level cleanup only, do NOT reinstall EAI."*

### Block 3 — Start an AIM  *(shared cluster, namespace-isolated)*
- **Objective:** bring a model to a serving endpoint and read the lifecycle.
- **Wraps:** `start.sh --model llama-3-3-70b --namespace <ns>`.
- **Lifecycle:** model/cache requested → cache ready → AIMService → InferenceService → predictor pod → endpoint available.
- **Verify:** `aimservices`, `aimmodelcaches`, `inferenceservice`, `pods` reach expected states; `TARGET_URL`/`MODEL_ID` emitted.
- **Artifact:** `start-output.txt` (the `TARGET_URL` / `MODEL_ID` contract consumed by Blocks 4–5).
- **Instructor notes:** cold vs warm cache timing; gated-token failure mode (advanced); template-mismatch on preview hardware (advanced). Mirror the lifecycle on the AIM deck slide.

### Block 4 — Check AIM Health  *(shared cluster)*
- **Objective:** compose a **repeatable health checklist**.
- **Wraps:** `check.sh --model llama-3-3-70b`.
- **Checklist:** resource → pod → logs → endpoint → smoke test → metrics.
- **Verify:** `/v1/models` returns an id; smoke chat/completion returns text. _(refinement)_ guard: **don't append `/v1` twice**.
- **Artifact:** `check.latest.summary.tsv` + the filled `health-checklist.md`.
- **Instructor notes:** this is the model for the `grade.sh` rubric (Objective 4).

### Block 5 — Use & Benchmark  *(shared cluster)*
- **Objective:** run a production-style profile and explain the metrics.
- **Wraps:** `benchmark.sh --mode perf|accuracy|all`.
- **Stages:** Smoke → Baseline → Throughput → (optional) Stress.
- **Metrics:** TTFT, ITL/TPOT, e2e latency, tokens/sec, requests/sec, concurrency, warmup.
- **Verify:** sweep results + summary written.
- **Artifact:** _(refinement)_ benchmark JSON/CSV **plus `environment.json`** (model, image tags, ROCm, GPU count) saved together via `capture_artifact`.
- **Instructor notes:** require students to fill `metrics-glossary.md` ("explain each to a PM" = Objective 5 bar).

### Block 6 — Troubleshooting & Debug  *(shared cluster, mostly read-only)*
- **Objective:** drive a **state-driven** flow without guessing commands.
- **Wraps:** `debug.sh <service> [ns]`, `--list`, `--gpu`, `--cluster`, `--portal`, `--endpoint`, `--all`.
- **State vocabulary:** Pending / Starting / Running-not-Ready / Ready / Failed.
- **Scenarios (taught by perturbing the Block 3/4 baseline):** registry auth, gated token, disk pressure, GPU oversubscription, template mismatch, warmup latency, routing, API schema errors.
- **Verify:** student reaches root cause + remediation.
- **Artifact:** `debug-runbook.md` (which `debug.sh` modes were used, in order) = evidence of Objective 6 "without guessing."
- **Instructor notes:** highest teaching value; intentionally sequenced **after** a known-good baseline exists.

### Block 7 — Debrief & Handoff
- **Objective:** consolidate artifacts; restate the loop.
- **Wraps:** `collect-artifacts.sh` → `report-template.md`.
- **Artifact:** one bundle per student; homework reinforcing the loop.

---

## 6. L3 Solo-POC Layer (`poc/`)

`run-poc.sh` chains the existing scripts non-interactively with gates between stages:

```text
env-check.sh
  -> install.sh                        (idempotent; skipped on shared clusters)
  -> start.sh --model <M> --namespace <ns>
  -> check.sh                          (GATE: must PASS or abort)
  -> benchmark.sh --mode all
  -> bundle.sh                         (results + `debug.sh --all` snapshot + environment.json)
```

- **Scenarios** are parameter files: `single-model-baseline` (core, Llama only);
  `model-switch` and `stress` are advanced (exercise `start.sh` stop-previous + multi-GPU).
- **Teardown** maps to the Block 2 hierarchy: `run-poc.sh --teardown {aim|namespace|platform|host}`
  (platform/host refused unless `--dedicated-node` is asserted).
- **Output:** a self-contained `results/poc/<run-id>/` bundle suitable for customer handoff.

---

## 7. Definition of Done / Grading (`grade.sh`)

Automated, artifact-based, mapped to objectives:

| Objective | Pass condition (checked from `results/`) |
| :--- | :--- |
| O1 install | `install-verify.txt` shows Ready nodes + allocatable GPUs |
| O2 reset | `reset-decision.md` selects the minimal correct level |
| O3 start | `start-output.txt` contains a valid `TARGET_URL` + `MODEL_ID` |
| O4 check | `health-checklist.md` complete **and** re-running `check.sh` PASSes |
| O5 benchmark | sweep results + `environment.json` present; glossary filled |
| O6 debug | `debug-runbook.md` lists the `debug.sh` modes used to reach root cause |

L2 is self-graded with the harness; instructor spot-checks the bundle.

---

## 8. Output / Export

- Author everything in Markdown.
- `lab/export/Makefile`: `make pdf` renders each `student.md` to a 1–2 page handout via
  `pandoc` (fallback: browser print-to-PDF). Instructor guides stay Markdown-only.

---

## 9. Phasing & Milestones

1. **Foundation** — `lab/common/` (`lab-lib.sh`, `env-check.sh`, `grade.sh`) + `lab/README.md` + env matrix.
2. **Reference prototype** — **Block 3 + Block 4** (instructor.md, student.md, run.sh, grade checks). Locks the format and the `TARGET_URL`/`MODEL_ID` contract.
3. **Debug** — Block 6 (built on the Block 3/4 baseline), then **Benchmark** — Block 5.
4. **Bookends** — Blocks 0, 1, 2, 7.
5. **L3** — `poc/run-poc.sh` + `single-model-baseline` scenario + `bundle.sh`.
6. **Polish** — PDF export, full 2×2h dry-run, timing tuning, advanced appendices (GPT-OSS, Mixtral).

---

## 10. Open Items / Risks

- **Shared-cluster namespacing:** confirm the convention (per-student namespace name, quota) before Blocks 3–6.
- **`check.sh`/`start.sh` namespace flag coverage** must be verified for non-`default` namespaces during prototyping.
- **Llama gating:** confirm whether the lab's Llama variant needs an `HF_TOKEN` in the target environment, or is served from a warm cache.
- **PDF toolchain:** confirm `pandoc` availability on the authoring machine, else use print-to-PDF.
- **Advanced appendices** (GPT-OSS Xet downloader, Mixtral 8-GPU) are out of the core path but documented for L3.
```
