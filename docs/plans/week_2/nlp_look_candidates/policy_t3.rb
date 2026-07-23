# Product-policy sweep for the winning tier. "Always emit top-3" is the wrong
# policy: 87.6% of rooms have NO examinable scenery, so emitting 3 guesses
# everywhere manufactures false positives. Gate on score, then cap at k.
require_relative "lib/common"
require "json"
rooms = LC.load_rooms
by_v  = rooms.to_h { |r| [r.vnum, r] }
sp    = LC.splits
preds = JSON.parse(File.read(File.join(LC::DATA, "t3_preds.json")))
te = sp["zone"]["test"].map { |v| by_v[v] }.compact
ranked = te.map { |r| (preds["zone"][r.vnum.to_s] || []).map { |w, s| [w, s.to_f] } }

puts format("  %-34s %8s %8s %8s %10s", "policy", "P", "R", "F1", "rooms w/ output")
puts "  " + "-" * 74
[[3, 0.0], [3, 0.3], [3, 0.5], [3, 0.7], [2, 0.5], [1, 0.5], [1, 0.7], [3, 0.9]].each do |k, t|
  sel = ranked.map { |l| l.select { |(_w, s)| s >= t }.sort_by { |(_w, s)| -s }.first(k).map(&:first) }
  m = LC.score(te, sel)
  nonempty = sel.count { |s| !s.empty? }
  puts format("  top-%d, score >= %.1f%-16s %7.1f%% %7.1f%% %7.1f%% %9.1f%%",
              k, t, "", m[:p] * 100, m[:r] * 100, m[:f1] * 100, 100.0 * nonempty / te.size)
end
puts "\n  reference: #{te.count { |r| !r.gold.empty? }} of #{te.size} test rooms (#{(100.0 * te.count { |r| !r.gold.empty? } / te.size).round(1)}%) actually have gold"
