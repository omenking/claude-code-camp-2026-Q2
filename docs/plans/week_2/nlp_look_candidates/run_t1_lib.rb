# frozen_string_literal: true
# Shared T1 featurizer + trainer (extracted from run_t1.rb so the ablation reuses it).
require_relative "lib/common"

DIRS  = %w[north south east west northeast northwest southeast southwest up down].to_set
EXIST = %w[stands stand lies lie hangs hang sits sit rests rest is are see notice
           visible standing lying hanging].to_set
LEAD  = %w[leads lead leading continues continue opens open runs run goes go].to_set
ADJ   = /(?:y|ing|ed|en|ous|ful|less|ish|al|ic|ive)\z/

# ---------------------------------------------------------------- features

def featurize(room, lex, df)
  toks = room.desc.scan(/[A-Za-z]{2,}/)
  low  = toks.map(&:downcase)
  sent = []                                   # sentence index per token
  si = 0
  room.desc.scan(/[A-Za-z]{2,}|[.!?]/) { |t| t =~ /[.!?]/ ? si += 1 : sent << si }
  sent = Array.new(low.size, 0) if sent.size != low.size

  namew = room.name.downcase.scan(/[a-z]{3,}/).to_set
  exitw = room.exits.flat_map { |e| e["to_name"].to_s.downcase.scan(/[a-z]{3,}/) }.to_set

  first = {}
  low.each_with_index { |w, i| first[w] ||= i }

  LC.candidates(room).map do |w|
    i = first[w] || 0
    f = Hash.new(0.0)
    f["bias"] = 1.0

    # -- lexical (train-only statistics) -----------------------------------
    st = lex[w]
    if st
      f["purity"]   = (st[0] + 1.0) / (st[0] + st[1] + 10.0)
      f["log_pos"]  = Math.log(1 + st[0])
      f["log_neg"]  = Math.log(1 + st[1])
      f["seen"]     = 1.0
    else
      f["unseen"]   = 1.0
    end
    f["log_df"] = Math.log(1 + df[w].to_i)

    # -- morphology --------------------------------------------------------
    f["suf3=#{w[-3..]}"] = 1.0
    f["suf4=#{w[-4..]}"] = 1.0 if w.length >= 4
    f["len"]    = w.length / 10.0
    f["plural"] = 1.0 if w.end_with?("s")

    # -- position ----------------------------------------------------------
    f["pos"]   = i.to_f / [low.size, 1].max
    f["sent"]  = [sent[i] || 0, 4].min / 4.0
    f["first_sent"] = 1.0 if (sent[i] || 0).zero?

    # -- local context -----------------------------------------------------
    p1 = i > 0 ? low[i - 1] : nil
    p2 = i > 1 ? low[i - 2] : nil
    n1 = low[i + 1]
    f["det_a"]   = 1.0 if p1 == "a" || p1 == "an" || p2 == "a" || p2 == "an"
    f["det_the"] = 1.0 if p1 == "the" || p2 == "the"
    f["adj_prev"] = 1.0 if p1 && p1 =~ ADJ
    f["adj2"]     = 1.0 if p2 && p2 =~ ADJ
    f["cap"]      = 1.0 if toks[i] =~ /\A[A-Z]/
    f["exist_near"] = 1.0 if [p1, p2, n1, low[i + 2]].compact.any? { |x| EXIST.include?(x) }
    f["lead_near"]  = 1.0 if [p1, p2, n1, low[i + 2]].compact.any? { |x| LEAD.include?(x) }
    f["dir_near"]   = 1.0 if [p1, p2, n1, low[i + 2]].compact.any? { |x| DIRS.include?(x) }
    f["is_dir"]     = 1.0 if DIRS.include?(w)

    # -- room-structural ---------------------------------------------------
    # Exit-destination membership is a FEATURE, never a subtraction: the earlier
    # plan proposed subtracting these and measurement killed it (F1 15.4 -> 13.9).
    f["in_name"] = 1.0 if namew.include?(w)
    f["in_exit"] = 1.0 if exitw.include?(w)
    f["sector=#{room.sector}"] = 1.0
    f["ndesc"] = Math.log(1 + low.size) / 5.0

    [w, f]
  end
end

def train_lex(train)
  lex = Hash.new { |h, k| h[k] = [0, 0] }
  df  = Hash.new(0)
  train.each do |r|
    g = r.gold.reduce(Set.new) { |a, s| a | s }
    LC.candidates(r).each do |w|
      df[w] += 1
      g.include?(w) ? lex[w][0] += 1 : lex[w][1] += 1
    end
  end
  [lex, df]
end

# ---------------------------------------------------------------- model

def fit(examples, labels, epochs: 6, lr: 0.5, l2: 1.0e-6, pos_weight: 12.0)
  w = Hash.new(0.0)
  g2 = Hash.new(1.0e-8)                       # AdaGrad accumulator
  idx = (0...examples.size).to_a
  rng = Random.new(42)
  epochs.times do
    idx.shuffle!(random: rng)
    idx.each do |i|
      f = examples[i]
      y = labels[i]
      z = 0.0
      f.each { |k, v| z += w[k] * v }
      z = 30.0 if z > 30.0
      z = -30.0 if z < -30.0
      p = 1.0 / (1.0 + Math.exp(-z))
      err = (p - y) * (y == 1 ? pos_weight : 1.0)
      f.each do |k, v|
        gr = err * v + l2 * w[k]
        g2[k] += gr * gr
        w[k] -= lr * gr / Math.sqrt(g2[k])
      end
    end
  end
  w
end

def predict(w, f)
  z = 0.0
  f.each { |k, v| z += w[k] * v }
  1.0 / (1.0 + Math.exp(-[[z, 30.0].min, -30.0].max))
end

