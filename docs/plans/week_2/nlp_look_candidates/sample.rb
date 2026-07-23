#!/usr/bin/env ruby
# frozen_string_literal: true
#
# sample.rb — human-readable slice of the dataset for eyeball review.
#
#   ruby sample.rb [N] > data/sample.txt
#
# Prints rooms with gold labels, the description, which aliases are reachable
# from the description text, and which are not. The unreachable ones are the
# ones no text extractor can ever get right — worth reading a few to judge
# whether that ceiling is fair or an artifact of how we tokenise.

require "json"
require "set"

N     = (ARGV[0] || 40).to_i
rooms = File.readlines(File.join(__dir__, "data/rooms.jsonl")).map { |l| JSON.parse(l) }
srand(7)

with_gold = rooms.select { |r| r["gold"].any? { |g| !g["meta"] } }

puts "=" * 78
puts "look_candidates dataset — review sample"
puts "#{with_gold.size} of #{rooms.size} rooms carry at least one scoreable label"
puts "showing #{N} at random (seed 7)"
puts "=" * 78

with_gold.sample(N).sort_by { |r| r["vnum"] }.each do |r|
  ws = r["desc"].downcase.scan(/[a-z]{3,}/).to_set
  puts
  puts "-" * 78
  puts "##{r['vnum']}  #{r['name']}   [zone #{r['zone']} / #{r['sector']}]"
  puts "-" * 78
  puts r["desc"].scan(/.{1,76}(?:\s|$)/).map(&:strip).join("\n")
  puts
  r["gold"].each do |g|
    hit  = g["aliases"].any? { |a| ws.include?(a) }
    mark = g["meta"] ? "META" : (hit ? " OK " : "MISS")
    puts "  [#{mark}] #{g['aliases'].join(', ')}"
    puts "         -> #{g['desc'][0, 66]}#{'...' if g['desc'].length > 66}"
  end
  ex = r["exits"].map { |x| x["to_name"] }.compact.uniq
  puts "  exits: #{ex.join(' | ')}" unless ex.empty?
end

puts
puts "=" * 78
puts "OK   = at least one alias appears verbatim in the description (reachable)"
puts "MISS = no alias appears in the description -> unreachable by any text extractor"
puts "META = out-of-character (credits/info/map art); excluded from scoring"
puts "=" * 78
