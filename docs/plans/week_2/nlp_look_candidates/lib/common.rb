# frozen_string_literal: true
#
# Shared dataset loading, candidate generation, and scoring for the tier bake-off.
# Every tier consumes the same candidate pool and the same metrics so the numbers
# are comparable. If you change candidate generation, every prior result is void.

require "json"
require "set"

module LC
  DIR   = File.expand_path("..", __dir__)
  DATA  = File.join(DIR, "data")

  # Deliberately minimal. Aggressive stopword removal would silently cut the
  # recall ceiling; these are words that cannot plausibly be an extra-description
  # keyword. Verified against the alias vocabulary: none of these appear as gold.
  STOP = %w[
    the and you are was were for that this from into onto with which who whom
    whose there here their they them its his her hers our ours your yours
    have has had been being can could would should will shall may might must
    not but any all some more most very just also than then when where what
    how why about above below over under after before while during
  ].to_set

  Room = Struct.new(:vnum, :zone, :name, :desc, :sector, :gold, :exits, keyword_init: true)

  def self.load_rooms
    File.readlines(File.join(DATA, "rooms.jsonl")).map do |l|
      h = JSON.parse(l)
      Room.new(
        vnum: h["vnum"], zone: h["zone"], name: h["name"], desc: h["desc"],
        sector: h["sector"],
        # meta blocks (credits/info/ascii-art) are excluded from scoring per DATASET.md 4.1
        gold: (h["gold"] || []).reject { |g| g["meta"] }.map { |g| g["aliases"].to_set },
        exits: (h["exits"] || [])
      )
    end
  end

  def self.splits = JSON.parse(File.read(File.join(DATA, "splits.json")))

  # Candidate pool for a room: every content word in the description.
  # Order preserved (first occurrence) so positional features are stable.
  def self.candidates(room)
    seen = Set.new
    room.desc.downcase.scan(/[a-z]{3,}/).select { |w| !STOP.include?(w) && seen.add?(w) }
  end

  # --- scoring ------------------------------------------------------------
  #
  # A gold block is HIT if any of its aliases was predicted (matches how the
  # game's own keyword lookup works, and DATASET.md 4.2's accepted convention).
  # A predicted word is a false positive only if it is in NO gold block.
  def self.score(rooms, preds)
    tp = fp = fn = 0
    rooms.each_with_index do |r, i|
      p = preds[i].to_set
      covered = r.gold.reduce(Set.new) { |a, s| a | s }
      hit = r.gold.count { |al| al.any? { |a| p.include?(a) } }
      tp += hit
      fn += r.gold.size - hit
      fp += p.count { |w| !covered.include?(w) }
    end
    prec = tp + fp > 0 ? tp.to_f / (tp + fp) : 0.0
    rec  = tp + fn > 0 ? tp.to_f / (tp + fn) : 0.0
    f1   = prec + rec > 0 ? 2 * prec * rec / (prec + rec) : 0.0
    { p: prec, r: rec, f1: f1, tp: tp, fp: fp, fn: fn }
  end

  # For scoring models that emit a score per candidate: sweep thresholds for the
  # best achievable F1, and evaluate a fixed top-k policy (the product setting -
  # look_candidates is probed serially at ~1.2s each, so an unbounded list is
  # worse than a short one).
  def self.score_ranked(rooms, ranked, k: 3)
    topk = ranked.map { |list| list.sort_by { |(_w, s)| -s }.first(k).map(&:first) }
    at_k = score(rooms, topk)

    all = ranked.flat_map { |l| l.map { |(_w, s)| s } }
    return [at_k, at_k, 0.0] if all.empty?
    lo, hi = all.minmax
    best = nil
    41.times do |i|
      t = lo + (hi - lo) * i / 40.0
      m = score(rooms, ranked.map { |l| l.select { |(_w, s)| s >= t }.map(&:first) })
      best = m if best.nil? || m[:f1] > best[:f1]
    end
    [at_k, best, pr_auc(rooms, ranked)]
  end

  # Average precision over the global ranking of all (room, word) pairs.
  # Threshold-free, so it compares models without a policy choice baked in.
  def self.pr_auc(rooms, ranked)
    pairs = []
    rooms.each_with_index do |r, i|
      covered = r.gold.reduce(Set.new) { |a, s| a | s }
      ranked[i].each { |(w, s)| pairs << [s, covered.include?(w) ? 1 : 0] }
    end
    total_pos = rooms.sum { |r| r.gold.size }
    return 0.0 if total_pos.zero?
    tp = 0
    ap = 0.0
    pairs.sort_by! { |(s, _)| -s }
    pairs.each_with_index do |(_s, y), i|
      next if y.zero?
      tp += 1
      ap += tp.to_f / (i + 1)
    end
    ap / total_pos
  end

  def self.ceiling(rooms)
    hit = tot = 0
    rooms.each do |r|
      c = candidates(r).to_set
      r.gold.each { |al| tot += 1; hit += 1 if al.any? { |a| c.include?(a) } }
    end
    tot.zero? ? 0.0 : hit.to_f / tot
  end

  # --- reporting ----------------------------------------------------------

  def self.report(label, splits_rooms, run)
    puts "\n#{'=' * 92}"
    puts "  #{label}"
    puts "=" * 92
    printf("  %-22s %-30s %8s %8s %8s %8s\n", "split", "policy", "P", "R", "F1", "PR-AUC")
    puts "  " + "-" * 88
    splits_rooms.each do |sname, (tr, te)|
      ranked = run.call(tr, te)
      at_k, best, auc = score_ranked(te, ranked, k: 3)
      printf("  %-22s %-30s %7.1f%% %7.1f%% %7.1f%% %7.1f%%\n",
             sname, "top-3 (product policy)", at_k[:p] * 100, at_k[:r] * 100, at_k[:f1] * 100, auc * 100)
      printf("  %-22s %-30s %7.1f%% %7.1f%% %7.1f%% %8s\n",
             "", "best threshold (oracle)", best[:p] * 100, best[:r] * 100, best[:f1] * 100, "")
    end
  end
end

module LC
  # Tag naming convention -> which frozen split its predictions belong to.
  # Centralised deliberately: scoring a tag against the wrong test set produces
  # plausible-looking but meaningless numbers.
  def self.split_for(tag)
    return "room" if tag.start_with?("room")
    return "walk" if tag.start_with?("walk")
    "zone"
  end
end
