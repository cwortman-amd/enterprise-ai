"""Force-enable Hugging Face Xet downloads in the AIM cache download job.

The AIM controller hard-injects HF_HUB_DISABLE_XET=1 into every model cache
download job and does not allow overriding it via AIMModelCache spec.env
(duplicate env keys are rejected at Job apply time). With Xet disabled, large
Xet-backed model shards (e.g. openai/gpt-oss-120b) fail with:

    ValueError: The file is too large to be downloaded using the regular
    download method. Use `hf_transfer` or `hf_xet` instead.

Python imports `sitecustomize` automatically at interpreter startup (before the
storage initializer entrypoint runs), so clearing the flag here re-enables Xet
for high-throughput downloads regardless of the operator-injected env.
"""
import os

# Re-enable Xet-powered downloads (operator sets this to "1").
os.environ.pop("HF_HUB_DISABLE_XET", None)

# Enable high-performance Xet transfer (hf_xet is installed in this image).
# This replaces the now-deprecated HF_HUB_ENABLE_HF_TRANSFER flag in
# huggingface_hub >= 1.x. setdefault keeps any explicit override intact.
os.environ.setdefault("HF_XET_HIGH_PERFORMANCE", "1")
