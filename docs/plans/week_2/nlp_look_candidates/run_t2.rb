#!/usr/bin/env ruby
# frozen_string_literal: true
#
# T2 — fastText supervised classification.
#   ruby run_t2.rb
#
# fastText classifies TEXT, not tokens, so each (room, candidate) pair becomes one
# pseudo-document: the target word, its local context window, and coarse structural
# markers. Subword n-grams (minn/maxn) give the morphological backoff that T1 had to
# hand-build as suffix features - and which measurably overfit there.

require_relative "lib/common"
require "fasttext"


DIRS = %w[north south east west northeast northwest southeast southwest up down].to_set

def doc_for(room, w, low, toks, i, namew, exitw)
  lo = [i - 5, 0].max
  hi = [i + 5, low.size - 1].min
  ctx = low[lo..hi].reject { |x| x == w }
  marks = []
  marks << "M_name"  if namew.include?(w)
  marks << "M_exit"  if exitw.include?(w)
  marks << "M_cap"   if toks[i] =~ /\A[A-Z]/
  marks << "M_dir"   if DIRS.include?(w)
  marks << "M_start" if i < 8
  marks << "M_sec_#{room.sector}"
  "TGT_#{w} #{ctx.join(' ')} #{marks.join(' ')}"
end

def build(rooms, labelled:)
  out = []
  rooms.each do |r|
    toks = r.desc.scan(/[A-Za-z]{2,}/)
    low  = toks.map(&:downcase)
    first = {}
    low.each_with_index { |x, i| first[x] ||= i }
    namew = r.name.downcase.scan(/[a-z]{3,}/).to_set
    exitw = r.exits.flat_map { |e| e["to_name"].to_s.downcase.scan(/[a-z]{3,}/) }.to_set
    g = r.gold.reduce(Set.new) { |a, s| a | s }
    LC.candidates(r).each do |w|
      i = first[w] || 0
      d = doc_for(r, w, low, toks, i, namew, exitw)
      out << (labelled ? ["__label__#{g.include?(w) ? 'pos' : 'neg'} #{d}", r, w] : [d, r, w])
    end
  end
  out
end

rooms = LC.load_rooms
by_v  = rooms.to_h { |r| [r.vnum, r] }
sp    = LC.splits
SPLITS = {
  "zone (headline)" => [sp["zone"]["train"], sp["zone"]["test"]],
  "room (leaky)"    => [sp["room"]["train"], sp["room"]["test"]]
}

runner = lambda do |tr, te|
  x = []
  y = []
  # Oversample positives: fastText has no class weighting, and at 0.9% positives
  # it otherwise collapses to predicting "neg" for everything.
  build(tr, labelled: false).each do |doc, r, w|
    g = r.gold.reduce(Set.new) { |a, s| a | s }
    pos = g.include?(w)
    n = pos ? 13 : 1
    n.times { x << doc; y << (pos ? "pos" : "neg") }
  end
  warn "  [t2] docs=#{x.size} pos=#{y.count('pos')}"

  model = FastText::Classifier.new(dim: 60, epoch: 12, lr: 0.3, word_ngrams: 2,
                                   minn: 3, maxn: 6, bucket: 300_000,
                                   min_count: 1, verbose: 0)
  model.fit(x, y)

  scores = Hash.new { |h, k| h[k] = [] }
  build(te, labelled: false).each do |doc, r, w|
    # predict returns {label => probability}
    scores[r.vnum] << [w, (model.predict(doc, k: 2)["pos"] || 0.0).to_f]
  end
  te.map { |r| scores[r.vnum] }
end

wrapped = {}
SPLITS.each do |name, (trv, tev)|
  wrapped[name] = [trv.map { |v| by_v[v] }.compact, tev.map { |v| by_v[v] }.compact]
end

LC.report("T2 — fastText supervised (subword n-grams)", wrapped, runner)
