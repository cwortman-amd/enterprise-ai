# AMD Enterprise AI — Operator Serving Guide (`scripts/start.sh`)

MI355X POC | AMD Enterprise AI Reference Stack

`scripts/start.sh` brings up a serving endpoint through the **AIM operator** (the
managed/declarative track). You declare intent with custom resources and the
operator reconciles them into a running, cached, routed model.

> [!NOTE]
> This is the original, fully-managed path. For the lightweight, self-contained
> alternative that runs the AIM container directly, see [DEPLOY.md](DEPLOY.md).

---

## 1. What It Does

For the selected model, `start.sh`:

1. Applies the supporting `AIMClusterModel` / `AIMClusterServiceTemplate` resources.
2. Creates/refreshes the `hf-token` secret from `HF_TOKEN` (in `scripts/.env`).
3. Creates an `AIMModelCache` — the operator runs a **download Job** that
   populates a shared cache PVC (for GPT-OSS this uses the custom Xet-enabled
   downloader image).
4. Stops previously running models to free GPUs (unless `--keep-existing-models`).
5. Creates the `AIMService`; the operator produces a KServe `InferenceService`
   and predictor pod, exposed via the cluster gateway.
6. Waits for cache + predictor readiness and prints the `TARGET_URL` for
   `benchmark.sh` / `check.sh`.

```bash
./scripts/start.sh --model llama-3-3-70b
./scripts/start.sh --model gpt-oss-120b --namespace default
```

---

## 2. When To Use

- You want the **managed platform experience**: shared model cache, gateway
  routing, the model/template catalog, and operator-driven lifecycle.
- You are running the **standard POC workflow** (`install.sh` → `start.sh` →
  `check.sh` → `benchmark.sh`).
- You want a **shared cache** reused across services rather than per-pod copies.
- You rely on operator features such as `AIMClusterServiceTemplate` profiles
  (latency/throughput) and centralized routing.

## 3. When Not To Use

- The full operator stack (airm + KServe + gateway + Longhorn) is **not
  installed**, or you want to serve on a plain Kubernetes cluster.
- You need to set **exact vLLM args/env yourself** — the operator injects some
  env (e.g. it disables Xet, which required the `sitecustomize` workaround).
  Use the [raw deploy track](DEPLOY.md) for direct control.
- You want a **minimal, reproducible single-pod deployment** for tuning or
  benchmarking without the cache/routing machinery.

---

## 4. Key Options

| Flag | Purpose |
| :--- | :--- |
| `--model MODEL` | Model to start (`llama-3-3-70b`, `mixtral-8x22b`, `gpt-oss-120b`) |
| `--namespace NS` | Target namespace (default `default`) |
| `--skip-cache` | Do not create/update the `AIMModelCache` |
| `--keep-existing-models` | Do not stop other AIMServices first |
| `--wait-timeout SEC` | Max wait for readiness |

Configuration (`MODEL`, `HF_TOKEN`, `NAMESPACE`, timeouts) can live in
`scripts/.env`; CLI flags and environment variables take priority.

---

## 5. Next Steps

- Smoke-test the endpoint: `./scripts/check.sh`
- Benchmark it: `./scripts/benchmark.sh --mode all`
- If startup, cache, GPU, or routing fails: [DEBUG.md](DEBUG.md)
  (`./scripts/debug.sh --cache` for download/cache issues).

## 6. Reference

- Raw (operator-free) serving: [DEPLOY.md](DEPLOY.md)
- Track comparison matrix: repository [README.md](../README.md)
- Manifests: `scripts/poc-models.yaml`, `scripts/poc-caches.yaml`,
  `scripts/*-template*.yaml`
