-- procgen.graph: the lock and key logic of a map, by breadth-first search over its rooms.
-- A room is one node (its exits are taken to connect to each other: reach.check verifies that
-- per template); a door is an edge that needs every tag in door.requires, in both directions.
local M = {}

local function passable(door, have)
  local req = door.requires
  for i = 1, #req do
    if not have[req[i]] then return false end
  end
  return true
end

-- graph.solve(map, opts): plays the map from the start room: walks through every door whose
-- tags are held and picks up the item of every room reached, until nothing changes.
-- opts.without: a tag that is never picked up (to ask what can be reached without it).
-- opts.have: array of tags held from the beginning.
-- Returns { reached = { [room index] = true }, count = rooms reached,
--           order = tags in the order they were picked up, have = { tag = true } }.
function M.solve(map, opts)
  local without = opts and opts.without
  local rooms, doors = map.rooms, map.doors
  local have, order, reached, queue, blocked = {}, {}, {}, {}, {}
  local count, gained = 0, false
  if opts and opts.have then
    for i = 1, #opts.have do have[opts.have[i]] = true end
  end
  local function visit(index)
    reached[index] = true
    count = count + 1
    queue[#queue + 1] = index
    local tag = rooms[index].grants
    if tag and tag ~= without and not have[tag] then
      have[tag] = true
      order[#order + 1] = tag
      gained = true
    end
  end
  visit(map.start)
  local head = 1
  while true do
    while head <= #queue do
      local room = rooms[queue[head]]
      head = head + 1
      for e = 1, #room.doors do
        local di = room.doors[e]
        if di then
          local door = doors[di]
          local other = door.a == room.index and door.b or door.a
          if not reached[other] then
            if passable(door, have) then visit(other) else blocked[#blocked + 1] = di end
          end
        end
      end
    end
    if not gained then break end
    gained = false
    local kept = 0
    for i = 1, #blocked do
      local door = doors[blocked[i]]
      local a, b = reached[door.a], reached[door.b]
      if not (a and b) then
        if passable(door, have) then
          visit(a and door.b or door.a)
        else
          kept = kept + 1
          blocked[kept] = blocked[i]
        end
      end
    end
    for i = #blocked, kept + 1, -1 do blocked[i] = nil end
  end
  return { reached = reached, count = count, order = order, have = have }
end

-- graph.validate(map): true, or false and a message. A map is valid when, from the start room,
-- every room is reached and every ability of map.abilities is picked up, and no item is behind
-- a door that needs it (the room of each tag is reached without ever picking that tag up).
function M.validate(map)
  local rooms = map.rooms
  local all = M.solve(map)
  if all.count ~= #rooms then
    for i = 1, #rooms do
      if not all.reached[i] then return false, "room " .. i .. " (" .. rooms[i].id .. ") is never reached" end
    end
  end
  local abilities = map.abilities
  for k = 1, #abilities do
    local tag = abilities[k]
    if not all.have[tag] then return false, "the ability " .. tag .. " is never found" end
    local at
    for i = 1, #rooms do
      if rooms[i].grants == tag then at = i; break end
    end
    if not M.solve(map, { without = tag }).reached[at] then
      return false, "the item of " .. tag .. " is behind a door that needs " .. tag
    end
  end
  return true
end

return M
