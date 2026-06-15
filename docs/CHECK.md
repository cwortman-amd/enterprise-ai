# AMD Enterprise AI — Sanity Check Guide (`scripts/check.sh`)

MI355X POC | AMD Enterprise AI Reference Stack

`scripts/check.sh` is an end-to-end **sanity check** for model serving. It confirms a model is
actually being served over the OpenAI-compatible API and exercises a real chat completion. It is
the fastest way to answer "is this model up and responding correctly?" and to produce a
reproducible PASS/FAIL record.

> [!IMPORTANT]
> **By default, `check.sh` validates the model that is *currently being served* — it does not
> deploy anything.** It auto-detects the active endpoint, preferring the **raw `deploy.sh`
> track** (an available `<model>-aim` Deployment, reached via its Service ClusterIP) and falling
> back to the **operator `start.sh` track** (a Ready InferenceService predictor).
>
> Only when you pass `--model`/`--models` does `check.sh` *ensure* a model is up first — and even
> then it prefers `deploy.sh` (raw track), falling back to `start.sh` (operator) only when the
> model has no `deploy/<model>/` manifest.

---

## 1. What It Does

`check.sh` runs in one of two modes:

**Default mode (no `--model`/`--models`)** — discover and validate the served model(s):

| # | Step | How it is checked |
| :--- | :--- | :--- |
| 1 | **Detect served models** | Available `<model>-aim` Deployments (raw track), then Ready InferenceServices (operator track) |
| 2 | **Resolve the endpoint** | Service ClusterIP for the raw track, predictor ClusterIP for the operator track |
| 3 | **Model listing** | `GET ${TARGET_URL}/v1/models` must respond |
| 4 | **Served model ID** | The response must contain `.data[0].id` |
| 5 | **Chat completion** | `POST ${TARGET_URL}/v1/chat/completions` with a small prompt must succeed |
| 6 | **Non-empty answer** | The response must contain assistant text (`.choices[0].message.content` or `.choices[0].text`) |

**Ensure mode (`--model`/`--models`)** — same validation, with an extra first step that brings
the model up if it is not already served: `deploy.sh --model <m>` when a `deploy/<m>/` manifest
exists, otherwise `start.sh --model <m>`.

Each model that passes all validation steps is recorded as **PASS**; any failure is recorded as
**FAIL** with a short note describing which step failed.

---

## 2. Running the Checks Manually

`check.sh` is just an automation of the `kubectl` and `curl` commands below. Run them by hand
to reproduce any individual step. Set the model and namespace first:

```bash
MODEL=gpt-oss-120b
NS=default
```

### Step 1 — Resolve the served endpoint

`check.sh` prefers the raw `deploy.sh` track, then falls back to the operator track:

```bash
# Raw deploy.sh track: Service ClusterIP of an available "<model>-aim" Deployment
if [[ "$(kubectl get deploy "${MODEL}-aim" -n "$NS" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" -ge 1 ]]; then
  IP=$(kubectl get svc "${MODEL}-aim" -n "$NS" -o jsonpath='{.spec.clusterIP}')
  PORT=$(kubectl get svc "${MODEL}-aim" -n "$NS" -o jsonpath='{.spec.ports[0].port}')
  TARGET_URL="http://${IP}:${PORT}"
else
  # Operator start.sh track: predictor ClusterIP of a Ready InferenceService
  ISVC=$(kubectl get inferenceservice -n "$NS" -o json \
    | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True")) | .metadata.name' \
    | head -1)
  IP=$(kubectl get svc "${ISVC}-predictor" -n "$NS" -o jsonpath='{.spec.clusterIP}')
  TARGET_URL="http://${IP}"
fi
```

### Step 1b — (ensure mode only) bring the model up

Only when you explicitly request a model. Prefer the raw track; fall back to the operator track:

```bash
if [[ -f "deploy/${MODEL}/deployment.yaml" ]]; then
  ./scripts/deploy.sh --model "$MODEL" --namespace "$NS"   # raw track (preferred)
else
  ./scripts/start.sh  --model "$MODEL" --namespace "$NS"   # operator track (fallback)
fi
```

