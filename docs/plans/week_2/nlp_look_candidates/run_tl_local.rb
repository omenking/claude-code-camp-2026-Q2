#!/usr/bin/env ruby
# frozen_string_literal: true
#
# TL(local) — zero-shot LLM reference using the local ollama container.
#   ruby run_tl_local.rb [N_ROOMS] [MODEL]
#
# Two jobs:
#   1. The LLM reference point README 8 item 10 calls for, at zero API cost.
#   2. A cheap proxy for the authorial-noise ceiling (README 7.4). A capable
#      zero-shot model has strong priors about what a MUD builder would bother
#      to describe. If it ALSO lands near ~25% precision, that is evidence the
#      remaining error is the builder's coin-flip rather than model capacity -
#      and no amount of scaling fixes it.
#
# Emits a SET, not scores, so PR-AUC does not apply; scored on the same P/R/F1.

require_relative "lib/common"
require "json"
require "net/http"

N     = (ARGV[0] || 300).to_i
MODEL = ARGV[1] || "mistral:7b"
HOST  = ENV["OLLAMA_HOST"] || "http://localhost:11434"

rooms = LC.load_rooms
by_v  = rooms.to_h { |r| [r.vnum, r] }
te    = LC.splits["zone"]["test"].map { |v| by_v[v] }.compact
srand(11)
# Stratify: keep the natural base rate rather than oversampling rooms with gold,
# otherwise precision is measured on an easier distribution than production.
sample = te.sample(N)

PROMPT = <<~P
  In a text adventure (MUD), room descriptions sometimes contain scenery objects
  that the player can LOOK AT for extra detail (a statue, a sign, an altar, a
  fountain). Most rooms have none at all.

  Room: %<name>s
  Description: %<desc>s

  List ONLY nouns from the description that a builder would most likely have
  written a separate examinable description for. Reply with a JSON array of
  lowercase single words, at most 3. If none, reply [].
P

def ask(model, prompt)
  uri = URI("#{HOST}/api/generate")
  req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
  # think:false is REQUIRED for reasoning models (qwen3.5 etc). Without it the
  # token budget is consumed by a hidden reasoning block and `response` comes
  # back empty with done_reason="length" - which silently scores as zero.
  req.body = JSON.generate(model: model, prompt: prompt, stream: false, think: false,
                           options: { temperature: 0.0, num_predict: 256 })
  res = Net::HTTP.start(uri.hostname, uri.port, read_timeout: 180) { |h| h.request(req) }
  body = JSON.parse(res.body)
  raise "ollama error: #{body['error']}" if body["error"]
  raise "empty response (done_reason=#{body['done_reason']})" if body["response"].to_s.strip.empty?
  body["response"].to_s
rescue StandardError => e
  @fails = (@fails || 0) + 1
  raise "aborting: #{e.message}" if @fails > 3   # do not silently score zeros
  warn "  [tl] request failed: #{e.class} #{e.message}"
  ""
end

preds = []
t0 = Time.now
sample.each_with_index do |r, i|
  raw = ask(MODEL, format(PROMPT, name: r.name, desc: r.desc))
  words = (raw[/\[.*?\]/m] ? (JSON.parse(raw[/\[.*?\]/m]) rescue []) : [])
  words = words.select { |w| w.is_a?(String) }.map { |w| w.downcase.strip }
  # Restrict to the shared candidate pool so TL is scored on the same surface as
  # every other tier - an LLM inventing a word not in the description would
  # otherwise be scored as a false positive no other tier could produce.
  cands = LC.candidates(r).to_set
  preds << words.select { |w| cands.include?(w) }.first(3)
  warn "  [tl] #{i + 1}/#{sample.size}  #{(Time.now - t0).round}s" if ((i + 1) % 50).zero?
end

m = LC.score(sample, preds)
gold_rooms = sample.count { |r| !r.gold.empty? }
puts "\n#{'=' * 84}"
puts "  TL(local) — #{MODEL}, zero-shot, #{sample.size} rooms from the zone test split"
puts "=" * 84
puts format("  P=%.1f%%  R=%.1f%%  F1=%.1f%%   (tp=%d fp=%d fn=%d)",
            m[:p] * 100, m[:r] * 100, m[:f1] * 100, m[:tp], m[:fp], m[:fn])
puts format("  emitted something in %d/%d rooms; %d rooms actually have gold (%.1f%%)",
            preds.count { |p| !p.empty? }, sample.size, gold_rooms,
            100.0 * gold_rooms / sample.size)
puts format("  elapsed %ds (%.1fs/room)", (Time.now - t0).round, (Time.now - t0) / sample.size)
