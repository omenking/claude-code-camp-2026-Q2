#!/usr/bin/env python3
"""
Export a checkpoint saved by `run_t3.py --save` to ONNX, plus an int8 copy.

    ./venv/bin/python export_onnx.py CKPT_DIR OUT_DIR

Writes OUT_DIR/{model_fp32.onnx, model_int8.onnx, vocab.json}. Nothing here is
needed at runtime — Ruby loads the .onnx and vocab.json and never sees torch.

The two ONNX files are NOT interchangeable at a fixed threshold: dynamic
quantization shifts the score distribution (see look_candidates_runtime.md 5.3),
so build_model.rb sweeps each one separately.
"""
import json, os, sys, torch
from transformers import AutoModelForTokenClassification

ckpt, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)

model = AutoModelForTokenClassification.from_pretrained(ckpt).eval()
fp32 = os.path.join(out, "model_fp32.onnx")
ids = torch.ones(1, 16, dtype=torch.long)
torch.onnx.export(
    model, (ids, ids), fp32,
    input_names=["input_ids", "attention_mask"], output_names=["logits"],
    dynamic_axes={"input_ids": {0: "b", 1: "t"}, "attention_mask": {0: "b", 1: "t"},
                  "logits": {0: "b", 1: "t"}},
    opset_version=17, dynamo=False)

from onnxruntime.quantization import quantize_dynamic, QuantType
int8 = os.path.join(out, "model_int8.onnx")
quantize_dynamic(fp32, int8, weight_type=QuantType.QInt8)

# The Ruby side implements WordPiece itself (the training split feeds it single
# [A-Za-z]{2,} words, so none of BERT's basic-tokenizer behaviour is reachable);
# all it needs is the vocab.
vocab = json.load(open(os.path.join(ckpt, "tokenizer.json")))["model"]["vocab"]
json.dump(vocab, open(os.path.join(out, "vocab.json"), "w"))

for f in ("model_fp32.onnx", "model_int8.onnx", "vocab.json"):
    print(f"  {f:18s} {os.path.getsize(os.path.join(out, f)) / 1e6:8.1f} MB", flush=True)
