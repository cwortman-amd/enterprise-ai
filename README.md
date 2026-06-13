# AMD Enterprise AI POC Operations

BNY MI355X POC automation for the AMD Enterprise AI Reference Stack.

This repository is an operations workspace, not an application service. It wraps
Cluster Bloom, Cluster Forge, AIM/KServe model serving, benchmarking, and
diagnostics with Bash scripts and Kubernetes manifests.

## Documentation

| Guide | Purpose |
| :--- | :--- |
| [docs/INSTALL.md](docs/INSTALL.md) | Install AMD Enterprise AI, monitor progress, retrieve access details, and verify the cluster. |
| [docs/QUICKSTART.md](docs/QUICKSTART.md) | Run the POC workflow: validate the environment, start models, smoke-test endpoints, and capture success criteria. |
| [docs/BENCHMARK.md](docs/BENCHMARK.md) | Run performance and accuracy benchmarks against an OpenAI-compatible endpoint. |
| [docs/DEBUG.md](docs/DEBUG.md) | Troubleshoot AIMService, cache, GPU, routing, and readiness failures. |

## Main Scripts

| Script | Purpose |
| :--- | :--- |
| `setup.sh` | Creates a local Python virtual environment and installs `requirements.txt` if present. |
| `scripts/install.sh` | Installs the platform with Bloom and deploys Cluster Forge. |
| `scripts/start.sh` | Starts one benchmark model at a time and prints endpoint details. |
| `scripts/check.sh` | Runs model startup and chat sanity checks, writing TSV summaries. |
| `scripts/debug.sh` | Collects cluster, AIM, GPU, routing, portal, and endpoint diagnostics. |
| `scripts/benchmark.sh` | Runs inference-perf sweeps and lm-evaluation-harness accuracy checks. |
| `scripts/build-gpt-oss-downloader.sh` | Builds the optional GPT-OSS Hugging Face downloader image. |
| `scripts/uninstall.sh` | Removes EAI/Kubernetes artifacts from a host. Use with care. |

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
4. Start one model with `./scripts/start.sh --model llama-3-3-70b`.
5. Smoke-test all target models with `./scripts/check.sh`.
6. Run benchmarks with `./scripts/benchmark.sh --mode perf` or `--mode all`.

See the linked docs for detailed commands, expected durations, and troubleshooting steps.
