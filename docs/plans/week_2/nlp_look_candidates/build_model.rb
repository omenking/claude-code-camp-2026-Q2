#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Builds the shippable `look_candidates` artifact end to end:
#
#   ruby build_model.rb [--seeds 1,2,3] [--out DIR] [--python PATH]
#
#   1. train each seed (run_t3.py --save)
#   2. score each with the SAME metrics as the bake-off, keep the MEDIAN seed
#   3. export fp32 + int8 ONNX and the vocab
#   4. re-score both artifacts THROUGH THE RUBY EXTRACTOR, sweeping thresholds
#   5. write model.onnx + vocab.json + manifest.json into --out
#
# Two decisions are baked in because measuring them is what this script exists
# for (docs/plans/week_2/look_candidates_runtime.md):
#
# - MEDIAN, not best. Seed-to-seed F1 swings +/-5 points; taking the best is
#   selecting on the test set.
# - Each artifact gets its OWN threshold. Dynamic quantization shifts the score
#   distribution, so an int8 model inheriting an fp32 threshold measures as
#   worse than it is (plan 5.3).
#
# Step 4 deliberately runs the production Ruby path rather than the Python one:
# the number written into the manifest is then a number the runtime can actually
# reproduce, not one from a scorer nothing ships.
require "json"
require "digest"
require "fileutils"
require "optparse"
require_relative "lib/common"

REPO = File.expand_path("../../../..", __dir__)
require File.join(REPO, "week2_capable/boukensha/lib/boukensha/extractors/word_piece")
require File.join(REPO, "week2_capable/boukensha/lib/boukensha/extractors/model")

opts = { seeds: [1, 2, 3], out: File.join(REPO, ".boukensha/models/look_candidates"),
         python: File.join(__dir__, "venv/bin/python"), split: "walk",
         base: "google/bert_uncased_L-8_H-512_A-8", epochs: 4,
         context: "name,exits", top_k: 3, min_precision: 0.40 }
OptionParser.new do |o|
  o.on("--seeds A,B,C", Array) { |v| opts[:seeds] = v.map(&:to_i) }
  o.on("--out DIR")            { |v| opts[:out] = v }
  o.on("--python PATH")        { |v| opts[:python] = v }
  o.on("--base MODEL")         { |v| opts[:base] = v }
  o.on("--skip-train")         { opts[:skip_train] = true }
end.parse!

WORK = File.join(__dir__, "build")
FileUtils.mkdir_p(WORK)

def sh(*cmd)
  puts "  $ #{cmd.join(" ")}"
  system(*cmd) || abort("FAILED: #{cmd.join(" ")}")
end

# --- 1. train ---------------------------------------------------------------
puts "\n=== 1. train #{opts[:seeds].size} seeds (#{opts[:base]}, split=#{opts[:split]}, ctx=#{opts[:context]})"
opts[:seeds].each do |seed|
  ckpt = File.join(WORK, "seed#{seed}")
  next puts "  seed #{seed}: cached" if opts[:skip_train] && File.exist?(File.join(ckpt, "config.json"))

  sh(opts[:python], File.join(__dir__, "run_t3.py"),
     "--split", opts[:split], "--epochs", opts[:epochs].to_s, "--model", opts[:base],
     "--use-context", "--context-fields", opts[:context], "--amp",
     "--seed", seed.to_s, "--tag", "build_seed#{seed}", "--save", ckpt)
end

# --- 2. pick the median seed ------------------------------------------------
puts "\n=== 2. score seeds, keep the median"
rooms = LC.load_rooms.to_h { |r| [r.vnum, r] }
test  = LC.splits[opts[:split]]["test"].map { |v| rooms[v] }.compact
preds = JSON.parse(File.read(File.join(LC::DATA, "t3_preds.json")))

# Best achievable F1 over a threshold grid, at the shipping top_k. This is the
# per-seed quality number; the winning THRESHOLD is re-derived in step 4 from
# the exported artifact, since export and quantization both move calibration.
GRID = (1..19).map { |i| i * 0.05 }

def sweep(test, ranked, top_k:, min_precision: 0.0)
  GRID.filter_map do |t|
    sel = ranked.map { |list| list.select { |(_w, s)| s >= t }.first(top_k).map(&:first) }
    m = LC.score(test, sel)
    next if m[:p] < min_precision

    { threshold: t.round(2), f1: m[:f1], p: m[:p], r: m[:r],
      speaks: sel.count { |s| !s.empty? }.fdiv(test.size),
      probes: sel.sum(&:size).fdiv(test.size) }
  end.max_by { |m| m[:f1] }
end

scored = opts[:seeds].map do |seed|
  ranked = test.map { |r| (preds.fetch("build_seed#{seed}")[r.vnum.to_s] || []).map { |w, s| [w, s.to_f] }.sort_by { |(_w, s)| -s } }
  best = sweep(test, ranked, top_k: opts[:top_k]) or abort("seed #{seed}: no threshold reached any precision")
  puts format("  seed %d: best F1 %.1f%% (P %.1f R %.1f) at >=%.2f", seed, best[:f1] * 100, best[:p] * 100, best[:r] * 100, best[:threshold])
  [seed, best]
end.sort_by { |(_s, m)| m[:f1] }

chosen_seed, chosen_stats = scored[scored.size / 2]
puts "  -> median seed #{chosen_seed} (F1 #{(chosen_stats[:f1] * 100).round(1)}%)"

