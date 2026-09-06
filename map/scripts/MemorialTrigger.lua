--
-- MemorialTrigger.lua
--
-- Plays an audio file when the local player walks within range of a
-- named node in the map's i3d. Built for Buscot Park as a memorial
-- to Johnny.
--
-- Multiplayer-safe:
--   * The script loads on every machine (host and each client).
--   * The audio plays locally on whichever machine has a player who
--     walked into the area — never broadcast. Each player hears it
--     independently when they personally visit the spot.
--   * Dedicated servers load the script but never call playSample
--     (no local player → distance check returns early). No errors.
--
-- Wiring (Giants Editor):
--   1. Create a Shape at the memorial location, name it exactly:
--          memorialTrigger_johnny
--   2. The shape doesn't actually need any physics setup — this script
--      uses a distance-from-player check, not engine triggers. You can
--      use a small invisible TransformGroup if you prefer.
--   3. Save the i3d.
--

MemorialTrigger = {}
MemorialTrigger.MOD_DIRECTORY = g_currentModDirectory
MemorialTrigger.MOD_NAME      = g_currentModName

local MemorialTrigger_mt = Class(MemorialTrigger)

-- =====================================================================
-- Configuration: each entry is one memorial spot
-- =====================================================================
MemorialTrigger.NODE_NAMES = {
    ["memorialTrigger_johnny"] = {
        soundFile         = "sounds/johnny_goodbye.ogg",
        volume            = 1.0,
        activationRadius  = 8.0,    -- metres
        startDelayMs      = 10000,  -- pause after entering before playback starts
        cooldownMs        = 30000,  -- minimum gap between plays
        playOnce          = false,  -- true = play exactly once per game session
    },
}

MemorialTrigger.instances = {}


-- =====================================================================
-- Constructor
-- =====================================================================
function MemorialTrigger.new(triggerNode, config)
    local self = setmetatable({}, MemorialTrigger_mt)

    self.triggerNode      = triggerNode
    self.config           = config
    self.sample           = nil
    self.lastPlayTimeMs   = -math.huge
    self.hasPlayedOnce    = false
    self.isInsideRadius   = false
    self.pendingPlayAtMs  = nil

    local soundPath = MemorialTrigger.MOD_DIRECTORY .. config.soundFile
    if not fileExists(soundPath) then
        Logging.error("[MemorialTrigger] Sound file not found: %s", soundPath)
        return nil
    end

    self.sample = createSample("MemorialSample_" .. tostring(triggerNode))
    loadSample(self.sample, soundPath, false)

    return self
end


-- =====================================================================
-- Locate the local player on foot. Returns nil if there's no on-foot
-- local player (dedicated server, player driving a vehicle, etc.) —
-- which means the trigger won't fire while in a vehicle.
-- =====================================================================
local function getLocalPlayerPosition()
    -- If the player is currently in a vehicle, don't trigger.
    if g_currentMission ~= nil and g_currentMission.controlledVehicle ~= nil then
        return nil
    end

    if g_localPlayer ~= nil then
        if type(g_localPlayer.getCurrentWorldPosition) == "function" then
            local ok, x, y, z = pcall(g_localPlayer.getCurrentWorldPosition, g_localPlayer)
            if ok and x ~= nil then return x, y, z end
        end
        if g_localPlayer.position ~= nil then
            return g_localPlayer.position[1], g_localPlayer.position[2], g_localPlayer.position[3]
        end
        if g_localPlayer.rootNode ~= nil and g_localPlayer.rootNode ~= 0 then
            return getWorldTranslation(g_localPlayer.rootNode)
        end
        if g_localPlayer.graphicsRootNode ~= nil and g_localPlayer.graphicsRootNode ~= 0 then
            return getWorldTranslation(g_localPlayer.graphicsRootNode)
        end
    end

    return nil
end


-- =====================================================================
-- Per-frame: check distance, schedule playback, fire scheduled plays
-- =====================================================================
function MemorialTrigger:update(nowMs)
    local px, py, pz = getLocalPlayerPosition()

    -- No local player here (e.g. dedicated server, or before player spawns).
    -- Just tick any scheduled plays and bail out.
    if px == nil then
        self:tickPending(nowMs)
        return
    end

    local tx, ty, tz = getWorldTranslation(self.triggerNode)
    local dx, dy, dz = px - tx, py - ty, pz - tz
    local dist = math.sqrt(dx*dx + dy*dy + dz*dz)

    if dist <= self.config.activationRadius then
        if not self.isInsideRadius then
            self.isInsideRadius = true
            self:schedulePlay()
        end
    elseif dist > self.config.activationRadius * 1.2 then
        -- Hysteresis: leave only after going a bit further out, so jitter
        -- on the radius boundary doesn't toggle isInsideRadius rapidly.
        self.isInsideRadius = false
    end

    self:tickPending(nowMs)
end


