require "json"
require "digest"
require "fileutils"

# The `look_candidates` weights are 41MB against a 476KB repo, so they are not in
# git. What IS committed is manifest.json — the runtime contract (threshold,
# top_k, context fields, tokenizer regexes) plus the download URL and sha256.
# Integrity therefore comes from the manifest, not from wherever the file is
# hosted.
namespace :model do
  MODEL_DIR = File.expand_path("../../../../.boukensha/models/look_candidates", __dir__)

  desc "Download the look_candidates model named by its committed manifest"
  task :fetch do
    manifest_path = File.join(MODEL_DIR, "manifest.json")
    abort "no manifest at #{manifest_path}" unless File.exist?(manifest_path)

    manifest = JSON.parse(File.read(manifest_path))
    target   = File.join(MODEL_DIR, manifest.fetch("model_file"))
    url      = manifest["download_url"]

    if File.exist?(target) && Digest::SHA256.file(target).hexdigest == manifest["model_sha256"]
      next puts "already present and verified: #{target}"
    end
    abort "manifest has no download_url — build it locally with " \
          "docs/plans/week_2/nlp_look_candidates/build_model.rb" if url.to_s.empty?

    puts "downloading #{(manifest["model_bytes"] / 1e6).round(1)}MB from #{url}"
    FileUtils.mkdir_p(MODEL_DIR)
    tmp = "#{target}.part"
    # -L for the redirect chain a Drive share hands back.
    system("curl", "-fsSL", "-o", tmp, url) || abort("download failed")

    got = Digest::SHA256.file(tmp).hexdigest
    if got != manifest["model_sha256"]
      FileUtils.rm_f(tmp)
      # Hard failure, never a warning: a model that isn't the one the manifest
      # was measured against would score every room with the wrong calibration.
      abort "sha256 mismatch\n  expected #{manifest["model_sha256"]}\n  got      #{got}"
    end
    FileUtils.mv(tmp, target)
    puts "verified -> #{target}"
  end

  desc "Show the installed look_candidates artifact"
  task :status do
    manifest_path = File.join(MODEL_DIR, "manifest.json")
    next puts "no manifest — look_candidates will be empty" unless File.exist?(manifest_path)

    m = JSON.parse(File.read(manifest_path))
    present = File.exist?(File.join(MODEL_DIR, m["model_file"]))
    puts "#{m["base_model"]} (#{m["quantization"]}, seed #{m["chosen_seed"]}, built #{m["built_at"]})"
    puts "  weights   : #{present ? "installed" : "MISSING — run `rake model:fetch`"}"
    puts "  policy    : top-#{m["top_k"]} at score >= #{m["threshold"]}"
    e = m["eval"] || {}
    puts format("  measured  : P %.0f%%  R %.0f%%  F1 %.0f%%  speaks in %.0f%% of rooms  %.1fms/room",
                e["p"].to_f * 100, e["r"].to_f * 100, e["f1"].to_f * 100,
                e["speaks_pct"].to_f, e["ms_per_room"].to_f)
  end
end
