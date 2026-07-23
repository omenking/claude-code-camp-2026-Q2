#!/usr/bin/env ruby
# frozen_string_literal: true
# Do Haiku and the trained model find the SAME hidden scenery, or different?
# Decides whether "escalate to an LLM when needed" can beat either alone.
#   ruby analyze_cascade.rb
require_relative "lib/common"
require "json"
rooms = LC.load_rooms; by = rooms.to_h { |r| [r.vnum, r] }
te = LC.splits["walk"]["test"].map { |v| by[v] }.compact
hp = JSON.parse(File.read(File.join(LC::DATA, "tl_haiku_preds.json")))["single_nofewshot"]
mp = JSON.parse(File.read(File.join(LC::DATA, "t3_preds.json")))["walk_medium_ctx"]
model = te.map { |r| (mp[r.vnum.to_s] || []).select { |_w, s| s.to_f >= 0.3 }
                     .sort_by { |_w, s| -s.to_f }.first(3).map(&:first) }
haiku = te.map { |r| hp[r.vnum.to_s] || [] }
both = te.each_index.map { |i| (model[i] | haiku[i]).first(4) }
# per gold block: who found it?
only_m = only_h = shared = neither = 0
te.each_with_index do |r, i|
  r.gold.each do |al|
    m = al.any? { |a| model[i].include?(a) }
    h = al.any? { |a| haiku[i].include?(a) }
    if m && h then shared += 1 elsif m then only_m += 1 elsif h then only_h += 1 else neither += 1 end
  end
end
tot = shared + only_m + only_h + neither
puts "  of #{tot} hidden things in the 340 test rooms:"
puts format("    found by BOTH          %4d  (%.1f%%)", shared, 100.0 * shared / tot)
puts format("    ONLY the trained model %4d  (%.1f%%)", only_m, 100.0 * only_m / tot)
puts format("    ONLY haiku             %4d  (%.1f%%)", only_h, 100.0 * only_h / tot)
puts format("    neither                %4d  (%.1f%%)", neither, 100.0 * neither / tot)
puts
puts format("  %-28s %7s %7s %7s", "strategy", "P", "R", "F1")
puts "  " + "-" * 54
{ "trained model only" => model, "haiku only" => haiku, "union of both" => both }.each do |k, v|
  m = LC.score(te, v)
  puts format("  %-28s %6.1f%% %6.1f%% %6.1f%%", k, m[:p] * 100, m[:r] * 100, m[:f1] * 100)
end
