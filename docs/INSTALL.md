# AMD Enterprise AI — Installation Guide

MI355X POC | AMD Enterprise AI Reference Stack

This guide is a complete operator-friendly walkthrough for installing the AMD Enterprise AI Reference Stack. It is based on the [official documentation](https://enterprise-ai.docs.amd.com/en/latest/platform-infrastructure/on-premises-installation.html) and automated via the `scripts/install.sh` script.

> [!IMPORTANT]
> **ROCm Version:** ROCm **7.0.2** is required. ROCm 7.2.x is **not supported**. Do not upgrade ROCm independently.

> [!WARNING]
> Keep runtime secrets and generated install artifacts out of git. Files such as `scripts/.env`, `bloom.yaml`, TLS private keys, logs, results, virtualenvs, and `amd-enterprise-ai-install/` are local-only operational state.

---

## 1. Prerequisites

### Hardware

| Component | Minimum | This POC |
| :--- | :--- | :--- |
| GPU | MI300X / MI325X / MI350X / MI355X | 8x MI355X |
| CPU | 20 cores | 2x AMD Turin |
| Storage | 1 unformatted drive (raw NVMe), 2-4 TB | Auto-detected |

> [!NOTE]
> MI355X is next-generation hardware. AIM Engine templates are currently optimized for MI300X only. Models must be deployed with `allowUnoptimized: true`. See [QUICKSTART.md](QUICKSTART.md).

### OS & Access

- Ubuntu 22.04 LTS or 24.04 LTS with `sudo` privileges
- Internet access from the node (Docker Hub, GitHub, AMD registries)
- Required host tools: `bash`, `curl`, `tar`, `python3`, `python3-venv`, and `jq`

### Local Repository Setup

Run the helper once from the repository root if you plan to use the Python-backed benchmark or utility flows:

```bash
./setup.sh
source .eai-rocm-venv/bin/activate  # or .eai-cpu-venv / .eai-cuda-venv
```

`setup.sh` detects the local accelerator type, creates a `.eai-<device>-venv`, installs base Python packaging tools, and installs `requirements.txt` if present. If no requirements file exists, `scripts/benchmark.sh` can still install `lm_eval[vllm,api]` lazily for accuracy runs.

### Disk

The Bloom installer provisions Longhorn storage on a raw NVMe drive.

- `scripts/install.sh` auto-detects the first unmounted NVMe device.
- Override: set `DISK_OVERRIDE=/dev/nvmeXn1` in `.env`.
- **Warning:** The selected disk will be wiped. Verify first with `lsblk`.

### Docker Hub Credentials

Without authentication, Docker Hub rate limits cause `ImagePullBackOff` errors.

Create a `.env` file in the `scripts/` directory:

```env
# Required for install (avoids Docker Hub rate limits / ImagePullBackOff)
DOCKERHUB_USER=your_dockerhub_username
DOCKERHUB_TOKEN=your_dockerhub_pat

# Required to download gated/hosted models when serving (start.sh / check.sh)
HF_TOKEN=hf_your_token
# HUGGING_FACE_HUB_TOKEN=hf_your_token   # alternative variable name; either is accepted

# Optional overrides
# DISK_OVERRIDE=/dev/nvme1n1
# IP_OVERRIDE=10.0.0.100
# DOMAIN_OVERRIDE=my-custom.domain.com
# BLOOM_VERSION=v1.2.2
# FORGE_VERSION=v1.5.2
# FORCE_REDEPLOY=true
```

Do not commit `scripts/.env`. If you need a shareable template, create an example file with placeholder values only.

### Hugging Face Token

Required to download gated or hosted models (e.g., Llama 3.3 70B, Mixtral, GPT-OSS) when serving them with `scripts/start.sh` or `scripts/check.sh`.

- Generate a **read** token at <https://huggingface.co/settings/tokens> and accept each model's license on its Hugging Face page.
- `scripts/start.sh` reads `HF_TOKEN` (or `HUGGING_FACE_HUB_TOKEN`) and validates access **before** starting a download, so an invalid or missing token fails fast.
- Provide it in either of these ways:
  - Add `HF_TOKEN=hf_...` to `scripts/.env` (loaded automatically by the scripts), or export it in your shell.
  - Add it via the **AI Workbench UI → Secrets** (key `HUGGING_FACE_HUB_TOKEN`) for UI-driven deployments.

> [!NOTE]
> A Hugging Face token is **not** required to install the platform itself — only to download gated/hosted model weights. You can add it during install (in `scripts/.env`) or later before the first model start.

---

## 2. Running the Installation

The script is **idempotent** — re-running it safely skips completed phases via state files in `amd-enterprise-ai-install/.state/`.

Run from the repository root unless you intentionally set `WORKDIR`. By default, `scripts/install.sh` writes its install workspace to `$PWD/amd-enterprise-ai-install`, so running it from different directories creates different workspaces.

```bash
# Place .env file first, then run:
./scripts/install.sh

# Force a full re-run after a failed install:
FORCE_REDEPLOY=true ./scripts/install.sh

# Use a specific generated workspace:
WORKDIR="$PWD/amd-enterprise-ai-install" ./scripts/install.sh
```

### Phase Overview

| Phase | Component | What Happens |
| :--- | :--- | :--- |
| 1 | Pre-flight | Logs system state, detects IP and disk |
| 2 | Bloom Download | Fetches `bloom` binary from GitHub |
| 3 | Forge Download | Downloads `release-enterprise-ai.tar.gz` |
| 4 | `bloom.yaml` | Generates config (domain, disk, Docker Hub creds) |
| 5 | Cluster-Bloom | Installs RKE2, ROCm 7.0.2, MetalLB, Longhorn |
| 6 | Cluster-Forge | Deploys ArgoCD, OpenBao, Gitea |
| 7 | Verification | Runs `kubectl` health checks |

> [!NOTE]
> First-run install typically takes **30–60 minutes** due to container image downloads.

### Expected Script Durations

Use these ranges to decide whether a script is making normal progress or needs investigation. Times vary with network speed, image cache state, Hugging Face access, and whether the model cache is already warm.

| Script / Step | Typical Duration | What You Should See |
| :--- | :--- | :--- |
| `scripts/install.sh` first run | 30-60 minutes | Bloom and Forge logs advance, cluster pods move toward `Running` |
| `scripts/install.sh` rerun | 1-10 minutes | Completed phases are skipped from `.state/` files |
| `FORCE_REDEPLOY=true scripts/install.sh` | 30-90 minutes | Full reinstall path; expect image downloads and component reconciliation |
| `scripts/start.sh` with cached model | 5-20 minutes | Previous model stops, cache is reported ready, predictor pod starts, readiness probes eventually pass |
| `scripts/start.sh` with new model download | 15-60+ minutes | Hugging Face token is validated first, then an `AIMModelCache` download job runs |
| Large model switch, for example Llama to Mixtral | 10-30 minutes after cache is warm | Old predictor pod terminates, GPUs free up, new predictor schedules and initializes |
| `scripts/debug.sh` service check | 10-60 seconds | Prints AIMService, InferenceService, pod, cache, routing, and event diagnostics |
| `scripts/benchmark.sh --mode perf` | 30-180+ minutes | Warmup runs first, then each use case/concurrency stage writes results |
| `scripts/benchmark.sh --mode accuracy` | 30-90+ minutes | `lm_eval` runs MMLU/GSM8K and writes accuracy outputs |

If a model-serving pod is `Pending` for more than a few minutes, check GPU availability with `kubectl describe pod <pod> -n default`. If it is `Running` but not ready, tail the predictor logs; large models can spend several minutes loading weights and initializing kernels.

---

## 3. Monitoring Progress

```bash
# Bloom (K8s/ROCm setup)
tail -f amd-enterprise-ai-install/logs/bloom-install.log

# Forge (ArgoCD/GitOps)
tail -f amd-enterprise-ai-install/logs/deploy.log

# Live cluster status (once kubectl is ready)
watch -n 5 'kubectl get pods -A | grep -v Completed'

# Verify GPU detection
kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name): \(.status.allocatable["amd.com/gpu"]) GPU(s)"'
```

---

## 4. Post-Installation Access

| Interface | URL | Purpose |
| :--- | :--- | :--- |
| AMD Resource Manager | `https://airmui.<ip>.nip.io` | GPU quota, users, cluster |
| AMD AI Workbench | `https://aiwbui.<ip>.nip.io` | Models, inference, training |
| ArgoCD | `https://argocd.<ip>.nip.io` | GitOps status |
| Gitea | `https://gitea.<ip>.nip.io` | Internal Git |

**Default login:** `devuser@<ip>.nip.io` / `password` *(forced change on first login)*

### Retrieve Backend Credentials

```bash
# ArgoCD admin password
kubectl get secret -n argocd argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

# OpenBao (Vault) root token
kubectl get secret -n cf-openbao openbao-init \
  -o jsonpath='{.data.root_token}' | base64 -d; echo

# Gitea admin password
kubectl get secret -n cf-gitea gitea-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

### Adding a Hugging Face Token

Required for gated models (Llama, Gemma, etc.):

1. Log in to AI Workbench (`aiwbui.*`)
2. Navigate to **Secrets**
3. Add key `HUGGING_FACE_HUB_TOKEN` with your token value

---

## 5. Deploying Models

> [!IMPORTANT]
> On MI355X clusters, use this repository's `scripts/start.sh` flow for normal POC runs. It applies custom MI355X `AIMClusterServiceTemplate` resources from `scripts/custom-templates.yaml` before creating `AIMService` resources. If you create ad hoc AIMService manifests outside that flow and do not provide MI355X templates, include `allowUnoptimized: true` or the service may remain stuck in **Pending**.

See **[QUICKSTART.md](QUICKSTART.md)** for complete deployment manifests for all POC benchmark models.

---

## 6. Debugging and Verification

For a comprehensive, step-by-step debug flow covering GPU template mismatch, redundant cache downloads, resource limitations, and JIT compilation, see the **[Detailed Troubleshooting Guide](DEBUG.md)**.

### Cluster Health Checks

```bash
kubectl get nodes -o wide
kubectl get pods -A | grep -Ev "Completed|Running"
kubectl get gateway -A
kubectl get httproute -A
```

### AIM Service Debugging

Use `scripts/debug.sh` from this repository:

```bash
./scripts/debug.sh llama-3-3-70b default   # Debug specific service
./scripts/debug.sh --list               # List all AIM services
./scripts/debug.sh --gpu             # Check GPU detection
```

### Quick Troubleshooting Reference

| Symptom | Cause | Fix |
| :--- | :--- | :--- |
| AIMService stuck `Pending` | MI355X/MI300X template mismatch | Use `start.sh` custom MI355X templates, or add `allowUnoptimized: true` for manual manifests |
| AIMService stuck `Starting` | Image pull in progress / no resources | `kubectl describe pod <name> -n <ns>` |
| `ImagePullBackOff` | Docker Hub rate limit | Verify `.env` credentials |
| Pods `Pending` (unscheduled) | No GPU resources | `kubectl describe node \| grep amd.com/gpu` |
| Bloom install hangs | Disk mounted or wrong device | Set `DISK_OVERRIDE` in `.env` |
| ArgoCD / Gitea unreachable | MetalLB or HTTPRoute not ready | `kubectl get gateway -A` |

### Pre-Flight Debug Logs

```bash
ls amd-enterprise-ai-install/logs/debug/
cat amd-enterprise-ai-install/logs/debug/preflight.*.txt
```

---

## 7. Next Steps

With the platform installed and verified, continue through the operational loop:

1. **Start a model** — deploy and serve a model with `scripts/start.sh`. See **[QUICKSTART.md](QUICKSTART.md)**.
2. **Verify serving** — run the end-to-end sanity check (`/v1/models` + chat completion) with `scripts/check.sh`. See **[CHECK.md](CHECK.md)**.
3. **Benchmark** — run the performance sweep and accuracy evaluation with `scripts/benchmark.sh`. See **[BENCHMARK.md](BENCHMARK.md)**.
4. **Troubleshoot** — if any step stalls or fails, use `scripts/debug.sh` and the state-driven flow in **[DEBUG.md](DEBUG.md)**.

To tear down or reset the environment, use `scripts/uninstall.sh`.

---

## 8. Further Reading

### In This Repository

| Document | Purpose |
| :--- | :--- |
| [QUICKSTART.md](QUICKSTART.md) | Start models and run the POC workloads |
| [CHECK.md](CHECK.md) | Sanity-check model serving end to end |
| [BENCHMARK.md](BENCHMARK.md) | Performance sweep and accuracy evaluation |
| [DEBUG.md](DEBUG.md) | Detailed troubleshooting and diagnostics |

### External References

| Resource | Link |
| :--- | :--- |
| Official Install Guide | [Official Install Guide][install-guide] |
| AIM Engine Troubleshooting | [AIM Engine Troubleshooting Guide][trouble-guide] |
| AIMs Catalog | [AIMs Catalog Documentation][catalog-guide] |
| GPU Support Matrix | [GPU Support Matrix Reference][support-matrix] |

[install-guide]: <https://enterprise-ai.docs.amd.com/en/latest/platform-infrastructure/on-premises-installation.html>
[trouble-guide]: <https://enterprise-ai.docs.amd.com/en/latest/aim-engine/admin/troubleshooting.html>
[catalog-guide]: <https://enterprise-ai.docs.amd.com/en/latest/aims/catalog/models.html>
[support-matrix]: <https://enterprise-ai.docs.amd.com/en/latest/aims/gpu_support.html>
