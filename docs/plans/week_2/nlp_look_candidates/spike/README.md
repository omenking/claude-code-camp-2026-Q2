# Spike — running the trained model from Ruby

Evidence for [`../../look_candidates_runtime.md`](../../look_candidates_runtime.md)
§2. Throwaway scripts kept because the plan cites their numbers; fold the useful
parts back into `run_t3.py` (plan work item 1) rather than growing this folder.

```bash
cd ..                       # nlp_look_candidates/
python3 -m venv venv --system-site-packages
./venv/bin/pip install transformers onnx onnxruntime

SEED=42 ./venv/bin/python spike/train_save.py --split walk --epochs 4 \
    --model google/bert_uncased_L-8_H-512_A-8 --use-context --tag noamp
./venv/bin/python spike/export_onnx.py      # spike/ckpt -> spike/lc.onnx (165 MB)
./venv/bin/python spike/ref.py              # Python reference scores -> spike/ref.json

gem install onnxruntime
ruby spike/parity.rb                        # ids + scores vs ref.json, and latency
ruby spike/ruby_preds.rb lc                 # full walk test set -> data/t3_preds.json["ruby_lc"]
```

- `train_save.py` — `run_t3.py` plus `SEED` env var and `save_pretrained`.
  The upstream script persists nothing, which is why no bake-off weights survive.
- `parity.rb` — pure-Ruby WordPiece (no `tokenizers` gem) + `onnxruntime`.
  0 token-id mismatches, max score delta 1.6e-06.
- `ruby_preds.rb <variant>...` — scores every walk-test room from Ruby and merges
  the predictions into `data/t3_preds.json` under `ruby_<variant>`.

**Tags this spike added to `data/t3_preds.json`:**

| tags | plan section |
|---|---|
| `spike_walk`, `seed1`–`seed3`, `noamp` | §4 seed variance |
| `nosec1`–`nosec3` | §5.1 sector ablation (`NOSECTOR=1`) |
| `small1`–`small3`, `mini1`–`mini3` | §5.2 capacity ladder, shipping recipe |
| `nosec3_rebuild` | §5.3/§5.4 the median checkpoint the final artifacts came from |
| `ruby_lc`, `ruby_lc_int8` | §5.3 fp32 vs int8, scored from Ruby |

Delete them once work item 2's pipeline regenerates the numbers properly.

`train_save.py` honours `NOSECTOR=1` to drop `sector` from the encoder context —
the ablation behind §5. In the real pipeline this becomes `--context-fields`
(plan work item 1), not an env var.

Model artifacts (`ckpt/`, `*.onnx`) are deliberately not committed here — see
plan §8 for where they should live.
