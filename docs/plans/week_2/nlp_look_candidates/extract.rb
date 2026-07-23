#!/usr/bin/env ruby
# frozen_string_literal: true
#
# extract.rb — build the look_candidates dataset from the tbaMUD world JSON export.
#
#   ruby extract.rb [--world PATH] [--out DIR]
#
# Source of truth is week0_explore/preview/data/world/wld/*.json (189 files), a
# structured export of week0_explore/infrastructure/lib/world/wld/*.wld — which
# is the SAME lib/ that docker-compose bind-mounts into the circlemud container.
# So the labels describe exactly the game we play. See DATASET.md for the
# provenance argument and the known gaps.
#
# We use the JSON rather than the .wld because the export has already solved the
# two parsing traps: extra-description keywords arrive pre-split into arrays, and
# `~`-terminated strings (which can contain `~`, `E`, `S`, and `#` in their text)
# are resolved. Cost of that convenience is 21 dropped rooms — documented below.
#
# Emits:
#   data/rooms.jsonl   one room per line
#   data/splits.json   frozen zone-level and room-level train/test splits
#   data/stats.json    corpus statistics (regenerated, not hand-maintained)

require "json"
require "set"
require "fileutils"

ROOT     = File.expand_path("../../../..", __dir__)
WORLD    = ENV["WORLD"] || File.join(ROOT, "week0_explore/preview/data/world/wld")
OUT      = File.join(__dir__, "data")
SEED     = 42

# Extra-descriptions that are out-of-character game furniture rather than scenery.
# A player exploring a room does not want `look credits`. These are FLAGGED, not
# dropped — §4 of DATASET.md argues the call is yours, not the extractor's.
META_KEYWORDS = %w[
  credits info menu news motd imotd policy handbook wizlist help
  background greeting login mapplan map plan
].to_set

def collapse(s)
  s.to_s.gsub(/\s+/, " ").strip
end

# Colour codes (@c @n @R ...) and box-drawing runs mark ASCII-art extra-descs
# (maps, signs rendered as art). Their "keywords" are real but the desc is not prose.
def ascii_art?(desc)
  d = desc.to_s
  return true if d.scan(/@[a-zA-Z]/).size >= 3
  return true if d.count("|+-_") > d.length / 6.0 && d.length > 40
  false
end

# ---------------------------------------------------------------- load

files = Dir[File.join(WORLD, "*.json")].sort
abort "no world JSON found at #{WORLD}" if files.empty?

raw = []
files.each do |f|
  begin
    JSON.parse(File.read(f)).each { |r| raw << [r, File.basename(f)] }
  rescue JSON::ParserError => e
    warn "SKIP #{File.basename(f)}: #{e.message}"
  end
end

# Room-name lookup so exits can carry destination names. Exit destinations are a
# FEATURE, not a subtraction — see DATASET.md §5 for the measurement that killed
# the subtraction idea.
names = raw.to_h { |r, _| [r["id"], collapse(r["name"])] }

# ---------------------------------------------------------------- transform

rooms = raw.map do |r, file|
  gold = (r["extra_descs"] || []).map do |e|
    aliases = Array(e["keywords"]).map { |k| k.to_s.downcase.strip }.reject(&:empty?).uniq
    {
      "aliases" => aliases,
      "desc"    => collapse(e["desc"]),
      "meta"    => aliases.any? { |a| META_KEYWORDS.include?(a) } || ascii_art?(e["desc"])
    }
  end.reject { |g| g["aliases"].empty? }

  exits = (r["exits"] || []).map do |x|
    to = x["room_linked"]
    { "dir" => x["dir"], "to" => to, "to_name" => names[to] }
  end.reject { |x| x["to"].nil? || x["to"].to_i <= 0 }

  {
    "vnum"      => r["id"],
    "zone"      => r["zone_number"],
    "zone_file" => file,
    "name"      => collapse(r["name"]),
    "desc"      => collapse(r["desc"]),
    "sector"    => r.dig("sector_type", "note"),
    "flags"     => Array(r["flags"]).map { |f| f["note"] }.compact,
    "gold"      => gold,
    "exits"     => exits
  }
end

