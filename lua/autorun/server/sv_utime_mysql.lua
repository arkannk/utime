if not SERVER then return end

--------------------------------------------
-- CONFIG
--------------------------------------------
local DB = {
    HOST = "", -- IP
    USER = "", -- USERNAME
    PASS = "", -- PASSWORD
    NAME = "" -- DB NAME
}

-- Team-Key: true = TeamID (robust), false = Teamname 
local USE_TEAM_ID = false

-- Debug on/off
local DEBUG = false 
-- ==========================

local function dprintf(fmt, ...)
  if DEBUG then print("[Solve_UTime] " .. string.format(fmt, ...)) end
end

-- load mysqloo
if not mysqloo then pcall(require, "mysqloo") end
if not mysqloo then ErrorNoHalt("[UTime] mysqloo missing!\n"); return end

-- Connection + Queue
DB._conn  = mysqloo.connect(DB.HOST, DB.USER, DB.PASS, DB.NAME, DB.PORT)
DB._ready = false
DB._failed= false
DB._queue = {}

local function esc(s) return DB._conn:escape(tostring(s or "")) end
local function steam64(p) return IsValid(p) and p:SteamID64() or tostring(p or "") end
local function jobKeyFor(ply)
  if USE_TEAM_ID then return tostring(ply:Team()) end
  local n = team.GetName and team.GetName(ply:Team()) or nil
  return n and tostring(n) or tostring(ply:Team())
end

local function runQ(q, ok, err)
  if not DB._ready then
    table.insert(DB._queue, {q=q, ok=ok, err=err})
    dprintf("Queue: %s", (q:gsub("%s+"," ")):sub(1,220))
    return
  end
  if DEBUG then dprintf("RUN: %s", (q:gsub("%s+"," ")):sub(1,220)) end
  local query = DB._conn:query(q)
  function query:onSuccess(data) if ok then ok(data) end end
  function query:onError(e)
    ErrorNoHalt("[UTime] SQL-Error: "..tostring(e).."\n> "..q.."\n")
    if err then err(e) end
  end
  query:start()
end

