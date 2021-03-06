--[[------------------------------------------------------

  binseq.Sequencer
  ----------------

  A Sequencer contains:
    * list of active patterns
      => channel

  The sequencer responds to
    * play(t): trigger events for all active patterns
      (one list contains all future events for active
       patterns)
    * addPattern(pattern)
    * removePattern(posid)
    * allOff: called to mute all current ON notes.
    * move(t): must be called to move song position.

--]]------------------------------------------------------
local lib = {type = 'binseq.Sequencer'}
lib.__index      = lib
binseq.Sequencer    = lib
local private    = {}
local MAX_CTRL_EVERY_MS = 2 -- 500 Hz

--=============================================== CONSTANTS

--=============================================== PUBLIC
setmetatable(lib, {
  __call = function(lib, ...)
    return lib.new(...)
  end
})

-- binseq.Sequencer(...)
function lib.new(def)
  local self = {
    t        = 0,
    channel  = 1,
    -- Playback list
    list = {},
    -- Active patterns by posid
    patterns = {},
    -- List of active controls by ctrl
    ctrls    = {},
  }
  setmetatable(self, lib)
  if def then
    self:set(def)
  end
  
  self.destroy = lk.Finalizer(function()
    self:allOff()
  end)

  return self
end

function lib:set(def)
  for k, v in pairs(def) do
    self[k] = v
  end

  if self.db then
    self:save()
  end
end

function lib:save()
  -- Write sequencer in database
  local db = self.db
  assert(db, 'Cannot save sequencer without database')
  db:setSequencer(self)
end

function lib:dump()
  local pat_on = {}
  for posid, _ in pairs(self.patterns) do
    table.insert(pat_on, posid)
  end

  return {
    type   = self.type,
    data   = {channel = self.channel},
    pat_on = pat_on,
  }
end

function lib:copy(dump)
  local data = dump.data
  self.channel = data.channel or 1
  self:save()

  for _, posid in ipairs(dump.pat_on) do
    self:enablePattern(posid)
  end
end

function lib:delete()
  local db = self.db
  assert(db, 'Cannot delete sequencer without database')
  db:deleteSequencer(self)
  self.deleted = true
end

function lib:enablePattern(posid)
  local pat = self:loadPattern(posid)
  pat:setSequencer(self)
end

function lib:disablePattern(posid)
  local pat = self.patterns[posid]
  if pat then
    self.patterns[posid] = nil
    pat:setSequencer(nil)
  end
end

function lib:loadPatterns()
  for posid in self.db:getActivePatternPosids(self.id) do
    self:loadPattern(posid)
  end
end

function lib:loadPattern(posid)
  local pat = self.song:getOrCreatePattern(posid)
  self.patterns[posid] = pat
  pat:setSequencer(self)
  return pat
end

function lib:allOff()
  local e = self.list.next
  self.list.next = nil
  while e do
    if e.off_t then
      self:trigger(e, true)
    end
    e = e.next
  end

  local playback = self.playback
  local base = self.channel + 0xB0 - 1
  for ctrl, list in pairs(self.ctrls) do
    playback(self, base, ctrl, 0)
  end
end

-- Change song position.
function lib:move(t)
  self.t  = t
  -- Clear list
  self.list = {}
  local list = self.list

  -- schedule all active patterns
  for _, pat in pairs(self.patterns) do
    for _, e in pairs(pat.events) do
      e:nextTrigger(t)
      if e.t then
        private.insertInList(list, e)
      end
    end
  end
end

function lib:reSchedule(e, not_now)
  if e.off_t then
    -- Event edited while ON
    -- Trigger off
    local f = self.playback
    if f then f(self, e) end
  end
  self:schedule(e, not_now)
end

function lib:schedule(e, not_now)
  e:nextTrigger(self.t, not_now)
  if e.t then
    private.insertInList(self.list, e)
  end
end

function lib:step(t)
  self.t = t
  local list = self.list
  local e = list.next
  local trig = self.trigger
  while e and e.t <= t do
    trig(self, e)
    e = list.next
  end

  private.controlRamps(self, t)
end

function lib:trigger(e, skip_schedule)
  -- 1. Trigger event
  if e.mute == 0 or e.off_t then
    -- Not muted or NoteOff
    local f = self.playback
    if f then 
      skip_schedule = f(self, e) or skip_schedule
    end
  end
  -- Keep last trigger time to reschedule event on edit/create.
  self.t = e.t
  -- 2. Reschedule
  if not skip_schedule then
    self:schedule(e, true)
  end
end

function lib:removeEvent(e)
  if e.off_t then
    local f = self.playback
    if f then f(self, e) end
  end

  -- Remove from previous list
  local p = e.prev
  local n = e.next

  if p then
    p.next = n
    e.prev = nil
  end

  if n then
    n.prev = p
    e.next = nil
  end
end

function private.insertInList(list, e)
  -- Remove from previous list
  local p = e.prev
  local n = e.next
  local t = e.t

  if p then
    p.next = n
    e.prev = nil
  end
  if n then
    n.prev = p
    e.next = nil
  end

  if e.mute == 0 then
    -- not muted
    -- insert sorted
    local l = list
    while true do
      if l.t and t < l.t then
        -- insert before
        local b = l.prev
        l.prev = e
        e.next = l
        if b then
          b.next = e
          e.prev = b
        end
        break
      end

      -- Any next item ?
      local n = l.next
      if not n then
        -- end of list reached
        l.next = e
        e.prev = l
        break
      else
        l = n
      end
    end
  end
end

function private:controlRamps(t)
  local ct = now()
  local playback = self.playback
  local base = self.channel + 0xB0 - 1
  for ctrl, list in pairs(self.ctrls) do
    local last = list._last
    local last_ct = list._last_ct or -1000
    if ct < last_ct + MAX_CTRL_EVERY_MS then
      -- ignore for now
    else
      local v = -1
      for e, _ in pairs(list) do
        if e ~= '_last' and e ~= '_last_ct' and e.off_t then
          -- For each control changers for this ctrl value
          local min, max = e.velocity, e.note
          if min > v or max > v then
            -- Compute ramp
            local end_t, len = e.off_t, e.length
            local slope = (max - min) / len
            local e_v = min + slope * (t - end_t + len)
            if e_v > v then
              v = e_v
              if v == 127 then
                break
              end
            end
          end
        end
      end

      if v == -1 then
        -- empty
        playback(self, base, ctrl, 0)
        self.ctrls[ctrl] = nil
      else
        v = math.floor(v + 0.5)
        if v ~= last then
          list._last = v
          list._last_ct = ct
          playback(self, base, ctrl, v)
        end
      end
    end
  end
end
