import sys
import os

# The AIM controller currently injects HF_HUB_DISABLE_XET=1 into cache jobs.
# GPT-OSS uses Hugging Face Xet-backed large files, so explicitly prefer hf_xet.
# Keep concurrency conservative because the cache PVC is network-backed and the
# CDN can reset high-concurrency range requests during large downloads.
os.environ.pop("HF_HUB_DISABLE_XET", None)
os.environ.pop("HF_HUB_ENABLE_HF_TRANSFER", None)
os.environ.setdefault("HF_XET_NUM_CONCURRENT_RANGE_GETS", "4")
os.environ.setdefault("HF_XET_RECONSTRUCT_WRITE_SEQUENTIALLY", "1")

from huggingface_hub import snapshot_download

if len(sys.argv) < 3:
    print("Usage: initializer-entrypoint <src_uri> <dest_path>")
    sys.exit(1)

src_uri = sys.argv[1]
dest_path = sys.argv[2]

# Remove hf:// prefix
repo_id = src_uri.replace("hf://", "")

# Keep the Xet dedup chunk cache on the same (large, network-backed) cache volume as
# the destination, not the container's small ephemeral filesystem. Otherwise the chunk
# cache can fill ephemeral storage and the pod is evicted mid-download.
dest_parent = os.path.dirname(os.path.normpath(dest_path)) or dest_path
xet_cache_dir = os.path.join(dest_parent, ".xet-cache")
os.makedirs(xet_cache_dir, exist_ok=True)
os.environ.setdefault("HF_XET_CACHE", xet_cache_dir)

print(f"Custom downloader: downloading {repo_id} to {dest_path}", flush=True)
print(
    "Custom downloader: "
    f"HF_XET_NUM_CONCURRENT_RANGE_GETS={os.getenv('HF_XET_NUM_CONCURRENT_RANGE_GETS')} "
    f"HF_XET_RECONSTRUCT_WRITE_SEQUENTIALLY={os.getenv('HF_XET_RECONSTRUCT_WRITE_SEQUENTIALLY')} "
    f"HF_XET_CACHE={os.getenv('HF_XET_CACHE')} "
    "max_workers=1",
    flush=True,
)
snapshot_download(
    repo_id=repo_id,
    local_dir=dest_path,
    ignore_patterns=["metal/*", "original/*"],
    token=os.getenv("HF_TOKEN") or os.getenv("HUGGING_FACE_HUB_TOKEN"),
    max_workers=1,
)
print("Download finished successfully!", flush=True)