local function flushQ()
  if #DB._queue == 0 then return end
  dprintf("Flush %d queued queries…", #DB._queue)
  for _, j in ipairs(DB._queue) do runQ(j.q, j.ok, j.err) end
  DB._queue = {}
end

function DB:_createSchema()
  runQ([[
    CREATE TABLE IF NOT EXISTS utime_players (
      steamid64 VARCHAR(20) NOT NULL PRIMARY KEY,
      total_seconds BIGINT UNSIGNED NOT NULL DEFAULT 0,
      first_join DATETIME NULL,
      last_join DATETIME NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
  ]])
  runQ([[
    CREATE TABLE IF NOT EXISTS utime_jobtime (
      steamid64 VARCHAR(20) NOT NULL,
      job_key VARCHAR(128) NOT NULL,         -- 128 to safely store long job names
      seconds BIGINT UNSIGNED NOT NULL DEFAULT 0,
      PRIMARY KEY (steamid64, job_key),
      INDEX (job_key),
      CONSTRAINT fk_utime_player
        FOREIGN KEY (steamid64) REFERENCES utime_players(steamid64)
        ON DELETE CASCADE ON UPDATE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
  ]])
end

function DB:_connect()
  function DB._conn:onConnected()
    DB._ready, DB._failed = true, false
    print("[UTime] MySQL connected.")
    DB:_createSchema()
    flushQ()
  end
  function DB._conn:onConnectionFailed(err)
    DB._failed = true
    ErrorNoHalt("[UTime] MySQL connection failed: "..tostring(err).."\n")
  end
  DB._conn:connect()
end
DB:_connect()

-- Health ping every 30s


local function prettyTime(sec)
  sec = tonumber(sec) or 0
  local d = math.floor(sec / 86400); sec = sec % 86400
  local h = math.floor(sec / 3600);  sec = sec % 3600
  local m = math.floor(sec / 60)
  local t = {}
  if d > 0 then t[#t+1] = d .. "d" end
  if h > 0 then t[#t+1] = h .. "h" end
  t[#t+1] = m .. "m"
  return table.concat(t, " ")
end

local function displayJob(job_key)
  if not job_key then return "Unknown" end
  if USE_TEAM_ID then
    local id = tonumber(job_key)
    if id and team and team.GetName then
      local n = team.GetName(id)
      if n and n ~= "" then return n end
    end
  end
  return tostring(job_key)
end




-- ===== Core functions =====
local function ensurePlayerRow(ply, set_first, cb)
  local sid = esc(steam64(ply))
  local q = string.format([[
    INSERT INTO utime_players (steamid64, total_seconds, first_join, last_join)
    VALUES ('%s', 0, %s, NOW())
    ON DUPLICATE KEY UPDATE last_join = NOW();
  ]], sid, set_first and "NOW()" or "first_join")
  runQ(q, function() if DEBUG then dprintf("ensurePlayerRow OK %s", sid) end; if cb then cb(true) end end,
          function(e) if cb then cb(false, e) end end)
end

local function addTotalSeconds(sid64, sec)
  if sec <= 0 then return end
  runQ(string.format([[
    UPDATE utime_players SET total_seconds = total_seconds + %d WHERE steamid64='%s';
  ]], sec, esc(sid64)))
end

local function addJobSeconds(sid64, jobKey, sec)
  if sec <= 0 then return end
  sid64  = esc(sid64)
  jobKey = esc(jobKey)
  -- Ensure parent, then upsert child
  runQ(string.format([[
    INSERT INTO utime_players (steamid64, total_seconds, first_join, last_join)
    VALUES ('%s', 0, NOW(), NOW())
    ON DUPLICATE KEY UPDATE steamid64=steamid64;
  ]], sid64), function()
    runQ(string.format([[
      INSERT INTO utime_jobtime (steamid64, job_key, seconds)
      VALUES ('%s', '%s', %d)
      ON DUPLICATE KEY UPDATE seconds = seconds + VALUES(seconds);
    ]], sid64, jobKey, sec))
  end)
end

-- In-memory session
local function saveAccrual(ply, why)
  if not IsValid(ply) or not ply:IsPlayer() or not ply.UTime_DBReady then return end
  local last = ply.UTime_LastAccrualTick or os.time()
  local now  = os.time()
  local d    = now - last
  if d > 0 then
    addTotalSeconds(steam64(ply), d)
    ply.UTime_LastAccrualTick = now
    if DEBUG then dprintf("+%ds total (%s) -> %s", d, tostring(why or "tick"), ply:Nick()) end
  end
end

local function saveJobAccrual(ply, why)
  if not IsValid(ply) or not ply:IsPlayer() or not ply.UTime_DBReady then return end
  if not ply.UTime_JobStart or not ply.UTime_JobKey then return end
  local now  = os.time()
  local diff = now - ply.UTime_JobStart
  if diff > 0 then
    addJobSeconds(steam64(ply), ply.UTime_JobKey, diff)
    ply.UTime_JobStart = now
    if DEBUG then dprintf("+%ds job='%s' (%s) -> %s", diff, tostring(ply.UTime_JobKey), tostring(why or "job"), ply:Nick()) end
  end
end

local function startSession(ply, is_first)
  ensurePlayerRow(ply, is_first, function(ok)
    local now = os.time()
    ply.UTime_DBReady         = ok and true or false
    ply.UTime_SessionStart    = now
    ply.UTime_LastAccrualTick = now
    ply.UTime_JobKey          = jobKeyFor(ply)
    ply.UTime_JobStart        = now
    ply._UTime_LastTeam       = ply:Team()
    dprintf("Session ready %s | job=%s", steam64(ply), tostring(ply.UTime_JobKey))
  end)
end

-- ===== Hooks =====

-- 0) Immediate: prepare first_join/last_join
hook.Add("PlayerAuthed", "UTime_FirstJoin_Ensure", function(ply)
  ensurePlayerRow(ply, true)
end)

-- 1) Start session when player spawns
hook.Add("PlayerInitialSpawn", "UTime_InitialSpawn_Start", function(ply)
  local sid = esc(steam64(ply))
  runQ(("SELECT steamid64 FROM utime_players WHERE steamid64='%s' LIMIT 1;"):format(sid),
    function(data) startSession(ply, not (data and data[1])) end,
    function() startSession(ply, false) end
  )
end)

-- 2) Job change (Sandbox/TTT…)
hook.Add("OnPlayerChangedTeam", "UTime_ChangedTeam_All", function(ply, before, after)
  if not IsValid(ply) then return end
  saveJobAccrual(ply, "gmod_hook")
  ply.UTime_JobKey   = USE_TEAM_ID and tostring(after) or (team.GetName and team.GetName(after) or tostring(after))
  ply.UTime_JobStart = os.time()
  ply._UTime_LastTeam= after
  saveAccrual(ply, "gmod_hook")
  dprintf("Job -> %s via OnPlayerChangedTeam", tostring(ply.UTime_JobKey))
end)

-- 3) Job change (DarkRP)
hook.Add("playerChangedTeam", "UTime_ChangedTeam_DarkRP", function(ply, before, after)
  if not IsValid(ply) then return end
  saveJobAccrual(ply, "darkrp_hook")
  ply.UTime_JobKey   = USE_TEAM_ID and tostring(after) or (team.GetName and team.GetName(after) or tostring(after))
  ply.UTime_JobStart = os.time()
  ply._UTime_LastTeam= after
  saveAccrual(ply, "darkrp_hook")
  dprintf("Job -> %s via playerChangedTeam", tostring(ply.UTime_JobKey))
end)

-- 5) Disconnect: flush current span
hook.Add("PlayerDisconnected", "UTime_Disconnect_Save", function(ply)
  saveJobAccrual(ply, "disconnect")
  saveAccrual(ply, "disconnect")
  runQ(("UPDATE utime_players SET last_join=NOW() WHERE steamid64='%s';"):format(esc(steam64(ply))))
end)

-- ===== Diagnostic commands =====
-- Dump DB rows for yourself or a target
concommand.Add("utime_debug_dump", function(ply, _, args)
  if IsValid(ply) and not ply:IsSuperAdmin() then return end
  local sid = args[1] and tostring(args[1]) or (IsValid(ply) and ply:SteamID64() or "")
  if sid == "^" and IsValid(ply) then sid = ply:SteamID64() end
  if sid == "" then print("Use: utime_debug_dump <steamid64|^>"); return end

  runQ(("SELECT * FROM utime_players WHERE steamid64='%s';"):format(esc(sid)), function(data)
    print("== utime_players =="); PrintTable(data or {})
  end)
  runQ(("SELECT * FROM utime_jobtime WHERE steamid64='%s';"):format(esc(sid)), function(data)
    print("== utime_jobtime =="); PrintTable(data or {})
  end)
end)

-- Simulate “+N seconds in current job” (tests addJobSeconds path)
concommand.Add("utime_debug_fakejobtime", function(ply, _, args)
  if not IsValid(ply) or not ply:IsSuperAdmin() then return end
  local n = tonumber(args[1] or "10") or 10
  if not ply.UTime_JobStart then ply.UTime_JobStart = os.time() - n end
  ply.UTime_JobStart = ply.UTime_JobStart - n
  saveJobAccrual(ply, "fake_add")
  ply:ChatPrint("[UTime] Fake job time saved: +"..n.."s")
end)