# --- reachability ---------------------------------------------------------
# tbaMUD ships ~150 builder scratch zones ("... Description Room") that no player
# can walk to. They are 85% of the corpus and only 9.5% of them carry labels,
# versus 21.1% for the navigable world - so training on them both dilutes the
# signal and mis-states the base rate. Walk the exit graph from the mortal start
# room (3001, Temple of Midgaard); anything unreachable on foot is scratch space
# the agent will never stand in.
START = 3001
adj = rooms.to_h { |r| [r["vnum"], r["exits"].map { |e| e["to"] }] }
seen = { START => true }
queue = [START]
until queue.empty?
  (adj[queue.shift] || []).each { |v| queue << v if adj.key?(v) && !seen[v] && (seen[v] = true) }
end
rooms.each { |r| r["walkable"] = seen.key?(r["vnum"]) }

# A room with no description carries no signal and cannot be scored. None exist
# today; the guard is here so a future world edit fails loudly rather than
# silently adding unscoreable rows.
dropped = rooms.reject { |r| r["desc"].length > 20 }
rooms   = rooms.select { |r| r["desc"].length > 20 }

# ---------------------------------------------------------------- splits
#
# TWO splits, both frozen and committed. Zone-level is the headline: rooms in a
# zone share an author and vocabulary, so a room-level split leaks and flatters
# any memorising model. Measured on the smaller CircleMUD corpus, that leak was
# worth 8x in F1 (16.5% room vs 2.1% zone) for a plain dictionary.

def split_by(items, key, frac, seed)
  groups = items.map { |i| i[key] }.uniq.sort
  rng    = Random.new(seed)
  shuf   = groups.shuffle(random: rng)
  n      = (shuf.size * frac).round
  train  = shuf[0...n].to_set
  [items.select { |i| train.include?(i[key]) }, items.reject { |i| train.include?(i[key]) }]
end

walk = rooms.select { |r| r["walkable"] }
zone_tr, zone_te = split_by(rooms, "zone", 0.8, SEED)
walk_tr, walk_te = split_by(walk, "zone", 0.8, SEED)
room_tr, room_te = split_by(rooms.each_with_index.map { |r, i| r.merge("_i" => i) }, "_i", 0.8, SEED)

splits = {
  "seed"  => SEED,
  "note"  => "Zone split is the headline metric. Room split is reported alongside " \
             "to quantify the leak, never as the primary result.",
  "zone"  => { "train" => zone_tr.map { |r| r["vnum"] }.sort, "test" => zone_te.map { |r| r["vnum"] }.sort,
               "train_zones" => zone_tr.map { |r| r["zone"] }.uniq.sort,
               "test_zones"  => zone_te.map { |r| r["zone"] }.uniq.sort },
  "room"  => { "train" => room_tr.map { |r| r["vnum"] }.sort, "test" => room_te.map { |r| r["vnum"] }.sort },
  # Walkable-only, zone-level. This is the honest deployment distribution.
  "walk"  => { "train" => walk_tr.map { |r| r["vnum"] }.sort, "test" => walk_te.map { |r| r["vnum"] }.sort,
               "train_zones" => walk_tr.map { |r| r["zone"] }.uniq.sort,
               "test_zones"  => walk_te.map { |r| r["zone"] }.uniq.sort }
}

# ---------------------------------------------------------------- stats

def tokens(s) = s.downcase.scan(/[a-z]{3,}/).uniq

with_gold  = rooms.count { |r| !r["gold"].empty? }
gold_all   = rooms.sum { |r| r["gold"].size }
gold_real  = rooms.sum { |r| r["gold"].count { |g| !g["meta"] } }

# Reachability: can a text-based extractor even see this label? An extractor that
# only proposes words from the description can never emit an alias that is absent
# from it. This is the hard recall ceiling for EVERY tier including the LLM.
reach = 0
gold_scored = 0
rooms.each do |r|
  ws = tokens(r["desc"]).to_set
  r["gold"].reject { |g| g["meta"] }.each do |g|
    gold_scored += 1
    reach += 1 if g["aliases"].any? { |a| ws.include?(a) }
  end
end

