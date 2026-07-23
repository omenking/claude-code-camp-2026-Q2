#!/usr/bin/env ruby
# frozen_string_literal: true
# T3 scorer - reads data/t3_preds.json (written by run_t3.py) and scores it with
# the SAME metrics and candidate pool as every other tier.
require_relative "lib/common"
require "json"

rooms = LC.load_rooms
by_v  = rooms.to_h { |r| [r.vnum, r] }
sp    = LC.splits
preds = JSON.parse(File.read(File.join(LC::DATA, "t3_preds.json")))

avail = {}
{ "zone (headline)" => "zone", "room (leaky)" => "room" }.each do |label, key|
  next unless preds[key]
  te = sp[key]["test"].map { |v| by_v[v] }.compact
  avail[label] = [[], te]
end
abort "no predictions found - run run_t3.py first" if avail.empty?

LC.report("T3 - BERT-mini token classification (contextual)", avail, lambda { |_tr, te|
  key = te.equal?(avail["zone (headline)"]&.last) ? "zone" : "room"
  te.map { |r| (preds[key][r.vnum.to_s] || []).map { |w, s| [w, s.to_f] } }
})
