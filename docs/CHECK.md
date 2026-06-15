# AMD Enterprise AI — Sanity Check Guide (`scripts/check.sh`)

MI355X POC | AMD Enterprise AI Reference Stack

`scripts/check.sh` is a quick **sanity check** for model serving. It confirms a model is actually
being served over the OpenAI-compatible API and exercises a real chat completion. It is the
fastest way to answer "is this model up and responding correctly?"

> [!IMPORTANT]
> **`check.sh` only inspects the model that is *currently being served* — it never deploys,
> starts, or stops anything.** It auto-detects the active endpoint, preferring the **raw
> `deploy.sh` track** (an available `<model>-aim` Deployment, reached via its Service ClusterIP)
> and falling back to the **operator `start.sh` track** (a Ready InferenceService predictor).
> Pass `--url` to target a specific endpoint and skip auto-detection.

---

## 1. What It Does

`check.sh` makes two curl calls against the served endpoint and prints their output:

| # | Step | How it is checked |
| :--- | :--- | :--- |
| 1 | **Resolve the endpoint** | Auto-detect (raw track Service ClusterIP, then operator predictor ClusterIP), or use `--url` |
| 2 | **Model listing** | `GET ${TARGET_URL}/v1/models` must respond; the served model ID is read from `.data[0].id` |
| 3 | **Chat completion** | `POST ${TARGET_URL}/v1/chat/completions` with a small prompt must succeed and return text |

It exits non-zero with a one-line error if any step fails; otherwise it prints the chat reply.

---

## 2. Running the Checks Manually

`check.sh` is just an automation of the `kubectl` and `curl` commands below. Run them by hand to
reproduce any individual step. Set the model and namespace first:

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

### Step 2 — Model listing and served model ID

```bash
curl -sf --max-time 20 "${TARGET_URL}/v1/models"

MODEL_ID=$(curl -sf --max-time 20 "${TARGET_URL}/v1/models" | jq -r '.data[0].id // empty')
echo "$MODEL_ID"
```

### Step 3 — Chat completion and response text

```bash
curl -sf --max-time 90 "${TARGET_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"${MODEL_ID}"'",
    "messages": [{"role": "user", "content": "Reply with one short sentence confirming you are ready."}],
    "max_tokens": 64,
    "temperature": 0
  }' | jq -r '.choices[0].message.content // .choices[0].text // empty'
```

> [!NOTE]
> `TARGET_URL` is the base URL only (e.g. `http://10.x.x.x:8000`). Append `/v1/...` exactly once —
> do not use a `TARGET_URL` that already ends in `/v1`, or you will hit `/v1/v1/...`.

---

## 3. Usage

```bash
# Validate whatever model is currently being served (auto-detected; no deploy)
./scripts/check.sh

# Target a specific endpoint and skip auto-detection
./scripts/check.sh --url http://localhost:8000

# Customize the prompt / namespace
./scripts/check.sh --namespace default --prompt "Say hello in French"
```

### Options

| Flag | Description | Default |
| :--- | :--- | :--- |
| `--url, --target-url URL` | Endpoint to check (skips auto-detection) | auto-detect |
| `--namespace, -n NS` | Namespace for auto-detection | `default` |
| `--model-id MODEL` | Model ID for the chat request | from `/v1/models` |
| `--prompt TEXT` | Chat prompt to send | "Reply with one short sentence confirming you are ready." |
| `--chat-timeout SEC` | curl timeout for the chat request | `90` |
| `-h, --help` | Show usage | — |

All flags have matching environment variables (`TARGET_URL`, `NAMESPACE`, `MODEL_ID`, `PROMPT`,
`CHAT_TIMEOUT`). A `scripts/.env` file is loaded automatically.

---

## 4. Expected Behavior

- **Non-destructive.** `check.sh` only inspects and exercises what is already serving — it never
  deploys, stops, or reshuffles anything.
- **Live output.** It prints `[INFO]`/`[ OK ]` lines, the resolved endpoint, the served model ID,
  the raw `/v1/models` and chat JSON (via `jq`), and the chat response text on success.
- **Exit code.** `check.sh` exits `0` only when both curl calls succeed and the chat response
  contains text; otherwise it exits non-zero with a short `[ERROR]` message. This makes it safe to
  gate automation/CI on.

---

## 5. Failure Modes & What They Mean

| Error message | Failing step | Likely cause |
| :--- | :--- | :--- |
| `No served model found in '<ns>'` | 1 — detect | Nothing is currently serving. Deploy first (`scripts/deploy.sh --model <m>`) or pass `--url` |
| `kubectl not found; pass --url ...` | 1 — detect | `kubectl` unavailable for auto-detection; supply `--url` directly |
| `/v1/models did not respond` | 2 — model listing | Endpoint resolved but the server is not serving HTTP yet (still warming up) or routing is broken |
| `Could not determine model ID from /v1/models` | 2 — model ID | Server is up but reporting no model; partial/failed model load (pass `--model-id`) |
| `/v1/chat/completions failed` | 3 — chat | Endpoint serves `/v1/models` but the inference call errored or timed out (try raising `--chat-timeout`) |
| `Chat response contained no text` | 3 — answer | Inference returned a response with no usable text content |

---

## 6. Next Steps

If the check fails, move into the diagnostic flow:

1. **Run the diagnostic tool** against the service and endpoint:

   ```bash
   ./scripts/debug.sh <model> <namespace>       # service deep-dive
   ./scripts/debug.sh --endpoint <target_url>   # probe the endpoint directly
   ./scripts/debug.sh --gpu                      # GPU allocation / oversubscription
   ./scripts/debug.sh --list                     # all services and their states
   ```

2. **Follow the state-driven troubleshooting flow** for the specific symptom — template
   mismatch on MI355X, redundant cache downloads, insufficient GPU resources, controller
   namespace detection, and first-request JIT latency are all covered in detail in
   **[DEBUG.md](DEBUG.md)**.

Common mappings from a `check.sh` failure to the relevant `DEBUG.md` section:

| `check.sh` symptom | Start here in [DEBUG.md](DEBUG.md) |
| :--- | :--- |
| No served model found / endpoint never appears | Issue 1 (template / GPU model mismatch) and Issue 3 (insufficient GPU resources) |
| Repeated cache downloads while waiting | Issue 2 (redundant downloaders & storage quota) |
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