-- =====================================================================
-- Schedule a play (with optional delay)
-- =====================================================================
function MemorialTrigger:schedulePlay()
    if self.sample == nil then return end
    if self.config.playOnce and self.hasPlayedOnce then return end

    local nowMs = g_time or 0
    if nowMs - self.lastPlayTimeMs < self.config.cooldownMs then return end
    if self.pendingPlayAtMs ~= nil then return end  -- already scheduled

    local delay = self.config.startDelayMs or 0
    if delay > 0 then
        self.pendingPlayAtMs = nowMs + delay
    else
        self:doPlayNow()
    end
end


function MemorialTrigger:tickPending(nowMs)
    if self.pendingPlayAtMs ~= nil and nowMs >= self.pendingPlayAtMs then
        self:doPlayNow()
    end
end


function MemorialTrigger:doPlayNow()
    if self.sample == nil then return end
    playSample(self.sample, 1, self.config.volume, 0, 0, 0)
    self.lastPlayTimeMs  = g_time or 0
    self.hasPlayedOnce   = true
    self.pendingPlayAtMs = nil
end


-- =====================================================================
-- Cleanup
-- =====================================================================
function MemorialTrigger:delete()
    if self.sample ~= nil then
        pcall(delete, self.sample)
        self.sample = nil
    end
end


-- =====================================================================
-- Setup: find named nodes and create instances
-- =====================================================================
local function findNodesByName(rootNode, nameToFind, results)
    results = results or {}
    if rootNode == nil or rootNode == 0 then return results end
    local ok, name = pcall(getName, rootNode)
    if ok and name == nameToFind then
        table.insert(results, rootNode)
    end
    local okN, n = pcall(getNumOfChildren, rootNode)
    if okN and n ~= nil then
        for i = 0, n - 1 do
            local okC, child = pcall(getChildAt, rootNode, i)
            if okC and child ~= nil and child ~= 0 then
                findNodesByName(child, nameToFind, results)
            end
        end
    end
    return results
end


local function setupAllTriggers()
    local searchRoots = {}
    if g_currentMission ~= nil then
        if g_currentMission.terrainRootNode ~= nil then
            table.insert(searchRoots, g_currentMission.terrainRootNode)
        end
        if g_currentMission.maps ~= nil then
            for _, mapNode in pairs(g_currentMission.maps) do
                if mapNode ~= nil and mapNode ~= 0 then
                    table.insert(searchRoots, mapNode)
                end
            end
        end
    end
    if #searchRoots == 0 then table.insert(searchRoots, 0) end

    for nodeName, config in pairs(MemorialTrigger.NODE_NAMES) do
        local found = {}
        for _, root in ipairs(searchRoots) do
            findNodesByName(root, nodeName, found)
        end
        if #found == 0 then
            Logging.warning("[MemorialTrigger] No node named '%s' in map", nodeName)
        else
            for _, node in ipairs(found) do
                local instance = MemorialTrigger.new(node, config)
                if instance ~= nil then
                    table.insert(MemorialTrigger.instances, instance)
                end
            end
        end
    end
end


local function updateAllInstances()
    if #MemorialTrigger.instances == 0 then return end
    local nowMs = g_time or 0
    for _, instance in ipairs(MemorialTrigger.instances) do
        instance:update(nowMs)
    end
end


local function cleanupAllInstances()
    for _, instance in ipairs(MemorialTrigger.instances) do
        instance:delete()
    end
    MemorialTrigger.instances = {}
end


-- =====================================================================
-- Console command (kept for testing; safe to leave in)
-- =====================================================================
local function cmd_play()
    if #MemorialTrigger.instances == 0 then
        return "[MemorialTrigger] No instances loaded."
    end
    for _, inst in ipairs(MemorialTrigger.instances) do
        inst.lastPlayTimeMs  = -math.huge
        inst.pendingPlayAtMs = nil
        inst:doPlayNow()
    end
    return "[MemorialTrigger] Played."
end

if addConsoleCommand ~= nil then
    addConsoleCommand("mtPlay", "Play memorial audio now", "cmd_play", { cmd_play = cmd_play })
end


-- =====================================================================
-- Hooks
-- =====================================================================
if FSBaseMission ~= nil and FSBaseMission.loadMapFinished ~= nil and Utils ~= nil and Utils.appendedFunction ~= nil then
    FSBaseMission.loadMapFinished = Utils.appendedFunction(
        FSBaseMission.loadMapFinished,
        function(self) setupAllTriggers() end
    )
end

if BaseMission ~= nil and BaseMission.update ~= nil and Utils ~= nil and Utils.appendedFunction ~= nil then
    BaseMission.update = Utils.appendedFunction(
        BaseMission.update,
        function(self, dt) updateAllInstances() end
    )
end

if g_messageCenter ~= nil and MessageType ~= nil and MessageType.MISSION_DELETED ~= nil then
    g_messageCenter:subscribe(MessageType.MISSION_DELETED, cleanupAllInstances, MemorialTrigger)
end

-- Backwards-compat stub (in case an old onCreate user attribute is still on the node)
function MemorialTrigger.onCreate(nodeId)
    -- No-op
end
