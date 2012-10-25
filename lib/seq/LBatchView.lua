--[[------------------------------------------------------

  seq.LBatchView
  -------------

  This view shows the following elements:

  ( event navigation, usual global commands )
  [ Display 'key' parameter for event 1 in page       ]
  [ Display 'key' parameter for event 2 in page       ]
  [ "                                                 ]
  [ "                                                 ] (edit 'note')

  [ "                                                 ] (edit 'velocity')
  [ "                                                 ] (edit 'length')
  [ "                                                 ] (edit 'position')
  [ "                                                 ] (edit 'loop')

  Click on the current edit param moves back to Main view.

--]]------------------------------------------------------
local lib = {type = 'seq.LBatchView', name = 'Batch'}
lib.__index         = lib
seq.LBatchView      = lib
-- Last column operation to function
local col_button    = {}
-- Map top buttons
local top_button    = {}
local private       = {}
local m             = seq.LMainView.batch

private.loadParam = m.loadParam
private.setParam  = m.setParam

--=============================================== CONSTANTS
-- Last column button parameter selection
local PARAMS      = m.PARAMS
local BIT_STATE   = m.BIT_STATE
local KEY_TO_ROW  = {}
for i, key in ipairs(PARAMS) do
  if key ~= '' then
    KEY_TO_ROW[key] = i
  end
end

local NOTE_ON_STATE = {
  'Green',
  'Amber',
  'Red',
  -- mute states
  'LightRed',
  'LightRed',
  'LightRed',
  'Red' -- mute button
}

local NOTE_OFF_STATE = {
  'LightGreen',
  'LightAmber',
  'LightRed', -- ???
  -- mute states
  'LightRed',
  'LightRed',
  'LightRed',
  'Red' -- mute button
}

local PAGE_BITS = {
  8,
  4,
  2,
  1,
}

--=============================================== PUBLIC
setmetatable(lib, {
  __call = function(lib, ...)
    return lib.new(...)
  end
})

-- seq.LBatchView(...)
function lib.new(lseq)
  local self = {
    lseq = lseq,
    pad = lseq.pad,
    seq = lseq.seq,
    key = 'note',
    -- Direct access to bit values (ex: bits[row][col])
    bits = {},
    -- Direct access to grid buttons
    btns = {},
    -- Edited events (independant of event.id)
    events = {},
    -- Find event from id
    row_by_id = {},
    -- Pagination
    page = 0,
  }
  return setmetatable(self, lib)
end

-- Display view content (called on load)
function lib:display(key, page)
  local key = key or self.key
  local page = page or self.page
  self.key = key
  self.last_key = nil
  local pad = self.pad
  local seq = self.seq
  local events = self.events
  -- Clear
  pad:prepare()
  pad:clear()
  -- Turn on mixer button
  pad:button(0, 8):setState('Amber')
  -- Display pagination buttons
  private.setPageButtons(self, page)

  -- Display events
  local row = 1
  local row_by_id = {}
  self.row_by_id = row_by_id

  local part_events = seq.partition.events
  for row=1,8 do
    local id = page*16 + row
    local e = part_events[id]
    if e then
      private.loadParam(self, key, e, e[key], BIT_STATE, row)
      row_by_id[e.id] = row
      events[row] = e
      self:setEventState(e)
    end
  end
  pad:button(KEY_TO_ROW[key], 9):setState('Amber')
  pad:commit()
end

function lib:setEventState(e)
  local id = e.id
  local row = self.row_by_id[id]
  -- Bit value for this element
  if row then
    local b = self.bits[self.key][row][1] + 1
    local btn = self.pad:button(row, 1)
    if e.mute then
      b = b + 3
    end
    if e.off_t then
      -- Note is on
      btn:setState(NOTE_ON_STATE[b])
    else
      -- Note is off
      btn:setState(NOTE_OFF_STATE[b])
    end
  end
end

-- Used to reload event data on mute change
function lib:editEvent(e, row, col)
  private.loadParam(self, self.key, e, e[key], BIT_STATE, row)
end

function lib:press(row, col)
  if row == 0 then
    f = top_button[col]
  elseif col == 9 then
    f = col_button[row]
  else
    f = private.pressGrid
  end
  if f then
    f(self, row, col)
  else
    -- Default LSeq handling
    self.lseq:press(row, col)
  end
end

function private:loadMain(row, col)
  self.lseq:loadView('Main')
end
top_button[8] = private.loadMain

function private:changePage(row, col)
  local p = self.page
  local b = self.page_bits[col]
  if b == 0 then
    self.page_bits[col] = 1
    p = p + PAGE_BITS[col]
  else
    self.page_bits[col] = 0
    p = p - PAGE_BITS[col]
  end
  self:display(self.key, p)
end
for i=1,4 do
  top_button[i] = private.changePage
end

function private:pressGrid(row, col)
  local e = self.events[row]
  if col == 1 then
    private.setParam(self, self.key, row, col, e, e.off_t and NOTE_ON_STATE or NOTE_OFF_STATE)
  else
    private.setParam(self, self.key, row, col, e, BIT_STATE)
  end
end

-- Last column buttons
function private:batchButton(row, col)
  local key = PARAMS[row]
  self:display(key)
end
for i, key in ipairs(PARAMS) do
  if key ~= '' then
    col_button[i] = private.batchButton
  end
end

function lib:release(row, col)
  -- ignore
end

-- Last column buttons
function private:batchButton(row, col)
  local key = PARAMS[row]
  local curr = self.key
  if key == curr then
    local last = self.last_key
    -- load last view
    if self.last_key then
      self.lseq:loadView('Batch', self.last_key)
      self.last_key = curr
    else
      self.lseq:loadView('Main')
    end
  else
    self.lseq:loadView('Batch', key)
    self.last_key = curr
  end
end
for i, key in ipairs(PARAMS) do
  if key ~= '' then
    col_button[i] = private.batchButton
  end
end

function private:setPageButtons(page)
  local v = page
  local pbits = {}
  local pad = self.pad
  self.page_bits = pbits
  for i, r in ipairs(PAGE_BITS) do
    local b = math.floor(v / r)
    v = v - r * b
    pbits[i] = b
    pad:button(0, i):setState(BIT_STATE[b+1])
  end
  self.page = page
end