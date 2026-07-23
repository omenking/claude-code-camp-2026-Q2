#!/usr/bin/env ruby
# frozen_string_literal: true
#
# TL(haiku) — the paid LLM reference point, on the SAME rooms and SAME scorer as
# every other tier.
#
#   ruby run_tl_haiku.rb --dry-run            # cost estimate, no API call
#   ruby run_tl_haiku.rb --mode single        # ONE call containing all N rooms
#   ruby run_tl_haiku.rb --mode multi         # N calls, conversation accumulates
#   ruby run_tl_haiku.rb --mode both -n 30
#
# Why two modes:
#   single — all rooms batched into one request. The task is independent per room,
#            so this is the cheap-and-correct shape. One prompt, one answer.
#   multi  — one room per turn with history retained. Costs far more (each turn
#            resends the whole conversation, so tokens grow quadratically) but
#            tests whether the model gets better by seeing its own prior answers.
#
# Cost control: both modes run on the SAME sampled rooms so the comparison is
# fair, --dry-run estimates spend before committing, and the script prints actual
# token usage and dollars from the API's own usage block.
#
# Uses raw Net::HTTP to match the existing in-repo client
# (week2_capable/boukensha/lib/boukensha/backends/anthropic.rb) rather than adding
# an SDK dependency to these otherwise dependency-light harness scripts.

require_relative "lib/common"
require "json"
require "net/http"
require "set"

MODEL     = "claude-haiku-4-5"
IN_PER_M  = 1.00   # USD per 1M input tokens
OUT_PER_M = 5.00   # USD per 1M output tokens
ENV_FILE  = File.expand_path("../../../../.boukensha/.env", __dir__)

# ---------------------------------------------------------------- args

opts = { mode: "single", n: 30, dry: false, batch: 40 }
ARGV.each_with_index do |a, i|
  case a
  when "--mode"    then opts[:mode] = ARGV[i + 1]
  when "-n"        then opts[:n] = ARGV[i + 1].to_i
  when "--batch"   then opts[:batch] = ARGV[i + 1].to_i
  when "--dry-run" then opts[:dry] = true
  end
end