### Step 2 — AIMService state (used to explain an ensure failure)

```bash
kubectl get aimservice "$MODEL" -n "$NS" -o json \
  | jq -r '.status.status // .status.state // "unknown"'
```

### Step 3 — Model listing

```bash
curl -sf --max-time 20 "${TARGET_URL}/v1/models"
```

### Step 4 — Extract the served model ID

```bash
MODEL_ID=$(curl -sf --max-time 20 "${TARGET_URL}/v1/models" | jq -r '.data[0].id // empty')
echo "$MODEL_ID"
```

### Steps 5 & 6 — Chat completion and response text

```bash
curl -sf --max-time 90 "${TARGET_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"${MODEL_ID}"'",
    "messages": [{"role": "user", "content": "Reply with one short sentence confirming the model is ready."}],
    "max_tokens": 64,
    "temperature": 0
  }' | jq -r '.choices[0].message.content // .choices[0].text // empty'
```

> [!NOTE]
> `TARGET_URL` is the base URL only (e.g. `http://10.x.x.x`). Append `/v1/...` exactly once —
> do not use a `TARGET_URL` that already ends in `/v1`, or you will hit `/v1/v1/...`.

---

## 3. Usage

```bash
# Validate whatever model is currently being served (auto-detected; no deploy)
./scripts/check.sh

# Ensure a single model is up (deploy.sh preferred, start.sh fallback) and check it
./scripts/check.sh --model gpt-oss-120b

# Ensure + check a specific subset
./scripts/check.sh --models llama-3-3-70b,gpt-oss-120b

# Stop at the first failing model instead of continuing
./scripts/check.sh --stop-on-fail
```

### Options

| Flag | Description | Default |
| :--- | :--- | :--- |
| `--model MODEL` | Single model to ensure + check (alias for `--models MODEL`) | — |
| `--models CSV` | Comma-separated model list to ensure + check | auto-detect the served model |
| `--namespace, -n NS` | Kubernetes namespace | `default` |
| `--output-dir DIR` | Directory for logs and summary | `results/eai-check` |
| `--prompt TEXT` | Chat prompt sent to each model | "Reply with one short sentence confirming the model is ready." |
| `--chat-timeout SEC` | curl timeout for the chat request | `90` |
| `--stop-on-fail` | Stop after the first failed model | off |
| `--keep-existing-models` | Pass through to `deploy.sh`/`start.sh` (do not stop other models first) | off |
| `-h, --help` | Show usage | — |

All flags have matching environment variables (`MODELS`, `NAMESPACE`, `OUTPUT_DIR`,
`CHAT_TIMEOUT`, `PROMPT`, `STOP_ON_FAIL`, `KEEP_EXISTING_MODELS`). Setting `MODELS` is treated as
an explicit selection (ensure mode). A `scripts/.env` file is loaded automatically, and
`HF_TOKEN` / `HUGGING_FACE_HUB_TOKEN` are read by `deploy.sh`/`start.sh` when a gated model needs
to be downloaded.

> [!NOTE]
> Default mode never deploys and never stops a running model — it only inspects and exercises
> what is already serving. Bringing a model up (and the GPU contention that implies) only happens
> in ensure mode, when you pass `--model`/`--models`.

---

## 4. Expected Behavior

- **Non-destructive by default.** In default mode `check.sh` only validates the model already
  being served; it never deploys, stops, or reshuffles anything.
- **Ensure mode brings models up.** With `--model`/`--models`, each model is brought up (raw
  `deploy.sh` preferred, operator `start.sh` fallback) if not already served, then validated.
- **Live progress.** Each model prints `[INFO]`/`[ OK ]`/`[FAIL]` lines; the served model ID
  and a snippet of the chat response are echoed on success.
- **Summary table.** At the end, a table is printed with one row per model:

  ```text
  model           status  target_url            served_model_id   elapsed_seconds  note
  gpt-oss-120b    PASS    http://10.x.x.x:8000  openai/gpt-oss...  18               chat response received
  ```

