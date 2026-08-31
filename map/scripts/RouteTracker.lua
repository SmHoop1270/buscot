-- Records the world-space path driven by the player's current vehicle, on demand,
-- via console commands - for tracing real drivable tracks that aren't part of the
-- roadPiece/asphalt01 road network (e.g. field access tracks, informal paths).
--
-- Console commands (open the dev console with the ~ key in-game):
--   rtStart  - begin recording a new segment
--   rtStop   - stop recording, keep this segment, and save ALL segments recorded
--              so far this session to map/pda/recordedTrack.xml
--   rtClear  - discard the CURRENT in-progress segment only (before rtStop),
--              without touching previously completed/saved segments
--   rtReset  - discard EVERYTHING (all completed segments plus any in-progress one)
--   rtUndo   - remove the LAST completed segment (e.g. you just recorded a track
--              that turns out to already be covered by the road highlight) and
--              re-save immediately
--
-- Each rtStart/rtStop cycle adds a separate <run> rather than overwriting the
-- file, so you can record several disconnected tracks in one session (repositioning
-- between them without recording) and every rtStop saves the full accumulated set.
-- Existing segments are also reloaded from disk on map load, so reloading the map
-- (e.g. to pick up a script update) never loses anything already recorded.
--
-- Output uses the same <roads><run><point x=".." z=".."/></run></roads> schema as
-- CreateMapPDA_FS25.lua's road_data.xml, so the existing CompositeRoadsOntoPDA.ps1
-- can draw it the same way.
--
-- Patterns here are taken directly from this map's own working OpeningHours.lua
-- (addModEventListener / loadMap / deleteMap / update lifecycle, Utils.getFilename
-- for a path relative to the mod's own directory, createXMLFile/setXMLString/
-- saveXMLFile) rather than guessed, plus g_currentMission.controlledVehicle, which
-- OpeningHours.lua itself already uses successfully in this same mod.

RouteTrackerSystem = {}
local RouteTrackerSystem_mt = Class(RouteTrackerSystem)

local MOD_DIR = g_currentModDirectory

-- Minimum distance (meters) between consecutive recorded points, so sitting still
-- (or driving slowly) doesn't flood the recording with near-duplicate points.
local MIN_POINT_SPACING = 1.0

function RouteTrackerSystem.new(mission)
    local self = setmetatable({}, RouteTrackerSystem_mt)
    self.mission = mission
    self.recording = false
    self.points = {}        -- current in-progress segment
    self.completedRuns = {} -- list of finished segments (each a list of {x,y,z})
    self.hasWarnedNoVehicle = false
    self.hasConfirmedVehicle = false
    self.noVehicleWarnTimer = 0
    return self
end

function RouteTrackerSystem:loadMap(name)
    g_currentMission.routeTrackerSystem = self

    addConsoleCommand("rtStart", "Start recording a new track segment", "consoleStart", self)
    addConsoleCommand("rtStop", "Stop recording, keep this segment, and save everything so far", "consoleStop", self)
    addConsoleCommand("rtClear", "Discard the current in-progress segment only", "consoleClear", self)
    addConsoleCommand("rtReset", "Discard ALL segments (completed and in-progress)", "consoleReset", self)
    addConsoleCommand("rtUndo", "Remove the last completed segment and re-save", "consoleUndo", self)

    -- Load any segments already saved from a previous session/before a map
    -- reload, so completedRuns (in-memory) never falls out of sync with what's
    -- actually on disk - without this, reloading the map to pick up a script
    -- change would silently wipe out everything already recorded, since the next
    -- rtStop would save from an empty in-memory list and overwrite the file.
    self:loadExisting()

    print("[RouteTracker] Ready. Console commands: rtStart, rtStop, rtClear, rtReset, rtUndo")
end

function RouteTrackerSystem:deleteMap()
    removeConsoleCommand("rtStart")
    removeConsoleCommand("rtStop")
    removeConsoleCommand("rtClear")
    removeConsoleCommand("rtReset")
    removeConsoleCommand("rtUndo")
    g_currentMission.routeTrackerSystem = nil
end

