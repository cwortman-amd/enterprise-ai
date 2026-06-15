# Standalone AIM Deployments

Raw Kubernetes `Deployment` + `Service` manifests for serving models with the
[AMD Inference Microservice (AIM)](https://github.com/amd-enterprise-ai/aim-build)
container images. These follow each model's official AIM deployment guide
(section 3) and run **independently of the AIM operator** (`AIMService` /
`AIMClusterServiceTemplate`) — useful for direct, reproducible serving and for
benchmarking the tuned configuration.

## Layout

| Directory | Model | Image | GPUs (TP) | HF token |
|---|---|---|---|---|
| `gpt-oss-120b/` | `openai/gpt-oss-120b` | `aim-openai-gpt-oss-120b:0.11.1` | 8 | required (gated) |
| `llama-3-3-70b/` | `meta-llama/Llama-3.3-70B-Instruct` | `aim-meta-llama-llama-3-3-70b-instruct:0.11.1` | 1 | required (gated) |
| `mixtral-8x22b/` | `mistralai/Mixtral-8x22B-Instruct-v0.1` | `aim-mistralai-mixtral-8x22b-instruct-v0-1:0.11.1` | 8 | not needed |

Each directory contains:
- `deployment.yaml` — the `Deployment` plus a `PersistentVolumeClaim` for the
  model cache (so weights survive restarts instead of re-downloading).
- `service.yaml` — a ClusterIP `Service` (port `80` → container `8000`).
- `gpt-oss-120b/` also has `profile-configmap.yaml` (see below).

## How these differ from the upstream guide

Adapted from the AIM guide's sample manifest, with these consistent changes:
- Image pinned to `0.11.1`; `AIM_GPU_MODEL=MI355X` for our hardware.
- Per-app names/labels (not the shared `minimal-aim-deployment`) so all three
  can coexist in one namespace.
- A persistent `model-cache` PVC instead of a bare `emptyDir`.
- `HF_TOKEN` / `HUGGING_FACE_HUB_TOKEN` injected from the `hf-token` secret
  (key `token`, `optional: true`) on the gated models.

## GPT-OSS-120B performance profile

`gpt-oss-120b/profile-configmap.yaml` is an AIM **custom profile** mounted at
`/workspace/aim-runtime/profiles/custom` and pinned via `AIM_PROFILE_ID`. It
encodes AMD's ROCm tuning for MI355x:

- `engine_args`: `tensor-parallel-size: 8`, `attention-backend:
  ROCM_AITER_UNIFIED_ATTN`, `gpu-memory-utilization: 0.95`, `block-size: 64`,
  and `compilation-config` carrying `fuse_rope_kvcache` + inductor graph
  partition.
- `env_vars`: `HSA_NO_SCRATCH_RECLAIM=1`, `AMDGCN_USE_BUFFER_OPS=0`,
  `VLLM_ROCM_USE_AITER=1`, `VLLM_ROCM_QUICK_REDUCE_QUANTIZATION=INT4`.

> `HSA_NO_SCRATCH_RECLAIM=1` is only needed when GPU firmware MEC version < 177
> (`rocm-smi --showfw | grep MEC | head -n1 | awk '{print $NF}'`). Llama and
> Mixtral use AIM's automatic profile selection (no custom profile).

## Usage

```bash
# Create the HF token secret once (gated models). start.sh also does this.
kubectl create secret generic hf-token -n default --from-literal=token="$HF_TOKEN"

# Deploy one model (requests 8 GPUs for gpt-oss / mixtral, 1 for llama).
kubectl apply -f deploy/gpt-oss-120b/ -n default

# Watch rollout, then reach the API locally.
kubectl rollout status deploy/gpt-oss-120b-aim -n default
kubectl port-forward service/gpt-oss-120b-aim 8000:80 -n default
curl http://localhost:8000/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"openai/gpt-oss-120b","prompt":"Once upon a time,","max_tokens":50}'
```

## Before you apply

- **GPU capacity**: GPT-OSS and Mixtral each request 8 `amd.com/gpu`, Llama 1.
  They cannot all run at once on a single 8-GPU node — deploy one at a time.
- **GPU count vs hardware**: lower `AIM_GPU_COUNT` and `amd.com/gpu` if a node
  has fewer GPUs.
- **StorageClass**: PVCs use the cluster default (Longhorn). Set
  `storageClassName` if you need a specific class.
- **Inspect profiles** the image offers (especially MXFP4 / TP variants):
  ```bash
  docker run --rm amdenterpriseai/aim-openai-gpt-oss-120b:0.11.1 list-profiles
  docker run --rm -e AIM_GPU_MODEL=MI355X -e AIM_GPU_COUNT=8 \
    amdenterpriseai/aim-openai-gpt-oss-120b:0.11.1 dry-run
  ```

## Relationship to the operator path

These raw deployments are an alternative to the operator-managed path
(`scripts/poc-models.yaml` + `scripts/start.sh`). They do **not** use the
operator's caching/routing or the `AIMModelCache` flow; each pod downloads to
its own PVC. Run one path or the other for a given model, not both.