def api_key
  raise "missing #{ENV_FILE}" unless File.exist?(ENV_FILE)
  line = File.readlines(ENV_FILE).find { |l| l =~ /\AANTHROPIC_API_KEY\s*=/ }
  raise "ANTHROPIC_API_KEY not in #{ENV_FILE}" unless line
  line.split("=", 2)[1].strip.gsub(/\A["']|["']\z/, "")
end

# ---------------------------------------------------------------- data
#
# Same walkable test split every other tier is scored on, same seed for both
# modes so single vs multi is a like-for-like comparison.

rooms = LC.load_rooms
by_v  = LC.splits["walk"]["test"].map { |v| rooms.find { |r| r.vnum == v } }.compact
srand(11)
SAMPLE = by_v.shuffle.first(opts[:n])

BASE_RULES = <<~S.strip
  You identify scenery in a text-adventure (MUD) room description that the game
  author probably wrote a separate examinable description for — things a player
  could LOOK AT for extra detail (a statue, a sign, an altar, a fountain).

  Rules:
  - Only use words that appear in the description itself.
  - Most rooms have NOTHING examinable. Returning an empty list is the common,
    correct answer — do not force a guess.
  - Ignore exits, directions, and references to neighbouring rooms.
  - At most 3 single lowercase words per room.
S

# Worked examples, all drawn from the walkable TRAIN split (vnums noted) so no
# test room ever appears in the prompt. Chosen to cover the full range:
#   - two empty rooms that are dense with tempting nouns (the majority case, and
#     the one the model gets wrong by over-firing)
#   - two single-object rooms where distractors outnumber the real answer
#   - one two-object room
#   - one four-object room, capped at 3 per the rule above
# #1500 and #3040 are deliberately adjacent: "wall"/"waters" are scenery prose in
# one and genuinely examinable in the other. That contrast is the actual task.
FEWSHOT = <<~S.strip
  Worked examples:

  Room: A Road Leading From The Bank                                    [train #1500]
  You find yourself on a small road leading away from the edge of the River of
  Lost Souls. The dark waters of the River can be seen and heard just south of
  here. Looking to the east and west, the road continues on.
  -> []
  (Nothing here was given its own description. "road", "waters" and "river" are
  scene-setting prose and directional reference, not examinable objects.)

  Room: A Long Road                                                     [train #1501]
  You stand here in spiritual emptiness, beginning a long and dangerous path.
  Your honest submission has already been made, but the truth of your heart has
  yet to be told. Leave here now, and forever hold your peace.
  -> []

  Room: A Guest Bedroom                                                 [train #2536]
  You are in a small guest bedroom. A small cot is in one corner, and a dusty
  mirror on one wall, other than that the room looks quite bare, and unused.
  -> ["mirror"]
  ("cot", "wall" and "room" are present but only the mirror was written up.)

  Room: A Cul De Sac                                                    [train #2541]
  You are in a small cul de sac. A window to the east is letting in moonlight
  and a pleasant breeze. Through it, the surrounding country side can be seen.
  -> ["window"]

  Room: The Bakery                                                      [train #3009]
  You are standing inside the small bakery. A sweet scent of danish and fine
  bread fills the room. The bread and Danish are arranged in fine order on the
  shelves, and seem to be of the finest quality. A sign is on the wall.
  -> ["danish", "sign"]

  Room: Inside The West Gate Of Midgaard                                [train #3040]
  You are by two small towers that have been built into the city wall and
  connected with a footbridge across the heavy wooden gate. Main Street leads
  east and Wall Road leads south from here.
  -> ["gate", "towers", "wall"]
  (Here the wall IS examinable — the same noun can be scenery in one room and a
  described object in another. Judge from the room, not the word.)
S

SYSTEM = ENV["NO_FEWSHOT"] ? BASE_RULES : "#{BASE_RULES}\n\n#{FEWSHOT}"

def room_block(r, idx = nil)
  head = idx ? "Room #{idx}: #{r.name}" : "Room: #{r.name}"
  "#{head}\n#{r.desc}"
end

def post(key, body)
  uri = URI("https://api.anthropic.com/v1/messages")
  req = Net::HTTP::Post.new(uri,
                            "content-type"      => "application/json",
                            "x-api-key"         => key,
                            "anthropic-version" => "2023-06-01")
  req.body = JSON.generate(body)
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 300) { |h| h.request(req) }
  parsed = JSON.parse(res.body)
  raise "API error: #{parsed.dig('error', 'message') || res.body[0, 300]}" if parsed["type"] == "error"
  parsed
end

def text_of(resp)
  Array(resp["content"]).select { |c| c["type"] == "text" }.map { |c| c["text"] }.join
end

def cost_of(usage)
  (usage["input_tokens"].to_i / 1e6 * IN_PER_M) + (usage["output_tokens"].to_i / 1e6 * OUT_PER_M)
end

# Restrict to the shared candidate pool: an LLM inventing a word not present in
# the description would otherwise be charged a false positive no other tier could
# produce, which would understate it unfairly.
def clean(words, room)
  pool = LC.candidates(room).to_set
  Array(words).select { |w| w.is_a?(String) }
              .map { |w| w.downcase.strip }
              .select { |w| pool.include?(w) }
              .uniq.first(3)
end

# Persist predictions. Scoring and discarding them means any later question
# ("do these agree with the trained model?") costs another API run - which is
# exactly what happened the first time.
def save_preds(tag, sample, preds)
  path = File.join(LC::DATA, "tl_haiku_preds.json")
  all = File.exist?(path) ? JSON.parse(File.read(path)) : {}
  all[tag] = sample.each_with_index.to_h { |r, i| [r.vnum.to_s, preds[i]] }
  File.write(path, JSON.generate(all))
  warn "  [saved] #{path} (#{tag}: #{sample.size} rooms)"
end

def report(label, sample, preds, in_tok, out_tok, calls, secs)
  m = LC.score(sample, preds)
  cost = in_tok / 1e6 * IN_PER_M + out_tok / 1e6 * OUT_PER_M
  puts "\n#{'=' * 78}"
  puts "  #{label}"
  puts "=" * 78
  puts format("  P=%.1f%%  R=%.1f%%  F1=%.1f%%   (tp=%d fp=%d fn=%d)",
              m[:p] * 100, m[:r] * 100, m[:f1] * 100, m[:tp], m[:fp], m[:fn])
  puts format("  spoke in %d/%d rooms; %d rooms have gold",
              preds.count { |p| !p.empty? }, sample.size, sample.count { |r| !r.gold.empty? })
  puts format("  %d call(s), %d in + %d out tokens, $%.4f total ($%.5f/room), %.1fs",
              calls, in_tok, out_tok, cost, cost / sample.size, secs)
  m.merge(cost: cost, in: in_tok, out: out_tok)
end

# ---------------------------------------------------------------- dry run

if opts[:dry]
  chars = SAMPLE.sum { |r| room_block(r).length }
  est_in = (SYSTEM.length + chars) / 3.6
  single_in = est_in
  # multi-turn resends the whole conversation each turn -> ~n/2 times the tokens
  multi_in = (0...SAMPLE.size).sum { |i| (SYSTEM.length / 3.6) + (chars / SAMPLE.size / 3.6) * (i + 1) + 20 * i }
  est_out = SAMPLE.size * 18
  puts "rooms sampled: #{SAMPLE.size}  (#{SAMPLE.count { |r| !r.gold.empty? }} have gold)"
  puts format("  single-turn: ~%d in + ~%d out  => ~$%.4f  (1 call)",
              single_in, est_out, single_in / 1e6 * IN_PER_M + est_out / 1e6 * OUT_PER_M)
  puts format("  multi-turn : ~%d in + ~%d out  => ~$%.4f  (%d calls)",
              multi_in, est_out, multi_in / 1e6 * IN_PER_M + est_out / 1e6 * OUT_PER_M, SAMPLE.size)
  puts "\n(no API calls made; drop --dry-run to execute)"
  exit
end

KEY = api_key
results = {}

# ---------------------------------------------------------------- single turn

if %w[single both].include?(opts[:mode])
  t0 = Time.now
  preds = []
  in_tok = out_tok = calls = 0
  # Batched rather than one giant call: asking for 340 numbered entries in a
  # single response invites drift and truncation, and a malformed batch costs
  # 1/9th of the run instead of all of it. Cost difference is ~1.5c/run.
  SAMPLE.each_slice(opts[:batch]).with_index do |chunk, bi|
    listing = chunk.each_with_index.map { |r, i| room_block(r, i + 1) }.join("\n\n")
    user = "#{listing}\n\nReturn ONLY a JSON object mapping each room number to its " \
           "array of examinable words, e.g. {\"1\": [\"statue\"], \"2\": []}. " \
           "Include every room number from 1 to #{chunk.size}."
    resp = post(KEY, model: MODEL, max_tokens: 8192, system: SYSTEM,
                     messages: [{ role: "user", content: user }])
    raw = text_of(resp)
    obj = (JSON.parse(raw[/\{.*\}/m].to_s) rescue {})
    warn "  [single] batch #{bi + 1}: unparseable response" if obj.empty? && chunk.any? { |r| !r.gold.empty? }
    # A room missing from the response is scored as "predicted nothing", never skipped.
    chunk.each_with_index { |r, i| preds << clean(obj[(i + 1).to_s], r) }
    u = resp["usage"] || {}
    in_tok += u["input_tokens"].to_i
    out_tok += u["output_tokens"].to_i
    calls += 1
    warn "  [single] batch #{bi + 1}/#{(SAMPLE.size / opts[:batch].to_f).ceil} done"
  end
  save_preds(ENV["NO_FEWSHOT"] ? "single_nofewshot" : "single_fewshot", SAMPLE, preds)
  results[:single] = report("TL(haiku) SINGLE-TURN — #{SAMPLE.size} rooms in #{calls} batched call(s)" \
                            "#{ENV['NO_FEWSHOT'] ? ' [no few-shot]' : ' [few-shot]'}",
                            SAMPLE, preds, in_tok, out_tok, calls, Time.now - t0)
end

# ---------------------------------------------------------------- multi turn

if %w[multi both].include?(opts[:mode])
  t0 = Time.now
  msgs = []
  preds = []
  in_tok = out_tok = 0
  SAMPLE.each_with_index do |r, i|
    msgs << { role: "user",
              content: "#{room_block(r)}\n\nReply with ONLY a JSON array of examinable words (max 3), or []." }
    resp = post(KEY, model: MODEL, max_tokens: 1024, system: SYSTEM, messages: msgs)
    raw = text_of(resp)
    msgs << { role: "assistant", content: raw }
    preds << clean((JSON.parse(raw[/\[.*?\]/m].to_s) rescue []), r)
    u = resp["usage"] || {}
    in_tok += u["input_tokens"].to_i
    out_tok += u["output_tokens"].to_i
    warn "  [multi] #{i + 1}/#{SAMPLE.size}" if ((i + 1) % 10).zero?
  end
  save_preds("multi", SAMPLE, preds)
  results[:multi] = report("TL(haiku) MULTI-TURN — #{SAMPLE.size} rooms, #{SAMPLE.size} calls, history retained",
                           SAMPLE, preds, in_tok, out_tok, SAMPLE.size, Time.now - t0)
end

# ---------------------------------------------------------------- baseline

preds_file = File.join(LC::DATA, "t3_preds.json")
if File.exist?(preds_file)
  p3 = JSON.parse(File.read(preds_file))["walk_medium_ctx"]
  if p3
    ranked = SAMPLE.map { |r| (p3[r.vnum.to_s] || []).map { |w, s| [w, s.to_f] } }
    sel = ranked.map { |l| l.select { |(_w, s)| s >= 0.3 }.sort_by { |(_w, s)| -s }.first(3).map(&:first) }
    m = LC.score(SAMPLE, sel)
    puts "\n  trained model (BERT-medium, walkable, >=0.3) on these same #{SAMPLE.size} rooms:"
    puts format("  P=%.1f%%  R=%.1f%%  F1=%.1f%%   cost $0.0000  ~10ms/room",
                m[:p] * 100, m[:r] * 100, m[:f1] * 100)
  end
end

if results.size == 2
  puts format("\n  multi-turn cost %.1fx single-turn for %+.1f F1 points",
              results[:multi][:cost] / results[:single][:cost],
              (results[:multi][:f1] - results[:single][:f1]) * 100)
end
