#!/usr/bin/env ruby
# frozen_string_literal: true
#
# "There's a locked door - what could contain the key?"
#   ruby keys_and_containers.rb [door_room_vnum]
#
# Unlike look_candidates, this is NOT a language problem. Doors declare their key
# object by vnum, objects declare their type (CONTAINER / KEY), and zone resets
# declare exactly where every object spawns - including nested inside containers
# and inside mob inventories. So "where is the key" is a graph lookup over world
# data, with no model and no guessing.
#
# Two distinct questions, which need different answers:
#   ORACLE  - where does this key actually spawn? (world data; omniscient)
#   IN-ROOM - what in this room could hold something? (containers are real listed
#             objects, so the MUD already tells us - no inference required)

require "json"
require "set"

W = File.expand_path("../../../../week0_explore/preview/data/world", __dir__)

def load_all(kind)
  Dir[File.join(W, kind, "*.json")].flat_map { |f| JSON.parse(File.read(f)) rescue [] }
end

objs  = load_all("obj").to_h { |o| [o["id"], o] }
wlds  = load_all("wld").to_h { |r| [r["id"], r] }
mobs  = load_all("mob").to_h { |m| [m["id"], m] }
zones = load_all("zon")

def otype(o) = (o&.dig("type", "note")).to_s
def oname(o) = (o&.dig("short_desc") || o&.dig("long_desc") || "?").to_s.strip

# --- where does each object spawn? ---------------------------------------
# Walks the reset tree: objects in rooms, objects nested in container contents,
# and objects in mob inventory/equipment.
placements = Hash.new { |h, k| h[k] = [] }

walk = lambda do |entry, ctx|
  id = entry["id"]
  placements[id] << ctx if id
  (entry["contents"] || []).each do |inner|
    walk.call(inner, { in: :container, container: id, room: ctx[:room] })
  end
end

zones.each do |z|
  (z["objects"] || []).each { |o| walk.call(o, { in: :room, room: o["room"] }) }
  (z["mobs"] || []).each do |m|
    (m["inventory"] || []).each { |o| walk.call(o, { in: :mob_inv, mob: m["mob"], room: m["room"] }) }
    (m["equipped"] || []).each { |o| walk.call(o, { in: :mob_eq,  mob: m["mob"], room: m["room"] }) }
  end
end

# --- every keyed door in the world ---------------------------------------
doors = []
wlds.each_value do |r|
  (r["exits"] || []).each do |e|
    k = e["key_number"].to_i
    doors << { room: r["id"], room_name: r["name"], key: k, flag: e.dig("door_flag", "note") } if k > 0
  end
end

if ARGV[0]
  # ---- single door lookup -----------------------------------------------
  vnum = ARGV[0].to_i
  found = doors.select { |d| d[:room] == vnum }
  abort "no keyed door in room #{vnum}" if found.empty?
  found.each do |d|
    key = objs[d[:key]]
    puts "Room #{d[:room]}: #{d[:room_name]}   (#{d[:flag]})"
    puts "  needs key ##{d[:key]}: #{key ? "#{oname(key)}  aliases=#{(key['aliases'] || []).inspect}" : 'OBJECT NOT DEFINED'}"
    locs = placements[d[:key]]
    if locs.empty?
      puts "  -> key never spawns via zone resets (script-placed, quest reward, or unreachable)"
    end
    locs.each do |l|
      case l[:in]
      when :room      then puts "  -> lies in room #{l[:room]} (#{wlds[l[:room]]&.dig('name')})"
      when :container then puts "  -> INSIDE container ##{l[:container]} \"#{oname(objs[l[:container]])}\" in room #{l[:room]} (#{wlds[l[:room]]&.dig('name')})"
      when :mob_inv   then puts "  -> carried by mob ##{l[:mob]} \"#{mobs[l[:mob]]&.dig('short_desc')}\" in room #{l[:room]}"
      when :mob_eq    then puts "  -> worn by mob ##{l[:mob]} \"#{mobs[l[:mob]]&.dig('short_desc')}\" in room #{l[:room]}"
      end
    end
    # in-room answer: containers that spawn in the same room as the door
    here = (zones.flat_map { |z| z["objects"] || [] }).select { |o| o["room"] == d[:room] }
    conts = here.select { |o| otype(objs[o["id"]]) == "CONTAINER" }
    puts "  containers visible in this room: " +
         (conts.empty? ? "(none)" : conts.map { |c| "\"#{oname(objs[c['id']])}\"" }.join(", "))
    puts
  end
  exit
end

# ---- corpus-wide: where do keys live? -----------------------------------
uniq = doors.uniq { |d| [d[:room], d[:key]] }
tally = Hash.new(0)
uniq.each do |d|
  locs = placements[d[:key]]
  if !objs[d[:key]]           then tally[:no_such_object] += 1
  elsif locs.empty?           then tally[:never_spawns] += 1
  elsif locs.any? { |l| l[:in] == :container } then tally[:in_container] += 1
  elsif locs.any? { |l| l[:in] == :mob_inv || l[:in] == :mob_eq } then tally[:on_mob] += 1
  else                             tally[:loose_in_room] += 1
  end
end

puts "objects: #{objs.size}  (#{objs.count { |_, o| otype(o) == 'CONTAINER' }} containers, " \
     "#{objs.count { |_, o| otype(o) == 'KEY' }} keys)"
puts "keyed doors: #{doors.size} (#{uniq.size} unique room+key pairs)"
puts
puts "  where the key for a locked door actually is:"
[[:in_container, "inside a container"], [:on_mob, "carried/worn by a mob"],
 [:loose_in_room, "lying loose in a room"], [:never_spawns, "never spawns (script/quest)"],
 [:no_such_object, "key object not defined"]].each do |k, label|
  puts format("    %-30s %5d  (%.1f%%)", label, tally[k], 100.0 * tally[k] / uniq.size)
end
puts
puts "  => 'look in <container>' is only the answer for the first row."
puts "     Run with a room vnum for a specific door, e.g.  ruby keys_and_containers.rb 89"