- **Exit code.** `check.sh` exits non-zero if **any** model failed, and exits `0` only when
  every selected model passed. This makes it safe to gate automation/CI on.

### Output Artifacts

All written under the output directory (default `results/eai-check/`):

| File | Contents |
| :--- | :--- |
| `check.<timestamp>.summary.tsv` | Tab-separated results for this run |
| `check.latest.summary.tsv` | Copy of the most recent run's summary |
| `<model>.start.log` | Full `start.sh` output for that model |
| `<model>.models.json` | Raw `/v1/models` response |
| `<model>.chat.json` | Raw `/v1/chat/completions` response |

---

## 5. Failure Modes & What They Mean

The `note` column tells you exactly where the sequence stopped:

| Note | Failing step | Likely cause |
| :--- | :--- | :--- |
| `No served model found ...` (default mode aborts) | 1 — detect | Nothing is currently serving. Deploy first (`scripts/deploy.sh --model <m>`) or pass `--model` |
| `ensure failed; AIMService status=<state>` | 1b — ensure | `deploy.sh`/`start.sh` could not bring the model to a ready endpoint. The `<state>` (e.g. `Pending`, `Failed`) is the key clue |
| `model is not served (no available deploy.sh Deployment or Ready InferenceService)` | 2 — endpoint | The model came up but no reachable Deployment/InferenceService endpoint resolved; usually a readiness or routing problem |
| `/v1/models did not respond` | 3 — model listing | Endpoint resolved but the server is not serving HTTP yet (still warming up) or routing is broken |
| `/v1/models responded but no model ID was found` | 4 — model ID | Server is up but reporting no model; partial/failed model load |
| `/v1/chat/completions failed` | 5 — chat | Endpoint serves `/v1/models` but the inference call errored or timed out (try raising `--chat-timeout`) |
| `chat response returned no text` | 6 — answer | Inference returned a response with no usable text content |

---

## 6. Next Steps

If a model fails, reproduce the failing step manually and then move into the diagnostic flow.

1. **Inspect the captured artifacts** for the failing model:

   ```bash
   cat results/eai-check/<model>.start.log      # full start.sh output
   cat results/eai-check/<model>.models.json    # what /v1/models returned
   cat results/eai-check/<model>.chat.json      # what the chat call returned
   ```

2. **Run the diagnostic tool** against the service and endpoint:

   ```bash
   ./scripts/debug.sh <model> <namespace>       # service deep-dive
   ./scripts/debug.sh --endpoint <target_url>   # probe the endpoint directly
   ./scripts/debug.sh --gpu                      # GPU allocation / oversubscription
   ./scripts/debug.sh --list                     # all services and their states
   ```

3. **Follow the state-driven troubleshooting flow** for the specific symptom — template
   mismatch on MI355X, redundant cache downloads, insufficient GPU resources, controller
   namespace detection, and first-request JIT latency are all covered in detail in
   **[DEBUG.md](DEBUG.md)**.

Common mappings from a `check.sh` failure to the relevant `DEBUG.md` section:

| `check.sh` symptom | Start here in [DEBUG.md](DEBUG.md) |
| :--- | :--- |
| `ensure failed` with AIMService stuck `Pending` | Issue 1 (template / GPU model mismatch) and Issue 3 (insufficient GPU resources) |
| Endpoint never appears, repeated cache downloads | Issue 2 (redundant downloaders & storage quota) |
| `debug.sh` reports controller/namespace errors | Issue 4 (namespace & controller label auto-detection) |
| First chat call is slow but later ones are fast | Section 3 (first-request latency & JIT compilation) |

---

## 7. Further Reading

| Document | Purpose |
| :--- | :--- |
| [INSTALL.md](INSTALL.md) | Install and verify the platform |
| [QUICKSTART.md](QUICKSTART.md) | Start models and run the POC workloads |
| [BENCHMARK.md](BENCHMARK.md) | Performance sweep and accuracy evaluation |
| [DEBUG.md](DEBUG.md) | Detailed troubleshooting and diagnostics |
