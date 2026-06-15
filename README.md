# AMD Enterprise AI POC Operations

MI355X POC automation for the AMD Enterprise AI Reference Stack. Customer- or site-specific values belong in `scripts/.env`.

This repository is an operations workspace, not an application service. It wraps
Cluster Bloom, Cluster Forge, AIM/KServe model serving, benchmarking, and
diagnostics with Bash scripts and Kubernetes manifests.

## Documentation

| Guide | Purpose |
| :--- | :--- |
| [docs/INSTALL.md](docs/INSTALL.md) | Install AMD Enterprise AI, monitor progress, retrieve access details, and verify the cluster. |
| [docs/QUICKSTART.md](docs/QUICKSTART.md) | Run the POC workflow: validate the environment, start models, smoke-test endpoints, and capture success criteria. |
| [docs/START.md](docs/START.md) | Serve a model via the AIM operator track (`scripts/start.sh`): managed cache, routing, and lifecycle. |
| [docs/DEPLOY.md](docs/DEPLOY.md) | Serve a model via the raw AIM track (`scripts/deploy.sh`): plain Deployment + Service, no operator. |
| [docs/BENCHMARK.md](docs/BENCHMARK.md) | Run performance and accuracy benchmarks against an OpenAI-compatible endpoint. |
| [docs/DEBUG.md](docs/DEBUG.md) | Troubleshoot AIMService, cache, GPU, routing, and readiness failures. |

## Main Scripts

| Script | Purpose |
| :--- | :--- |
| `setup.sh` | Creates a local Python virtual environment and installs `requirements.txt` if present. |
| `scripts/install.sh` | Installs the platform with Bloom and deploys Cluster Forge. |
| `scripts/start.sh` | Starts one model via the AIM operator track (managed cache/routing) and prints endpoint details. |
| `scripts/deploy.sh` | Starts one model via the raw AIM track (plain Deployment + Service), auto-discovered from `deploy/`. Blocks until the endpoint serves a chat response. |
| `scripts/check.sh` | Validates the currently-served model (`/v1/models` + chat); with `--model` it ensures the model is up first. Writes a TSV summary. |
| `scripts/debug.sh` | Collects cluster, AIM, GPU, routing, portal, and endpoint diagnostics. |
| `scripts/benchmark.sh` | Runs inference-perf sweeps and lm-evaluation-harness accuracy checks. |
| `scripts/build-gpt-oss-downloader.sh` | Builds the optional GPT-OSS Hugging Face downloader image. |
| `scripts/uninstall.sh` | Removes EAI/Kubernetes artifacts from a host. Use with care. |

## Serving Tracks

There are two ways to serve a model. Both run the **same AIM container image and
vLLM engine**; they differ in the orchestration around it. Use one or the other
for a given model, not both (they contend for the same GPUs).

| Aspect | Operator track (`start.sh`) | Raw track (`deploy.sh`) |
| :--- | :--- | :--- |
| Control plane | AIM operator + KServe CRDs | None — plain `Deployment` + `Service` |
| You declare | `AIMService` / `AIMModelCache` / template | A Pod spec under `deploy/<model>/` |
| Tuning source | Template fields the operator interprets | `AIM_*` env / `AIM_PROFILE_ID` on the container |
| Model download | Operator Job → **shared** cache PVC | Each pod → **its own** PVC |
| Env control | Operator injects some env (e.g. disables Xet) | You control all env |
| Networking | Cluster gateway routing | ClusterIP + `port-forward` |
| Cluster prereqs | Full Cluster Forge stack | Just Kubernetes + GPUs |
| Add a new model | Edit manifests/templates | Drop in `deploy/<model>/` (auto-discovered) |
| Best for | Managed POC workflow, shared cache, routing | Minimal/portable serving, direct vLLM tuning, benchmarking |
| Guide | [docs/START.md](docs/START.md) | [docs/DEPLOY.md](docs/DEPLOY.md) |

## Local Setup

Run from the repository root:

```bash
./setup.sh
source .eai-rocm-venv/bin/activate  # or .eai-cpu-venv / .eai-cuda-venv
```

`setup.sh` detects `rocm-smi`, `nvidia-smi`, or CPU mode, creates a venv named
`.eai-<device>-venv`, installs `pip`, `wheel`, and `setuptools`, and installs
`requirements.txt` if the file exists. If no requirements file exists, benchmark
accuracy dependencies may still be installed lazily by `scripts/benchmark.sh`.

## Secrets And Generated Files

Do not commit runtime credentials or generated install artifacts. Keep real
values in local-only files such as `scripts/.env`, and commit only examples.

Treat these as local/generated:

- `scripts/.env`
- `*.pem`, `*.key`, `*.crt`
- `bloom.yaml`
- `bloom`, `release-enterprise-ai.tar.gz`
- `logs/`, `results/`, `.state/`
- `amd-enterprise-ai-install/`
- `.eai-*-venv/`

If any real tokens, private keys, or join commands have been shared outside this
host, rotate them before publishing or sharing the repository.

## Typical Workflow

1. Prepare host prerequisites and local config in `scripts/.env`.
2. Install the platform with `./scripts/install.sh`.
3. Validate the cluster with `./scripts/debug.sh --cluster` and `./scripts/debug.sh --gpu`.
4. Start one model with `./scripts/start.sh --model llama-3-3-70b` (operator track) or `./scripts/deploy.sh --model gpt-oss-120b` (raw track).
5. Smoke-test the served model with `./scripts/check.sh` (auto-detects what is serving).
6. Run benchmarks with `./scripts/benchmark.sh --mode perf` or `--mode all`.

See the linked docs for detailed commands, expected durations, and troubleshooting steps.