# Ambiguity: the same word positive in one room, negative in another. This is what
# decides whether contextual models are necessary or a lexicon would do.
pos = Hash.new(0)
neg = Hash.new(0)
rooms.each do |r|
  p = r["gold"].reject { |g| g["meta"] }.flat_map { |g| g["aliases"] }.to_set
  tokens(r["desc"]).each { |w| p.include?(w) ? pos[w] += 1 : neg[w] += 1 }
end
ambiguous = pos.keys.count { |w| neg[w] > 0 }

tok_total = rooms.sum { |r| tokens(r["desc"]).size }
tok_pos   = pos.values.sum

stats = {
  "generated_at"       => Time.now.utc.iso8601,
  "source"             => WORLD.sub(ROOT + "/", ""),
  "rooms"              => rooms.size,
  "rooms_walkable"     => rooms.count { |r| r["walkable"] },
  "walkable_gold_density_pct" => (100.0 * walk.count { |r| !r["gold"].empty? } / walk.size).round(2),
  "rooms_dropped_nodesc" => dropped.size,
  "zones"              => rooms.map { |r| r["zone"] }.uniq.size,
  "rooms_with_gold"    => with_gold,
  "rooms_with_gold_pct" => (100.0 * with_gold / rooms.size).round(2),
  "gold_blocks_all"    => gold_all,
  "gold_blocks_scored" => gold_real,
  "gold_blocks_meta"   => gold_all - gold_real,
  "multi_alias_blocks" => rooms.sum { |r| r["gold"].count { |g| g["aliases"].size > 1 } },
  "recall_ceiling_pct" => (100.0 * reach / gold_scored).round(2),
  "unreachable_blocks" => gold_scored - reach,
  "token_positive_rate_pct" => (100.0 * tok_pos / tok_total).round(3),
  "distinct_positive_words" => pos.size,
  "ambiguous_positive_words" => ambiguous,
  "ambiguous_pct"      => (100.0 * ambiguous / pos.size).round(2),
  # Ranked by min(pos, neg): a word is genuinely contested only when BOTH counts
  # are substantial. Ranking by pos+neg instead just surfaces common words that
  # happened to be a keyword once ("see" 1+/2122-), which tells us nothing.
  "most_contested"     => pos.select { |w, c| c >= 5 }
                             .sort_by { |w, c| -[c, neg[w]].min }.first(12)
                             .map { |w, c| { "word" => w, "pos" => c, "neg" => neg[w],
                                             "purity" => (100.0 * c / (c + neg[w])).round(1) } },
  # Purity distribution over words that are positive at least 5 times. If most
  # sit near 50%, word identity is nearly useless alone and context is mandatory.
  "purity_of_frequent" => begin
    fr = pos.select { |w, c| c >= 5 }.map { |w, c| 100.0 * c / (c + neg[w]) }.sort
    fr.empty? ? nil : { "n" => fr.size, "p25" => fr[fr.size / 4].round(1),
                        "median" => fr[fr.size / 2].round(1), "p75" => fr[3 * fr.size / 4].round(1) }
  end,
  "distinct_aliases"   => rooms.flat_map { |r| r["gold"].reject { |g| g["meta"] }
                                                 .flat_map { |g| g["aliases"] } }.uniq.size,
  "split_sizes"        => {
    "zone" => { "train" => zone_tr.size, "test" => zone_te.size,
                "train_zones" => splits["zone"]["train_zones"].size,
                "test_zones"  => splits["zone"]["test_zones"].size },
    "room" => { "train" => room_tr.size, "test" => room_te.size }
  }
}

# ---------------------------------------------------------------- write

require "time"
FileUtils.mkdir_p(OUT)
File.open(File.join(OUT, "rooms.jsonl"), "w") { |f| rooms.each { |r| f.puts JSON.generate(r) } }
File.write(File.join(OUT, "splits.json"), JSON.pretty_generate(splits))
File.write(File.join(OUT, "stats.json"),  JSON.pretty_generate(stats))

puts JSON.pretty_generate(stats)
puts
puts "wrote #{OUT}/rooms.jsonl (#{rooms.size} rooms)"
puts "wrote #{OUT}/splits.json"
puts "wrote #{OUT}/stats.json"
