#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Scores every prediction set in data/t3_preds.json with the shared metrics.
#   ruby compare_t3.rb
#
# Tag naming convention: <split>[_<model>][_ctx|_noctx]. The split prefix decides
# which held-out room list the predictions are scored against, so a mislabelled
# tag would silently score against the wrong set - keep the prefix accurate.

require_relative "lib/common"
require "json"

rooms = LC.load_rooms
by_v  = rooms.to_h { |r| [r.vnum, r] }
sp    = LC.splits
preds = JSON.parse(File.read(File.join(LC::DATA, "t3_preds.json")))

ORDER = %w[zone zone_mini_ctx zone_small_ctx zone_medium_ctx zone_base_ctx walk_medium_ctx room]
tags  = (ORDER & preds.keys) + (preds.keys - ORDER)

puts format("  %-20s %-9s %7s %7s %7s %8s %9s", "tag", "split", "P@3", "R@3", "F1@3", "PR-AUC", "bestF1")
puts "  " + "-" * 74

tags.each do |tag|
  split = LC.split_for(tag)
  te = sp[split]["test"].map { |v| by_v[v] }.compact
  ranked = te.map { |r| (preds[tag][r.vnum.to_s] || []).map { |w, s| [w, s.to_f] } }
  at_k, best, auc = LC.score_ranked(te, ranked, k: 3)
  puts format("  %-20s %-9s %6.1f%% %6.1f%% %6.1f%% %7.1f%% %8.1f%%",
              tag, split, at_k[:p] * 100, at_k[:r] * 100, at_k[:f1] * 100, auc * 100, best[:f1] * 100)
end

# Operating-point sweep for the best ZONE-split tag. "Always emit top-3" is the
# wrong default - 87.6% of rooms have no examinable scenery. Room-split tags are
# excluded from this selection: their PR-AUC is inflated 2-3x by vocabulary leak,
# so picking on it would sweep operating points for a model we would never ship.
zone_tags = tags.select { |t| t.start_with?("walk") }
zone_tags = tags.reject { |t| t.start_with?("room") } if zone_tags.empty?
best_tag = zone_tags.max_by do |tag|
  te = sp[LC.split_for(tag)]["test"].map { |v| by_v[v] }.compact
  LC.pr_auc(te, te.map { |r| (preds[tag][r.vnum.to_s] || []).map { |w, s| [w, s.to_f] } })
end

te = sp[LC.split_for(best_tag)]["test"].map { |v| by_v[v] }.compact
ranked = te.map { |r| (preds[best_tag][r.vnum.to_s] || []).map { |w, s| [w, s.to_f] } }

puts "\n  operating points — #{best_tag}"
puts format("  %-26s %7s %7s %7s %11s", "policy", "P", "R", "F1", "rooms w/out")
puts "  " + "-" * 64
[[3, 0.0], [3, 0.3], [3, 0.5], [3, 0.7], [1, 0.7], [3, 0.9], [1, 0.9]].each do |k, t|
  sel = ranked.map { |l| l.select { |(_w, s)| s >= t }.sort_by { |(_w, s)| -s }.first(k).map(&:first) }
  m = LC.score(te, sel)
  puts format("  top-%d, score >= %.1f%-8s %6.1f%% %6.1f%% %6.1f%% %10.1f%%",
              k, t, "", m[:p] * 100, m[:r] * 100, m[:f1] * 100,
              100.0 * sel.count { |s| !s.empty? } / te.size)
end
puts "\n  base rate: #{te.count { |r| !r.gold.empty? }}/#{te.size} test rooms " \
     "(#{(100.0 * te.count { |r| !r.gold.empty? } / te.size).round(1)}%) have gold"