function RouteTrackerSystem:loadExisting()
    local path = Utils.getFilename("map/pda/recordedTrack.xml", MOD_DIR)
    local xmlFile = loadXMLFile("routeTrackerLoad", path)
    if xmlFile == nil or xmlFile == 0 then
        print("[RouteTracker] No existing recordedTrack.xml found - starting fresh.")
        return
    end

    local runIndex = 0
    while true do
        local runKey = string.format("roads.run(%d)", runIndex)
        if getXMLString(xmlFile, runKey .. ".point(0)#x") == nil then
            break
        end

        local points = {}
        local pointIndex = 0
        while true do
            local base = string.format("%s.point(%d)", runKey, pointIndex)
            local xStr = getXMLString(xmlFile, base .. "#x")
            if xStr == nil then
                break
            end
            local zStr = getXMLString(xmlFile, base .. "#z")
            table.insert(points, { x = tonumber(xStr), y = 0, z = tonumber(zStr) })
            pointIndex = pointIndex + 1
        end

        if #points > 0 then
            table.insert(self.completedRuns, points)
        end
        runIndex = runIndex + 1
    end

    delete(xmlFile)

    print(string.format("[RouteTracker] Loaded %d existing segment(s) from %s", #self.completedRuns, path))
end

function RouteTrackerSystem:consoleStart()
    self.recording = true
    self.points = {}
    self.hasWarnedNoVehicle = false
    self.hasConfirmedVehicle = false
    self.noVehicleWarnTimer = 0
    print(string.format("[RouteTracker] Recording segment #%d - drive the route, then run rtStop.", #self.completedRuns + 1))
end

function RouteTrackerSystem:consoleClear()
    self.recording = false
    local hadPoints = #self.points
    self.points = {}
    print(string.format("[RouteTracker] Cleared current in-progress segment (discarded %d point(s)). %d completed segment(s) untouched.", hadPoints, #self.completedRuns))
end

function RouteTrackerSystem:consoleReset()
    self.recording = false
    local hadRuns = #self.completedRuns
    self.points = {}
    self.completedRuns = {}
    print(string.format("[RouteTracker] Reset everything (discarded %d completed segment(s) plus any in-progress one).", hadRuns))
end

function RouteTrackerSystem:consoleUndo()
    if #self.completedRuns == 0 then
        print("[RouteTracker] Nothing to undo - no completed segments.")
        return
    end
    table.remove(self.completedRuns)
    print(string.format("[RouteTracker] Removed last completed segment. %d segment(s) remain.", #self.completedRuns))
    self:save()
end

function RouteTrackerSystem:consoleStop()
    self.recording = false

    if #self.points < 2 then
        print("[RouteTracker] Nothing meaningful in this segment (need at least 2 points) - not added.")
    else
        table.insert(self.completedRuns, self.points)
        print(string.format("[RouteTracker] Segment #%d completed: %d point(s).", #self.completedRuns, #self.points))
    end
    self.points = {}

    self:save()
end

-- Tries every plausible real API for "the vehicle the local player is currently
-- driving", in priority order, and reports which one actually worked - so instead
-- of guessing a single API name, the next test tells us definitively which is
-- correct on this game version (g_currentMission.controlledVehicle was tried first
-- and confirmed NOT populated during actual driving, contradicting its use
-- elsewhere in this same mod's OpeningHours.lua).
local function findControlledVehicle()
    if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        local v = g_localPlayer:getCurrentVehicle()
        if v ~= nil then
            return v, "g_localPlayer:getCurrentVehicle()"
        end
    end
    if g_currentMission ~= nil and g_currentMission.controlledVehicle ~= nil then
        return g_currentMission.controlledVehicle, "g_currentMission.controlledVehicle"
    end
    if g_currentMission ~= nil and g_currentMission.player ~= nil and g_currentMission.player.getCurrentVehicle ~= nil then
        local v = g_currentMission.player:getCurrentVehicle()
        if v ~= nil then
            return v, "g_currentMission.player:getCurrentVehicle()"
        end
    end
    return nil, nil
end

function RouteTrackerSystem:update(dt)
    if not self.recording then
        return
    end

    local vehicle, source = findControlledVehicle()
    if vehicle == nil or vehicle.rootNode == nil then
        -- Real-time diagnostic (throttled to once every 3s) instead of a silent
        -- no-op, so a missing vehicle is obvious WHILE recording, not just as a
        -- confusing "0 points" surprise after rtStop. Includes enough detail to
        -- tell "g_localPlayer doesn't exist at all" apart from "it exists but
        -- reports no vehicle", since those point to very different problems.
        self.noVehicleWarnTimer = self.noVehicleWarnTimer + dt
        if not self.hasWarnedNoVehicle or self.noVehicleWarnTimer >= 3000 then
            self.hasWarnedNoVehicle = true
            self.noVehicleWarnTimer = 0
            print(string.format(
                "[RouteTracker] WARNING: no controlled vehicle detected. g_localPlayer=%s g_currentMission.controlledVehicle=%s",
                tostring(g_localPlayer), tostring(g_currentMission ~= nil and g_currentMission.controlledVehicle or "n/a")))
        end
        return
    end

    if not self.hasConfirmedVehicle then
        self.hasConfirmedVehicle = true
        print("[RouteTracker] Vehicle detected via " .. source .. " (" ..
            tostring(vehicle.typeName or vehicle.configFileName or "?") .. ") - recording positions now.")
    end

    local x, y, z = getWorldTranslation(vehicle.rootNode)

    local last = self.points[#self.points]
    if last == nil then
        table.insert(self.points, { x = x, y = y, z = z })
    else
        local dx = x - last.x
        local dz = z - last.z
        if math.sqrt(dx * dx + dz * dz) >= MIN_POINT_SPACING then
            table.insert(self.points, { x = x, y = y, z = z })
        end
    end
end

function RouteTrackerSystem:save()
    if #self.completedRuns == 0 then
        print("[RouteTracker] No completed segments to save yet.")
        return
    end

    local path = Utils.getFilename("map/pda/recordedTrack.xml", MOD_DIR)

    local xmlFile = createXMLFile("routeTracker", path, "roads")
    if xmlFile == nil or xmlFile == 0 then
        print("[RouteTracker] ERROR: could not create XML file at " .. tostring(path))
        return
    end

    local totalPoints = 0
    for runIndex, run in ipairs(self.completedRuns) do
        for pointIndex, p in ipairs(run) do
            local key = string.format("roads.run(%d).point(%d)", runIndex - 1, pointIndex - 1)
            setXMLString(xmlFile, key .. "#x", string.format("%.4f", p.x))
            setXMLString(xmlFile, key .. "#z", string.format("%.4f", p.z))
            totalPoints = totalPoints + 1
        end
    end

    saveXMLFile(xmlFile)
    delete(xmlFile)

    print(string.format("[RouteTracker] Saved %d segment(s), %d point(s) total, to %s",
        #self.completedRuns, totalPoints, path))
end

local g_routeTrackerSystem = RouteTrackerSystem.new(g_currentMission)
addModEventListener(g_routeTrackerSystem)

print("[RouteTracker] Registered event listener")
