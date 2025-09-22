local function msg(s) reaper.ShowMessageBox(s, "Create VERB Aux", 0) end

-- Read whole file into a string (returns nil if not found/readable)
local function slurp(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local c = f:read("*a")
  f:close()
  return c
end

-- Collect all params whose name matches (case-insensitive). Returns array of indices.
local function find_params_by_name(track, fx_idx, needle)
  local hits = {}
  local cnt = reaper.TrackFX_GetNumParams(track, fx_idx)
  needle = (needle or ""):lower()
  for p = 0, cnt-1 do
    local _, pname = reaper.TrackFX_GetParamName(track, fx_idx, p, "")
    local low = (pname or ""):lower()
    if low == needle or low:find(needle, 1, true) then
      hits[#hits+1] = p
    end
  end
  return hits
end

-- Set a parameter to a desired "native" (e.g., dB) value using min/max from GetParamEx.
local function set_param_to_native(track, fx_idx, param_idx, desired_native)
  local _, minv, maxv, _ = reaper.TrackFX_GetParamEx(track, fx_idx, param_idx)
  if not (minv and maxv) then return false end
  local v = math.max(minv, math.min(maxv, desired_native))
  local norm = (maxv ~= minv) and ((v - minv) / (maxv - minv)) or 0.0
  reaper.TrackFX_SetParamNormalized(track, fx_idx, param_idx, norm)
  return true
end

-- Insert a track right below the given track (1-based index known)
local function insert_track_below(idx1_based)
  -- InsertTrackAtIndex uses 0-based; inserting at idx1_based places AFTER src
  reaper.InsertTrackAtIndex(idx1_based, true) -- obey track defaults
  reaper.TrackList_AdjustWindows(false)
  return reaper.GetTrack(0, idx1_based)
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

-- Validate selection
local src = reaper.GetSelectedTrack(0, 0)
if not src then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Create VERB aux (no selection)", -1)
  return msg("Please select a track first.")
end

-- Source info
local src_idx_1 = math.floor(reaper.GetMediaTrackInfo_Value(src, "IP_TRACKNUMBER"))
local _, src_name = reaper.GetSetMediaTrackInfo_String(src, "P_NAME", "", false)
if not src_name or src_name == "" then
  src_name = string.format("Track %d", src_idx_1)
end
local target_name = "VERB_" .. src_name

-- Locate template
local resource_path = reaper.GetResourcePath()
local template_path = resource_path .. "/TrackTemplates/AUX_VERB.RTrackTemplate" -- forward slash works on all OSes
local template_chunk = slurp(template_path)

-- Make the destination track
local dest = insert_track_below(src_idx_1)
if not dest then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Create VERB aux (failed to create track)", -1)
  return msg("Couldn't create the new aux track.")
end

if template_chunk and template_chunk:find("<TRACK") then
  -- Apply template chunk to the new track
  -- use isundo = true to ensure proper state handling
  local ok = reaper.SetTrackStateChunk(dest, template_chunk, true)
  -- Name per our scheme (override any name from template)
  reaper.GetSetMediaTrackInfo_String(dest, "P_NAME", target_name, true)
  -- Create send from src -> dest
  local send_idx = reaper.CreateTrackSend(src, dest)
  if send_idx < 0 then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Create VERB aux from template (failed to create send)", -1)
    return msg("Created template track, but couldn't create the send from the source track.")
  end
else
  -- Fallback: build manually (no Wet changes)
  -- Name
  reaper.GetSetMediaTrackInfo_String(dest, "P_NAME", target_name, true)
  -- Copy color
  reaper.SetTrackColor(dest, reaper.GetTrackColor(src))
  -- Insert ReaVerb
  local fx_idx = reaper.TrackFX_AddByName(dest, "ReaVerb (Cockos)", false, -1)
  if fx_idx < 0 then fx_idx = reaper.TrackFX_AddByName(dest, "ReaVerb", false, -1) end
  if fx_idx >= 0 then
    -- Dry = fully down
    local dry_hits = find_params_by_name(dest, fx_idx, "dry")
    if #dry_hits >= 1 then
      local dry_p = dry_hits[1]
      local ok = set_param_to_native(dest, fx_idx, dry_p, -1e9)
      if not ok then reaper.TrackFX_SetParamNormalized(dest, fx_idx, dry_p, 0.0) end
    end
  else
    -- ReaVerb missing is non-fatal; continue with routing
  end
  -- Create send from src -> dest
  local send_idx = reaper.CreateTrackSend(src, dest)
  if send_idx < 0 then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Create VERB aux (failed to create send)", -1)
    return msg("Couldn't create the send from the source track.")
  end
end

-- Keep selection intuitive: select the new aux
reaper.SetOnlyTrackSelected(dest)

reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock("Create VERB aux (template if present, else manual)", -1)