# The bake-off's own reproduced range (plan 4). A run outside it means something
# broke — bad split, wrong context fields, corpus regenerated — and a silently
# broken retrain must not reach the manifest.
BAND = (0.35..0.60)
unless BAND.cover?(chosen_stats[:f1])
  abort "median F1 #{(chosen_stats[:f1] * 100).round(1)}% is outside the expected #{BAND} band - refusing to ship"
end

# --- 3. export --------------------------------------------------------------
puts "\n=== 3. export ONNX (fp32 + int8) and vocab"
export = File.join(WORK, "export")
sh(opts[:python], File.join(__dir__, "export_onnx.py"), File.join(WORK, "seed#{chosen_seed}"), export)

# --- 4. sweep each artifact through the RUBY runtime ------------------------
puts "\n=== 4. re-score through the Ruby extractor, sweep each artifact"
vocab = JSON.parse(File.read(File.join(export, "vocab.json")))
input = JSON.parse(File.read(File.join(LC::DATA, "t3_input.json")))[opts[:split]]["test"]
by_vnum = input.to_h { |r| [r["vnum"], r] }

variants = { "fp32" => "model_fp32.onnx", "int8" => "model_int8.onnx" }.filter_map do |label, file|
  model = Boukensha::Extractors::Model.new(
    onnx_path: File.join(export, file), vocab: vocab,
    threshold: 0.0, top_k: opts[:top_k], max_len: 256,
    context_fields: opts[:context].split(",")
  )
  t0 = Time.now
  ranked = test.map do |room|
    src = by_vnum.fetch(room.vnum)
    model.score(name: src["name"], description: src["desc"],
                exit_targets: (src["exits"] || []).each_with_index.to_h { |d, i| [i.to_s, d] })
  end
  ms = (Time.now - t0) * 1000 / test.size

  best = sweep(test, ranked, top_k: opts[:top_k], min_precision: opts[:min_precision])
  unless best
    puts format("  %-4s: no threshold reaches P >= %.0f%% - skipped", label, opts[:min_precision] * 100)
    next
  end
  puts format("  %-4s: F1 %.1f%%  P %.1f%%  R %.1f%%  at >=%.2f  speaks %.0f%%  probes/room %.2f  (%.1f ms/room)",
              label, best[:f1] * 100, best[:p] * 100, best[:r] * 100, best[:threshold],
              best[:speaks] * 100, best[:probes], ms)
  [label, file, best, ms]
end
abort "no artifact cleared the precision floor" if variants.empty?

# Smallest artifact that clears the precision floor and is within 2 F1 points of
# the best. int8 is a quarter the size; paying 165MB for noise is not a trade.
top = variants.max_by { |(_l, _f, m, _ms)| m[:f1] }
label, file, stats, ms = variants.select { |(_l, _f, m, _ms)| m[:f1] >= top[2][:f1] - 0.02 }
                                 .min_by { |(_l, f, _m, _ms)| File.size(File.join(export, f)) }
puts "  -> shipping #{label} (#{(File.size(File.join(export, file)) / 1e6).round(1)} MB)"

# --- 5. write the artifact --------------------------------------------------
puts "\n=== 5. write #{opts[:out]}"
FileUtils.mkdir_p(opts[:out])
FileUtils.cp(File.join(export, file), File.join(opts[:out], "model.onnx"))
FileUtils.cp(File.join(export, "vocab.json"), File.join(opts[:out], "vocab.json"))

manifest = {
  "built_at" => Time.now.utc.strftime("%FT%TZ"),
  "git_sha" => `git -C #{REPO} rev-parse --short HEAD`.strip,
  "base_model" => opts[:base],
  "split" => opts[:split], "seeds" => opts[:seeds], "chosen_seed" => chosen_seed,
  "quantization" => label,
  "model_file" => "model.onnx", "vocab_file" => "vocab.json",
  "model_sha256" => Digest::SHA256.file(File.join(opts[:out], "model.onnx")).hexdigest,
  "model_bytes" => File.size(File.join(opts[:out], "model.onnx")),
  # Filled in by hand once the file is uploaded; `rake model:fetch` reads it.
  "download_url" => (JSON.parse(File.read(File.join(opts[:out], "manifest.json")))["download_url"] rescue nil),
  "context_fields" => opts[:context].split(","),
  "max_len" => 256,
  "word_regex" => Boukensha::Extractors::Model::WORD.source,
  "candidate_regex" => Boukensha::Extractors::Model::CANDIDATE.source,
  "stopwords_sha256" => Digest::SHA256.hexdigest(Boukensha::Extractors::Model::STOP.to_a.sort.join(" ")),
  "threshold" => stats[:threshold], "top_k" => opts[:top_k],
  "eval" => {
    "scorer" => "ruby", "rooms" => test.size,
    "rooms_with_gold" => test.count { |r| !r.gold.empty? },
    "p" => stats[:p].round(4), "r" => stats[:r].round(4), "f1" => stats[:f1].round(4),
    "speaks_pct" => (stats[:speaks] * 100).round(1),
    "probes_per_room" => stats[:probes].round(2),
    "ms_per_room" => ms.round(1)
  }
}
File.write(File.join(opts[:out], "manifest.json"), JSON.pretty_generate(manifest) + "\n")
puts JSON.pretty_generate(manifest)
