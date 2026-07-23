#!/usr/bin/env ruby
# Export the exact same rooms/candidates/gold the Ruby tiers use, so T3 is scored
# on an identical candidate pool and identical metrics.
require_relative "lib/common"
require "json"
rooms = LC.load_rooms
by_v  = rooms.to_h { |r| [r.vnum, r] }
sp    = LC.splits
pack  = lambda do |vnums|
  vnums.map { |v| by_v[v] }.compact.map do |r|
    { "vnum" => r.vnum, "desc" => r.desc,
      "name" => r.name, "sector" => r.sector,
      "exits" => r.exits.map { |e| e["to_name"] }.compact.uniq,
      "cands" => LC.candidates(r),
      "gold"  => r.gold.map(&:to_a) }
  end
end
out = { "zone" => { "train" => pack.call(sp["zone"]["train"]), "test" => pack.call(sp["zone"]["test"]) },
        "room" => { "train" => pack.call(sp["room"]["train"]), "test" => pack.call(sp["room"]["test"]) },
        "walk" => { "train" => pack.call(sp["walk"]["train"]), "test" => pack.call(sp["walk"]["test"]) } }
File.write("data/t3_input.json", JSON.generate(out))
puts "wrote data/t3_input.json  zone train=#{out['zone']['train'].size} test=#{out['zone']['test'].size}"
