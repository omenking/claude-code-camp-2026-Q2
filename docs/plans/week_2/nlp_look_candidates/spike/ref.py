import json,os,re,torch
from transformers import AutoTokenizer, AutoModelForTokenClassification
HERE=os.path.dirname(os.path.abspath(__file__))
P="os.path.dirname(os.path.dirname(os.path.abspath(__file__)))"
tok=AutoTokenizer.from_pretrained(os.path.join(HERE,"ckpt"),use_fast=False)
m=AutoModelForTokenClassification.from_pretrained(os.path.join(HERE,"ckpt")).eval()
rooms=json.load(open(P+"/data/t3_input.json"))["zone"]["test"][:20]
WORD=re.compile(r"[A-Za-z]{2,}"); MAXLEN=256
out=[]
for room in rooms:
    ids=[tok.cls_token_id]; wpos=[]
    ctx=" ".join([room.get("name",""),(room.get("sector") or "").lower()," ".join(room.get("exits",[]) or [])])
    for w in WORD.findall(ctx)[:48]:
        sub=tok.convert_tokens_to_ids(tok.tokenize(w))
        if sub and len(ids)+len(sub)+2<MAXLEN: ids.extend(sub)
    ids.append(tok.sep_token_id)
    for w in WORD.findall(room["desc"]):
        sub=tok.convert_tokens_to_ids(tok.tokenize(w))
        if not sub: continue
        if len(ids)+len(sub)+1>MAXLEN: break
        wpos.append((w.lower(),len(ids))); ids.extend(sub)
    ids.append(tok.sep_token_id)
    with torch.no_grad():
        pr=torch.softmax(m(input_ids=torch.tensor([ids]),attention_mask=torch.ones(1,len(ids),dtype=torch.long)).logits,-1)[0,:,1]
    best={}
    for w,p in wpos: best[w]=max(best.get(w,-1),float(pr[p]))
    out.append({"vnum":room["vnum"],"n_ids":len(ids),"ids_head":ids[:12],
                "scores":{c:round(best.get(c,0.0),6) for c in room["cands"]}})
json.dump(out,open(HERE+"/ref.json","w"),indent=1)
print("rooms",len(out))
