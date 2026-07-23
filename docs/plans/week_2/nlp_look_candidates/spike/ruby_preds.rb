require "json"; require "onnxruntime"
HERE=__dir__; PLAN=File.expand_path("..", __dir__)
VOCAB=JSON.parse(File.read("#{HERE}/ckpt/tokenizer.json"))["model"]["vocab"]
CLS,SEP,UNK=VOCAB["[CLS]"],VOCAB["[SEP]"],VOCAB["[UNK]"]
def wp(word); w=word.downcase; out=[]; s=0
  while s<w.length; f=w.length; cur=nil
    while s<f; sub=s.positive? ? "###{w[s...f]}" : w[s...f]; (cur=sub;break) if VOCAB.key?(sub); f-=1; end
    return [UNK] if cur.nil?
    out<<VOCAB[cur]; s=f; end
  out; end
W=/[A-Za-z]{2,}/; MAX=256
def enc(r); ids=[CLS]; wpos=[]
  [r["name"],r["sector"].to_s.downcase,(r["exits"]||[]).join(" ")].join(" ").scan(W).first(48).each { |w|
    sub=wp(w); ids.concat(sub) if ids.length+sub.length+2<MAX }
  ids<<SEP
  r["desc"].scan(W).each { |w| sub=wp(w); break if ids.length+sub.length+1>MAX
    wpos<<[w.downcase,ids.length]; ids.concat(sub) }
  ids<<SEP; [ids,wpos]; end
rooms=JSON.parse(File.read("#{PLAN}/data/t3_input.json"))["walk"]["test"]
out={}
ARGV.each do |variant|
  sess=OnnxRuntime::Model.new("#{HERE}/#{variant}.onnx"); preds={}; t=[]
  rooms.each do |r|
    ids,wpos=enc(r); t0=Time.now
    lg=sess.predict({"input_ids"=>[ids],"attention_mask"=>[Array.new(ids.length,1)]})["logits"][0]
    t<<(Time.now-t0)*1000
    best=Hash.new(-1.0)
    wpos.each { |w,p| s=Math.exp(lg[p][1])/(Math.exp(lg[p][0])+Math.exp(lg[p][1])); best[w]=s if s>best[w] }
    preds[r["vnum"].to_s]=r["cands"].map { |c| [c, best.key?(c) ? best[c] : 0.0] }
  end
  out["ruby_#{variant}"]=preds
  st=t.sort
  warn format("%s: mean %.1f ms  median %.1f  p95 %.1f  (%d rooms)",variant,t.sum/t.size,st[t.size/2],st[(t.size*0.95).to_i],t.size)
end
f="#{PLAN}/data/t3_preds.json"; e=JSON.parse(File.read(f)); e.merge!(out); File.write(f,JSON.generate(e))
warn "merged: #{out.keys.join(', ')}"
