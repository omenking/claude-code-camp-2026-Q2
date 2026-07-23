require "json"; require "onnxruntime"
HERE = __dir__
PLAN = File.expand_path("..", __dir__)

# --- pure-Ruby WordPiece over the vocab embedded in tokenizer.json -------------
VOCAB = JSON.parse(File.read("#{HERE}/ckpt/tokenizer.json"))["model"]["vocab"]
CLS, SEP, UNK = VOCAB["[CLS]"], VOCAB["[SEP]"], VOCAB["[UNK]"]
def wordpiece(word)
  w = word.downcase; out = []; start = 0
  while start < w.length
    fin = w.length; cur = nil
    while start < fin
      sub = start.positive? ? "###{w[start...fin]}" : w[start...fin]
      (cur = sub; break) if VOCAB.key?(sub)
      fin -= 1
    end
    return [UNK] if cur.nil?
    out << VOCAB[cur]; start = fin
  end
  out
end
WORD = /[A-Za-z]{2,}/
MAXLEN = 256

def encode(room)
  ids = [CLS]; wpos = []
  ctx = [room["name"], room["sector"].to_s.downcase, (room["exits"] || []).join(" ")].join(" ")
  ctx.scan(WORD).first(48).each do |w|
    sub = wordpiece(w)
    ids.concat(sub) if ids.length + sub.length + 2 < MAXLEN
  end
  ids << SEP
  room["desc"].scan(WORD).each do |w|
    sub = wordpiece(w)
    break if ids.length + sub.length + 1 > MAXLEN
    wpos << [w.downcase, ids.length]; ids.concat(sub)
  end
  ids << SEP
  [ids, wpos]
end

t0 = Time.now
sess = OnnxRuntime::Model.new("#{HERE}/lc.onnx")
load_ms = (Time.now - t0) * 1000

rooms = JSON.parse(File.read("#{PLAN}/data/t3_input.json"))["zone"]["test"].first(20)
ref   = JSON.parse(File.read("#{HERE}/ref.json"))

def softmax1(pair) = Math.exp(pair[1]) / (Math.exp(pair[0]) + Math.exp(pair[1]))

max_diff = 0.0; id_mismatch = 0; times = []
rooms.each_with_index do |room, i|
  ids, wpos = encode(room)
  id_mismatch += 1 unless ids.length == ref[i]["n_ids"] && ids.first(12) == ref[i]["ids_head"]
  t = Time.now
  out = sess.predict({ "input_ids" => [ids], "attention_mask" => [Array.new(ids.length, 1)] })
  times << (Time.now - t) * 1000
  logits = out["logits"][0]
  best = Hash.new(-1.0)
  wpos.each { |w, p| s = softmax1(logits[p]); best[w] = s if s > best[w] }
  room["cands"].each do |c|
    d = ((best.key?(c) ? best[c] : 0.0) - ref[i]["scores"][c]).abs
    max_diff = d if d > max_diff
  end
  next unless i < 3
  top = best.select { |w, _| room["cands"].include?(w) }.sort_by { |_, s| -s }.first(3)
  puts format("  room %-6s cands=%-3d top3=%s", room["vnum"], room["cands"].length,
              top.map { |w, s| "#{w}:#{s.round(3)}" }.join(" "))
end
puts "session load      : #{load_ms.round(1)} ms"
puts "id mismatches     : #{id_mismatch}/20"
puts "max |ruby-python| : #{max_diff.round(8)}"
puts format("inference/room    : mean %.1f ms  p_max %.1f ms (%d rooms, 1 thread default)",
            times.sum / times.size, times.max, times.size)
