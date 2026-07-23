#!/usr/bin/env ruby
# frozen_string_literal: true
#
# T0 baselines: the floor every trained tier must beat.
#   ruby run_t0.rb

require_relative "lib/common"

rooms  = LC.load_rooms
by_v   = rooms.to_h { |r| [r.vnum, r] }
sp     = LC.splits

SPLITS = {
  "zone (headline)" => [sp["zone"]["train"].map { |v| by_v[v] }.compact,
                        sp["zone"]["test"].map  { |v| by_v[v] }.compact],
  "room (leaky)"    => [sp["room"]["train"].map { |v| by_v[v] }.compact,
                        sp["room"]["test"].map  { |v| by_v[v] }.compact]
}

puts "corpus: #{rooms.size} rooms, #{rooms.sum { |r| r.gold.size }} scoreable gold blocks"
SPLITS.each do |n, (tr, te)|
  puts format("%-16s train %5d / test %5d   test gold %4d   candidate recall ceiling %.1f%%",
              n, tr.size, te.size, te.sum { |r| r.gold.size }, LC.ceiling(te) * 100)
end

# --- T0a: predict nothing -------------------------------------------------
LC.report("T0a — predict nothing", SPLITS, ->(_tr, te) { te.map { [] } })

# --- T0b: every candidate word (recall ceiling probe) ---------------------
LC.report("T0b — all content words", SPLITS,
          ->(_tr, te) { te.map { |r| LC.candidates(r).map { |w| [w, 1.0] } } })

# --- T0c: learned dictionary ----------------------------------------------
# Any word seen as a gold alias anywhere in train. Scored by train frequency so
# top-3 has something to rank on; this is the strongest purely-lexical policy.
LC.report("T0c — learned dictionary", SPLITS, lambda { |tr, te|
  freq = Hash.new(0)
  tr.each { |r| r.gold.each { |al| al.each { |a| freq[a] += 1 } } }
  te.map { |r| LC.candidates(r).select { |w| freq[w] > 0 }.map { |w| [w, freq[w].to_f] } }
})

# --- T0d: dictionary weighted by purity -----------------------------------
# Same vocabulary, but ranked by P(examinable | word) estimated on train instead
# of raw frequency. Tests whether the DATASET.md 3.1 purity signal is usable at
# all without context features.
LC.report("T0d — dictionary x purity", SPLITS, lambda { |tr, te|
  pos = Hash.new(0); neg = Hash.new(0)
  tr.each do |r|
    g = r.gold.reduce(Set.new) { |a, s| a | s }
    LC.candidates(r).each { |w| g.include?(w) ? pos[w] += 1 : neg[w] += 1 }
  end
  te.map do |r|
    LC.candidates(r).filter_map do |w|
      next unless pos[w] > 0
      [w, (pos[w] + 1.0) / (pos[w] + neg[w] + 10.0)]   # smoothed purity
    end
  end
})
