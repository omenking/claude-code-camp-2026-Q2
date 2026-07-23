#!/usr/bin/env python3
"""
T3 - contextual transformer, token classification.

    ./venv/bin/python run_t3.py [--split zone] [--epochs 4] [--model google/bert_uncased_L-4_H-256_A-4]

This is the tier that DATASET.md 3.1 argues should matter. Median word purity is
8.6% - `wall` is examinable 3.7% of the time - so whether a noun is examinable is
a property of the ROOM, not the word. A bag-of-features model (T1) cannot represent
that; a contextual encoder can. If T3 does not beat T1/T2, the remaining gap is
authorial noise (README 7.4), not model capacity.

Reads data/t3_input.json (exported by export_t3.rb so the candidate pool is
identical to the Ruby tiers) and writes data/t3_preds.json, which run_t3.rb scores
with the same metrics as every other tier.
"""
import json, argparse, math, os, random
import torch
import torch.nn as nn
from transformers import AutoTokenizer, AutoModelForTokenClassification

ap = argparse.ArgumentParser()
ap.add_argument("--split", default="zone")
ap.add_argument("--epochs", type=int, default=4)
ap.add_argument("--model", default="google/bert_uncased_L-4_H-256_A-4")
ap.add_argument("--maxlen", type=int, default=256)
ap.add_argument("--bs", type=int, default=32)
ap.add_argument("--lr", type=float, default=5e-5)
ap.add_argument("--pos-weight", type=float, default=20.0)
ap.add_argument("--use-context", action="store_true",
                help="prepend room name + sector + exit destinations as encoder context")
ap.add_argument("--tag", default=None, help="key under which to store predictions")
ap.add_argument("--amp", action="store_true", help="mixed precision (halves memory, ~2x faster)")
args = ap.parse_args()

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_s=int(os.environ.get("SEED","42")); random.seed(_s); torch.manual_seed(_s)

tok = AutoTokenizer.from_pretrained(args.model, use_fast=False)
dev = "cuda" if torch.cuda.is_available() else "cpu"
print(f"device={dev} model={args.model}", flush=True)

WORD = __import__("re").compile(r"[A-Za-z]{2,}")


def encode(room):
    """Manual word->subtoken alignment (slow tokenizers have no word_ids())."""
    words = WORD.findall(room["desc"])
    gold = set(a for al in room["gold"] for a in al)
    ids, wpos, labels = [tok.cls_token_id], [], []
    if args.use_context:
        # Room name / sector / exit destinations are context the model can attend
        # to but must NOT be labelled - only description tokens carry labels.
        ctx = " ".join([room.get("name",""), "" if os.environ.get("NOSECTOR") else (room.get("sector") or "").lower(),
                        " ".join(room.get("exits", []) or [])])
        for w in WORD.findall(ctx)[:48]:
            sub = tok.convert_tokens_to_ids(tok.tokenize(w))
            if sub and len(ids) + len(sub) + 2 < args.maxlen:
                ids.extend(sub)
        ids.append(tok.sep_token_id)
    for wi, w in enumerate(words):
        sub = tok.convert_tokens_to_ids(tok.tokenize(w))
        if not sub:
            continue
        if len(ids) + len(sub) + 1 > args.maxlen:
            break
        wpos.append((w.lower(), len(ids)))          # first subtoken carries the label
        labels.append(1 if w.lower() in gold else 0)
        ids.extend(sub)
    ids.append(tok.sep_token_id)
    return ids, wpos, labels


def batches(rooms, bs, shuffle):
    idx = list(range(len(rooms)))
    if shuffle:
        random.shuffle(idx)
    for i in range(0, len(idx), bs):
        chunk = [rooms[j] for j in idx[i:i + bs]]
        enc = [encode(r) for r in chunk]
        mx = max(len(e[0]) for e in enc)
        input_ids = torch.zeros(len(enc), mx, dtype=torch.long)
        attn = torch.zeros(len(enc), mx, dtype=torch.long)
        lab = torch.full((len(enc), mx), -100, dtype=torch.long)
        for k, (ids, wpos, labels) in enumerate(enc):
            input_ids[k, :len(ids)] = torch.tensor(ids)
            attn[k, :len(ids)] = 1
            for (_w, p), y in zip(wpos, labels):
                lab[k, p] = y
        yield chunk, enc, input_ids.to(dev), attn.to(dev), lab.to(dev)


data = json.load(open(os.path.join(HERE, "data/t3_input.json")))[args.split]
train, test = data["train"], data["test"]
print(f"split={args.split} train={len(train)} test={len(test)}", flush=True)

model = AutoModelForTokenClassification.from_pretrained(args.model, num_labels=2).to(dev)
opt = torch.optim.AdamW(model.parameters(), lr=args.lr)
# Heavy positive weighting: ~0.9% of tokens are positive, so unweighted CE
# collapses to all-negative within one epoch.
lossf = nn.CrossEntropyLoss(weight=torch.tensor([1.0, args.pos_weight]).to(dev), ignore_index=-100)

steps = args.epochs * math.ceil(len(train) / args.bs)
sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=args.lr, total_steps=steps, pct_start=0.1)

amp_on = args.amp and dev == "cuda"
scaler = torch.amp.GradScaler("cuda", enabled=amp_on)

model.train()
step = 0
for ep in range(args.epochs):
    tot, n = 0.0, 0
    for _chunk, _enc, ids, attn, lab in batches(train, args.bs, True):
        with torch.amp.autocast("cuda", enabled=amp_on):
            out = model(input_ids=ids, attention_mask=attn).logits
            loss = lossf(out.view(-1, 2), lab.view(-1))
        scaler.scale(loss).backward()
        scaler.unscale_(opt)
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        scaler.step(opt); scaler.update(); sched.step(); opt.zero_grad()
        tot += loss.item(); n += 1; step += 1
        if step % 100 == 0:
            print(f"  ep{ep+1} step {step}/{steps} loss {tot/max(n,1):.4f}", flush=True)
    print(f"epoch {ep+1} mean loss {tot/max(n,1):.4f}", flush=True)

model.eval()
preds = {}
with torch.no_grad():
    for chunk, enc, ids, attn, _lab in batches(test, args.bs, False):
        with torch.amp.autocast("cuda", enabled=amp_on):
            logits = model(input_ids=ids, attention_mask=attn).logits
        prob = torch.softmax(logits.float(), dim=-1)[:, :, 1]
        for k, room in enumerate(chunk):
            best = {}
            for (w, p) in enc[k][1]:
                s = float(prob[k, p])
                if s > best.get(w, -1):
                    best[w] = s
            # emit scores for exactly the shared candidate pool
            preds[str(room["vnum"])] = [[c, best.get(c, 0.0)] for c in room["cands"]]

outp = os.path.join(HERE, "data/t3_preds.json")
existing = json.load(open(outp)) if os.path.exists(outp) else {}
existing[args.tag or args.split] = preds
json.dump(existing, open(outp, "w"))
print(f"wrote {outp} ({args.tag or args.split}: {len(preds)} rooms)", flush=True)

# --- spike addition: persist the trained artefact ---
outdir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ckpt")
model.save_pretrained(outdir)
from transformers import AutoTokenizer as _AT
_AT.from_pretrained(args.model).save_pretrained(outdir)   # fast tokenizer -> tokenizer.json + vocab.txt
print("saved", outdir, flush=True)
