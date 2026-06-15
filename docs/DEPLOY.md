# AMD Enterprise AI — Raw Serving Guide (`scripts/deploy.sh`)

MI355X POC | AMD Enterprise AI Reference Stack

`scripts/deploy.sh` brings up a serving endpoint by running the **AIM container
image directly** as a plain Kubernetes `Deployment` + `Service` — no AIM
operator, no custom resources. It follows AMD's official AIM container
deployment guides.

> [!NOTE]
> This is the lightweight, self-contained track. For the fully-managed operator
> experience (shared cache, gateway routing, template catalog), see
> [START.md](START.md).

---

## 1. What It Does

Models are **auto-discovered** from the `deploy/` directory. Any subdirectory
containing a `deployment.yaml` is a deployable model:

```
deploy/<model>/deployment.yaml         # required: Deployment [+ model-cache PVC]
deploy/<model>/service.yaml            # required: ClusterIP Service (80 -> 8000)
deploy/<model>/profile-configmap.yaml  # optional: AIM custom profile (tuning)
```

For the selected model, `deploy.sh`:

1. Ensures the `hf-token` secret (only if the manifests reference it and
   `HF_TOKEN` is set).
2. Stops other running models to free GPUs unless `--keep-existing`:
   - other **raw-track** models (Deployment + Service; model-cache PVCs are kept), and
   - **operator-track** `AIMService`s (cascades to their `InferenceService` +
     predictor pods; `AIMModelCache` PVCs are kept).

   It then waits (up to `--stop-timeout`, default 300s) for those pods to
   actually release their GPUs before applying, so the new pod doesn't silently
   land in `Pending` with `Insufficient amd.com/gpu`.
3. Applies `deploy/<model>/` — the AIM container selects its serving profile
   from `AIM_*` env / `AIM_PROFILE_ID` and launches vLLM internally.
4. Waits for rollout and prints the port-forward + API access details.

Each pod downloads weights into **its own PVC** (there is no shared
`AIMModelCache`).

```bash
./scripts/deploy.sh --list
./scripts/deploy.sh --model gpt-oss-120b
./scripts/deploy.sh --model llama-3-3-70b --delete    # tear down (keeps PVC)
```

---

## 2. When To Use

- You want a **minimal, self-contained deployment** with few moving parts, or
  to serve on a **plain Kubernetes cluster** without the operator stack.
- You need **direct control over vLLM tuning** — set engine args and env via an
  AIM custom profile (e.g. the GPT-OSS MI355x profile: TP8, AITER unified
  attention, QuickReduce INT4, block-size 64).
- You want a **reproducible, directly-tuned endpoint** for benchmarking or
  A/B comparison against the operator path.
- You are following AMD's published AIM container deployment guides.

## 3. When Not To Use

- You want the **managed platform features**: a shared model cache reused across
  services, gateway routing, the model/template catalog, or operator lifecycle
  management — use [START.md](START.md) instead.
- You are running the **standard POC workflow**, which is wired around
  `start.sh`. (`check.sh` validates whichever track is actually serving — it
  prefers this raw `deploy.sh` track and uses the operator `start.sh` track as a
  fallback.)
- You need **multiple models sharing one cached copy** of weights — the raw
  track downloads per-pod into separate PVCs.

> [!WARNING]
> Run the operator track **or** the raw track for a given model, not both — they
> would contend for the same GPUs.

---

## 4. Key Options

| Flag | Purpose |
| :--- | :--- |
| `--list` | List auto-discovered models |
| `--model MODEL` | Deploy a model (a directory under `deploy/`) |
| `--namespace NS` | Target namespace (default `default`) |
| `--keep-existing` | Do not stop other deploy-track models first |
| `--skip-secret` | Do not create/update the `hf-token` secret |
| `--no-wait` | Apply without waiting for rollout (also skips serving verification) |
| `--no-verify` | Skip the post-rollout `/v1/models` + chat sanity check |
| `--verify-timeout SEC` | Max seconds to wait for the endpoint to serve (default `600`) |
| `--delete` / `--purge` | Tear down the model; `--purge` also deletes the cache PVC |

> [!NOTE]
> By default `deploy.sh` does **not** finish until the model is genuinely usable: after the
> rollout it resolves the Service ClusterIP, waits for `/v1/models` to report a model, and sends
> a chat request (falling back to `/v1/completions`) that must return non-empty text. If that
> chat never succeeds, `deploy.sh` exits non-zero. Use `--no-verify` to skip this (e.g. when
> cluster IPs are not routable from where you run the script).

---

## 5. Adding A New Model

Because models are auto-discovered, no script changes are needed:

1. Create `deploy/<new-model>/` with `deployment.yaml` and `service.yaml`
   (copy an existing model dir as a template).
2. Set the AIM image, `AIM_GPU_COUNT`, `amd.com/gpu`, and a model-cache PVC.
3. Optionally add `profile-configmap.yaml` and pin it via `AIM_PROFILE_ID`.
4. `./scripts/deploy.sh --list` should now show it; deploy with
   `./scripts/deploy.sh --model <new-model>`.

Inspect what tuned profiles an image ships before writing a custom one:

```bash
docker run --rm amdenterpriseai/aim-openai-gpt-oss-120b:0.11.1 list-profiles
docker run --rm -e AIM_GPU_MODEL=MI355X -e AIM_GPU_COUNT=8 \
  amdenterpriseai/aim-openai-gpt-oss-120b:0.11.1 dry-run
```

---

## 6. Next Steps

- Reach the endpoint: `kubectl port-forward service/<model>-aim 8000:80 -n default`
- Benchmark it (manual forward): `./scripts/benchmark.sh --mode all --target-url http://localhost:8000`
- Benchmark it (auto forward + cleanup): `./scripts/benchmark.sh --mode all --port-forward <model>-aim`
  - This starts the port-forward, waits until `/v1/models` is ready, runs the
    benchmark against `localhost`, and tears the forward down on exit.
  - Use `--namespace` / `--local-port` to override the defaults
    (`default` / `8000`).
- Inspect rollout/pods if it does not become ready:
  `kubectl get pods -l app=<model>-aim` and `kubectl logs ...`.

## 7. Reference

- Manifest layout and per-model details: [`deploy/README.md`](../deploy/README.md)
- Operator-managed alternative: [START.md](START.md)
- Track comparison matrix: repository [README.md](../README.md)
