--
-- GateObstruction.lua
--
-- Places a "pay to clear" fallen tree trunk / bushes obstruction at a
-- gateway. While uncleared, it also locks the underlying gate door itself
-- (AnimatedObject.isEnabled = false) -- so the gate can't be opened even
-- though the door isn't part of the obstruction's own i3d group. Paying
-- removes the obstruction and unlocks the gate, permanently, per savegame.
--
-- Multiplayer-safe:
--   * Money is only ever changed on the server (GateObstructionClearEvent).
--   * The resulting cleared state (visibility + gate unlock) is broadcast
--     to every client, not just applied locally on whoever paid.
--
-- Wiring (Giants Editor):
--   1. Create a TransformGroup at the gateway, name it exactly:
--          gateObstruction_<uniqueId>          e.g. gateObstruction_field99
--      Put the trunk + bush meshes inside it as children.
--   2. Inside that same group, add a Shape (box/cylinder) covering the
--      gateway approach, flag it as a Trigger with the PLAYER collision
--      mask, and name it exactly:
--          gateObstruction_<uniqueId>_trigger
--   3. The underlying gate door gets locked automatically, tried in order:
--        a. GateObstruction.GATE_NODE_IDS[uniqueId], an exact GE10 node id
--           (verified live -- falls through if the id doesn't resolve).
--        b. The nearest farm-fence gate within FENCE_GATE_SEARCH_RADIUS.
--        c. The nearest standalone gate/door placeable within
--           PLACEABLE_GATE_SEARCH_RADIUS.
--      A spot with no match locks nothing but still works as a visual +
--      trigger obstruction.
--   4. Save the i3d.
--
-- First test spot: gateObstruction_field99
--

GateObstruction = {}

local GateObstruction_mt = Class(GateObstruction)

-- =====================================================================
-- Configuration
-- =====================================================================
GateObstruction.DEFAULT_PRICE = 1850   -- covers trunk/bush removal + fitting a new gate

-- Two separate gate mechanisms exist on this map, matched separately:
--  1. Farm-fence gates (spec_newFence.fence.segments) -- matched by the midpoint of the
--     whole fence run, which can sit tens of metres from the actual visual door, so this
--     needs a generous radius. Only 4 such gates exist on the whole map, so that's safe.
--  2. Standalone gate/door placeables (spec_animatedObjects, e.g. the estate's ornamental
--     archway gates) -- matched by the owning placeable's own position, which sits right
--     next to the door, so a tight radius is correct here and avoids accidentally locking
--     an unrelated nearby building's door (532 placeables carry this generic spec).
GateObstruction.FENCE_GATE_SEARCH_RADIUS      = 80.0
GateObstruction.PLACEABLE_GATE_SEARCH_RADIUS  = 15.0

-- Explicit gate match by the exact Giants Editor node ID (shown in GE10's inspector when
-- you select the gate). NOTE: this numeric id is only guaranteed stable *within one engine
-- session* -- it may be reassigned when the actual game loads the same map, so this is
-- verified live via entityExists() at scan time rather than trusted blindly. When it does
-- resolve, every AnimatedObject on the same placeable as that node gets locked (sidesteps
-- saveId collisions entirely). Obstructions without a working match here fall back to the
-- proximity search.
GateObstruction.GATE_NODE_IDS = {
    ["field99"] = 799260,
}

-- Per-spot price overrides, keyed by uniqueId (the part after "gateObstruction_").
-- Anything not listed here uses GateObstruction.DEFAULT_PRICE.
GateObstruction.PRICES = {
    ["field99"] = 1850,   -- test spot
}

GateObstruction.instances      = {}
GateObstruction.instancesById  = {}
GateObstruction.clearedIds     = {}   -- set of uniqueId -> true, loaded from savegame
GateObstruction.SAVE_FILENAME  = "gateObstructions.xml"
GateObstruction.gateScanPending  = true
GateObstruction.gateScanWaitedMs = 0


-- =====================================================================
-- Constructor
-- =====================================================================
function GateObstruction.new(uniqueId, visualNode, triggerNode)
    local self = setmetatable({}, GateObstruction_mt)

    self.uniqueId    = uniqueId
    self.visualNode  = visualNode
    self.triggerNode = triggerNode
    self.price       = GateObstruction.PRICES[uniqueId] or GateObstruction.DEFAULT_PRICE
    self.gateAnimatedObjects = {}   -- matched AnimatedObject instances to lock/unlock
    self.activatable = nil
    self.isCleared   = GateObstruction.clearedIds[uniqueId] == true

    return self
end


-- =====================================================================
-- Activatable (drives the native on-screen "hold to interact" prompt
-- while the local player stands in the trigger)
-- =====================================================================
GateObstructionActivatable = {}
local GateObstructionActivatable_mt = Class(GateObstructionActivatable)

function GateObstructionActivatable.new(obstruction)
    local self = setmetatable({}, GateObstructionActivatable_mt)
    self.obstruction = obstruction

    local priceText = "£" .. tostring(obstruction.price)
    if g_i18n ~= nil and g_i18n.formatMoney ~= nil then
        local ok, formatted = pcall(g_i18n.formatMoney, g_i18n, obstruction.price, 0, true, true)
        if ok and formatted ~= nil then priceText = formatted end
    end
    self.activateText = string.format("Clear fallen tree & undergrowth (%s)", priceText)

    return self
end

function GateObstructionActivatable:getIsActivatable()
    return self.obstruction ~= nil and not self.obstruction.isCleared
end

function GateObstructionActivatable:run()
    self.obstruction:promptClear()
end

function GateObstructionActivatable:getDistance(x, y, z)
    if self.obstruction == nil or self.obstruction.triggerNode == nil then return math.huge end
    local ok, tx, ty, tz = pcall(getWorldTranslation, self.obstruction.triggerNode)
    if not ok or tx == nil then return math.huge end
    local dx, dy, dz = x - tx, y - ty, z - tz
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end


-- =====================================================================
-- Trigger callback: player enters/leaves -> show/hide the prompt
-- =====================================================================
function GateObstruction:onTrigger(triggerId, otherId, onEnter, onLeave, onStay)
    if self.isCleared then return end
    if not (onEnter or onLeave) then return end
    if g_localPlayer == nil or otherId ~= g_localPlayer.rootNode then return end

    if onEnter then
        if self.activatable == nil then
            self.activatable = GateObstructionActivatable.new(self)
        end
        g_currentMission.activatableObjectsSystem:addActivatable(self.activatable)
    elseif onLeave then
        if self.activatable ~= nil then
            g_currentMission.activatableObjectsSystem:removeActivatable(self.activatable)
        end
    end
end


-- =====================================================================
-- Confirm dialog + payment request
-- =====================================================================
function GateObstruction:promptClear()
    local priceText = "£" .. tostring(self.price)
    if g_i18n ~= nil and g_i18n.formatMoney ~= nil then
        local ok, formatted = pcall(g_i18n.formatMoney, g_i18n, self.price, 0, true, true)
        if ok and formatted ~= nil then priceText = formatted end
    end

    YesNoDialog.show(
        self.onConfirmClear,
        self,
        string.format("Clear the fallen tree and undergrowth, and fit a new gate, for %s?", priceText),
        "Gateway Obstruction"
    )
end

function GateObstruction:onConfirmClear(yes)
    if not yes or self.isCleared then return end

    if g_currentMission:getMoney() < self.price then
        InfoDialog.show("Not enough money to clear this obstruction.")
        return
    end

    GateObstructionClearEvent.sendToServer(self.uniqueId, g_currentMission:getFarmId(), self.price)
end


-- =====================================================================
-- Apply a clear (called on every machine once the server confirms it)
-- =====================================================================
local function disableCollisionRecursive(node)
    if node == nil or node == 0 then return end
    local okShape, isShape = pcall(getHasClassId, node, ClassIds.SHAPE)
    if okShape and isShape then
        pcall(setCollisionMask, node, 0)
    end
    local okN, n = pcall(getNumOfChildren, node)
    if okN and n ~= nil then
        for i = 0, n - 1 do
            local okC, child = pcall(getChildAt, node, i)
            if okC and child ~= nil and child ~= 0 then
                disableCollisionRecursive(child)
            end
        end
    end
end

function GateObstruction:applyClear()
    if self.isCleared then return end
    self.isCleared = true
    GateObstruction.clearedIds[self.uniqueId] = true

    if self.visualNode ~= nil then
        pcall(setVisibility, self.visualNode, false)
        disableCollisionRecursive(self.visualNode)
    end
    if self.triggerNode ~= nil then
        pcall(removeTrigger, self.triggerNode)
    end
    if self.activatable ~= nil then
        pcall(function() g_currentMission.activatableObjectsSystem:removeActivatable(self.activatable) end)
        self.activatable = nil
    end

    self:setGateLocked(false)
end

function GateObstruction:setGateLocked(locked)
    for _, animObj in ipairs(self.gateAnimatedObjects) do
        pcall(function() animObj.isEnabled = not locked end)
    end
end


-- =====================================================================
-- Gate matching: find nearby gate door(s) once placeables have loaded
-- =====================================================================
local function findNearbyGateAnimatedObjects(x, z, maxDist)
    local found = {}
    if g_currentMission == nil or g_currentMission.placeableSystem == nil then return found end

    local numFencePlaceables, numSegments, numGateSegments, closestDist = 0, 0, 0, math.huge

    for _, placeable in pairs(g_currentMission.placeableSystem.placeables) do
        -- This map's fences use the newer "newFence" specialization: the segment
        -- list lives on spec_newFence.fence (a Fence class instance), not directly
        -- on the spec table. Confirmed via live diagnostic against decompiled source.
        local ok, fence = pcall(function() return placeable.spec_newFence and placeable.spec_newFence.fence end)
        if ok and fence ~= nil and fence.segments ~= nil then
            numFencePlaceables = numFencePlaceables + 1
            for _, segment in pairs(fence.segments) do
                numSegments = numSegments + 1
                if segment.animatedObjects ~= nil and segment.startPosX ~= nil and segment.endPosX ~= nil then
                    numGateSegments = numGateSegments + 1
                    local mx = (segment.startPosX + segment.endPosX) / 2
                    local mz = (segment.startPosZ + segment.endPosZ) / 2
                    local dx, dz = x - mx, z - mz
                    local dist = math.sqrt(dx * dx + dz * dz)
                    if dist < closestDist then closestDist = dist end
                    if dist <= maxDist then
                        for _, animObj in ipairs(segment.animatedObjects) do
                            table.insert(found, animObj)
                        end
                    end
                end
            end
        end
    end

    Logging.info("[GateObstruction] Gate scan: fencePlaceables=%d totalSegments=%d gateSegments=%d closestGateDist=%s matchedWithin%dm=%d",
        numFencePlaceables, numSegments, numGateSegments,
        closestDist == math.huge and "n/a" or string.format("%.1f", closestDist), maxDist, #found)

    return found
end

-- Standalone gate/door placeables (spec_animatedObjects) -- matched by the owning
-- placeable's own world position, which sits right next to the door itself.
local function findNearbyPlaceableAnimatedObjects(x, z, maxDist)
    local found = {}
    if g_currentMission == nil or g_currentMission.placeableSystem == nil then return found end

    local numWithAnimObjs, closestDist = 0, math.huge

    for _, placeable in pairs(g_currentMission.placeableSystem.placeables) do
        local ok, animObjs = pcall(function()
            return placeable.spec_animatedObjects and placeable.spec_animatedObjects.animatedObjects
        end)
        if ok and animObjs ~= nil and #animObjs > 0 then
            local okPos, px, _, pz = pcall(getWorldTranslation, placeable.rootNode)
            if okPos and px ~= nil then
                numWithAnimObjs = numWithAnimObjs + 1
                local dx, dz = x - px, z - pz
                local dist = math.sqrt(dx * dx + dz * dz)
                if dist < closestDist then closestDist = dist end
                if dist <= maxDist then
                    for _, animObj in ipairs(animObjs) do
                        table.insert(found, animObj)
                    end
                end
            end
        end
    end

    Logging.info("[GateObstruction] Placeable-door scan: withAnimatedObjects=%d closestDist=%s matchedWithin%dm=%d",
        numWithAnimObjs, closestDist == math.huge and "n/a" or string.format("%.1f", closestDist), maxDist, #found)

    return found
end

-- Match by the exact Giants Editor node id. Verified live (entityExists) since GE10's
-- numeric ids aren't guaranteed to survive into an actual game session. When the node is
-- found, resolves the owning placeable and locks every AnimatedObject on it -- avoids
-- needing an exact saveId match at all.
local function findGateAnimatedObjectsByNodeId(nodeId)
    if nodeId == nil then return {}, "no nodeId configured" end

    local okExists, exists = pcall(entityExists, nodeId)
    if not okExists or not exists then
        return {}, string.format("node %s does not exist in this session (GE10 ids are session-local, as expected)", tostring(nodeId))
    end

    local okName, name = pcall(getName, nodeId)

    -- Try the direct engine lookup first (works when nodeId is itself a registered
    -- trigger/shape target).
    local placeable = nil
    if g_currentMission ~= nil and g_currentMission.nodeToObject ~= nil then
        local okDirect, direct = pcall(function() return g_currentMission.nodeToObject[nodeId] end)
        if okDirect and direct ~= nil then placeable = direct end
    end

    -- Fall back to walking up parents until we hit a node that is some placeable's
    -- own rootNode.
    if placeable == nil and g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil then
        local rootNodeToPlaceable = {}
        for _, p in pairs(g_currentMission.placeableSystem.placeables) do
            local okRoot, root = pcall(function() return p.rootNode end)
            if okRoot and root ~= nil then rootNodeToPlaceable[root] = p end
        end

        local current = nodeId
        for _ = 1, 64 do
            if rootNodeToPlaceable[current] ~= nil then
                placeable = rootNodeToPlaceable[current]
                break
            end
            local okParent, parent = pcall(getParent, current)
            if not okParent or parent == nil or parent == 0 then break end
            current = parent
        end
    end

    if placeable == nil then
        return {}, string.format("node %s ('%s') exists but no owning placeable could be resolved",
            tostring(nodeId), okName and tostring(name) or "?")
    end

    local found = {}
    local okAnim, animObjs = pcall(function()
        return placeable.spec_animatedObjects and placeable.spec_animatedObjects.animatedObjects
    end)
    if okAnim and animObjs ~= nil then
        for _, animObj in ipairs(animObjs) do table.insert(found, animObj) end
    end
    local okFence, fence = pcall(function() return placeable.spec_newFence and placeable.spec_newFence.fence end)
    if okFence and fence ~= nil and fence.segments ~= nil then
        for _, segment in pairs(fence.segments) do
            if segment.animatedObjects ~= nil then
                for _, animObj in ipairs(segment.animatedObjects) do table.insert(found, animObj) end
            end
        end
    end

    return found, string.format("node %s ('%s') resolved to a placeable with %d animatedObject(s)",
        tostring(nodeId), okName and tostring(name) or "?", #found)
end

local function hasAnyFencePlaceables()
    if g_currentMission == nil or g_currentMission.placeableSystem == nil then return false end
    for _, placeable in pairs(g_currentMission.placeableSystem.placeables) do
        local ok, fence = pcall(function() return placeable.spec_newFence and placeable.spec_newFence.fence end)
        if ok and fence ~= nil then return true end
    end
    return false
end

local function runGateScan()
    local totalLocked = 0
    for _, obstruction in ipairs(GateObstruction.instances) do
        if not obstruction.isCleared then
            obstruction.gateAnimatedObjects = {}
            local nodeId = GateObstruction.GATE_NODE_IDS[obstruction.uniqueId]

            if nodeId ~= nil then
                local matches, detail = findGateAnimatedObjectsByNodeId(nodeId)
                if #matches > 0 then
                    obstruction.gateAnimatedObjects = matches
                    Logging.info("[GateObstruction] '%s': matched by GE10 node id %s -- %s",
                        obstruction.uniqueId, tostring(nodeId), detail)
                else
                    Logging.warning("[GateObstruction] '%s': node id %s match failed (%s) -- falling back to proximity search",
                        obstruction.uniqueId, tostring(nodeId), detail)
                end
            end

            if #obstruction.gateAnimatedObjects == 0 then
                local ox, _, oz
                local ok
                ok, ox, _, oz = pcall(getWorldTranslation, obstruction.visualNode)
                if ok and ox ~= nil then
                    local fenceGates = findNearbyGateAnimatedObjects(ox, oz, GateObstruction.FENCE_GATE_SEARCH_RADIUS)
                    local placeableGates = findNearbyPlaceableAnimatedObjects(ox, oz, GateObstruction.PLACEABLE_GATE_SEARCH_RADIUS)
                    for _, animObj in ipairs(fenceGates) do table.insert(obstruction.gateAnimatedObjects, animObj) end
                    for _, animObj in ipairs(placeableGates) do table.insert(obstruction.gateAnimatedObjects, animObj) end
                end
            end

            obstruction:setGateLocked(true)
            totalLocked = totalLocked + #obstruction.gateAnimatedObjects
        end
    end
    Logging.info("[GateObstruction] Gate scan complete: locked %d gate door(s) across %d obstruction(s)",
        totalLocked, #GateObstruction.instances)
end


-- =====================================================================
-- Savegame persistence
-- =====================================================================
local function loadClearedState()
    GateObstruction.clearedIds = {}

    local missionInfo = g_currentMission and g_currentMission.missionInfo
    if missionInfo == nil or missionInfo.savegameDirectory == nil then return end

    local path = missionInfo.savegameDirectory .. "/" .. GateObstruction.SAVE_FILENAME
    local xmlFile = loadXMLFile("gateObstructions", path)
    if xmlFile == nil or xmlFile == 0 then return end

    local i = 0
    while true do
        local key = string.format("gateObstructions.cleared(%d)", i)
        local id = getXMLString(xmlFile, key .. "#id")
        if id == nil then break end
        GateObstruction.clearedIds[id] = true
        i = i + 1
    end

    delete(xmlFile)
    Logging.info("[GateObstruction] Loaded %d cleared obstruction(s) from savegame", i)
end

local function saveClearedState(savegameDirectory)
    if savegameDirectory == nil then return end
    local path = savegameDirectory .. "/" .. GateObstruction.SAVE_FILENAME

    local xmlFile = createXMLFile("gateObstructionsWrite", path, "gateObstructions")
    if xmlFile == nil or xmlFile == 0 then
        Logging.warning("[GateObstruction] Could not write %s", path)
        return
    end

    local i = 0
    for id, cleared in pairs(GateObstruction.clearedIds) do
        if cleared then
            setXMLString(xmlFile, string.format("gateObstructions.cleared(%d)#id", i), id)
            i = i + 1
        end
    end

    saveXMLFile(xmlFile)
    delete(xmlFile)
end


-- =====================================================================
-- Setup: find named nodes and create instances
-- =====================================================================
local function findNodesByPrefix(rootNode, prefix, suffix, results)
    results = results or {}
    if rootNode == nil or rootNode == 0 then return results end
    local ok, name = pcall(getName, rootNode)
    if ok and name ~= nil and name:sub(1, #prefix) == prefix and name:sub(-#suffix) == suffix then
        table.insert(results, rootNode)
    end
    local okN, n = pcall(getNumOfChildren, rootNode)
    if okN and n ~= nil then
        for i = 0, n - 1 do
            local okC, child = pcall(getChildAt, rootNode, i)
            if okC and child ~= nil and child ~= 0 then
                findNodesByPrefix(child, prefix, suffix, results)
            end
        end
    end
    return results
end

local function setupAllObstructions()
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

    loadClearedState()

    local triggerNodes = {}
    for _, root in ipairs(searchRoots) do
        findNodesByPrefix(root, "gateObstruction_", "_trigger", triggerNodes)
    end

    if #triggerNodes == 0 then
        Logging.warning("[GateObstruction] No 'gateObstruction_<id>_trigger' nodes found in map")
        return
    end

    for _, triggerNode in ipairs(triggerNodes) do
        local okName, fullName = pcall(getName, triggerNode)
        if okName and fullName ~= nil then
            local uniqueId = fullName:sub(#"gateObstruction_" + 1, -(#"_trigger" + 1))
            local okParent, visualNode = pcall(getParent, triggerNode)

            if okParent and visualNode ~= nil and visualNode ~= 0 then
                local instance = GateObstruction.new(uniqueId, visualNode, triggerNode)
                table.insert(GateObstruction.instances, instance)
                GateObstruction.instancesById[uniqueId] = instance

                if instance.isCleared then
                    pcall(setVisibility, visualNode, false)
                    disableCollisionRecursive(visualNode)
                else
                    local ok = pcall(addTrigger, triggerNode, "onTrigger", instance)
                    if not ok then
                        Logging.error("[GateObstruction] Failed to register trigger for '%s'", uniqueId)
                    end
                end

                Logging.info("[GateObstruction] Registered '%s' (price=%d, cleared=%s)",
                    uniqueId, instance.price, tostring(instance.isCleared))
            end
        end
    end
end

local function cleanupAllInstances()
    for _, instance in ipairs(GateObstruction.instances) do
        if instance.triggerNode ~= nil and not instance.isCleared then
            pcall(removeTrigger, instance.triggerNode)
        end
        if instance.activatable ~= nil then
            pcall(function() g_currentMission.activatableObjectsSystem:removeActivatable(instance.activatable) end)
        end
    end
    GateObstruction.instances     = {}
    GateObstruction.instancesById = {}
    GateObstruction.gateScanPending  = true
    GateObstruction.gateScanWaitedMs = 0
end


-- =====================================================================
-- Per-frame: defer the gate-lock scan until Fence placeables have
-- actually loaded (they load in progressively after loadMapFinished,
-- same reasoning as OpeningHours.lua's production-boost wait).
-- =====================================================================
local function updateGateScan(dt)
    if not GateObstruction.gateScanPending then return end
    if #GateObstruction.instances == 0 then return end

    GateObstruction.gateScanWaitedMs = GateObstruction.gateScanWaitedMs + dt
    if hasAnyFencePlaceables() or GateObstruction.gateScanWaitedMs >= 15000 then
        GateObstruction.gateScanPending = false
        runGateScan()
    end
end


-- =====================================================================
-- Networked event: server-authoritative payment + broadcast the result
-- =====================================================================
GateObstructionClearEvent = {}
local GateObstructionClearEvent_mt = Class(GateObstructionClearEvent, Event)

InitEventClass(GateObstructionClearEvent, "GateObstructionClearEvent")

function GateObstructionClearEvent.emptyNew()
    return Event.new(GateObstructionClearEvent_mt)
end

function GateObstructionClearEvent.new(uniqueId, farmId, price)
    local self = GateObstructionClearEvent.emptyNew()
    self.uniqueId = uniqueId
    self.farmId   = farmId
    self.price    = price
    return self
end

function GateObstructionClearEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.uniqueId)
    streamWriteUIntN(streamId, self.farmId, 6)
    streamWriteInt32(streamId, self.price)
end

function GateObstructionClearEvent:readStream(streamId, connection)
    self.uniqueId = streamReadString(streamId)
    self.farmId   = streamReadUIntN(streamId, 6)
    self.price    = streamReadInt32(streamId)
    self:run(connection)
end

function GateObstructionClearEvent:run(connection)
    local obstruction = GateObstruction.instancesById[self.uniqueId]
    if obstruction == nil or obstruction.isCleared then return end

    if g_server ~= nil then
        local farm = g_farmManager ~= nil and g_farmManager:getFarmById(self.farmId) or nil
        if farm == nil or farm.money < self.price then return end

        g_currentMission:addMoney(-self.price, self.farmId, MoneyType.OTHER, true, true)
        obstruction:applyClear()
        g_server:broadcastEvent(GateObstructionClearEvent.new(self.uniqueId, self.farmId, self.price), false, connection)
    else
        obstruction:applyClear()
    end
end

-- Sent by whichever machine confirmed the Yes/No dialog.
function GateObstructionClearEvent.sendToServer(uniqueId, farmId, price)
    local event = GateObstructionClearEvent.new(uniqueId, farmId, price)
    if g_server ~= nil then
        event:run(nil)
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(event)
    end
end


-- =====================================================================
-- Savegame save hook
-- =====================================================================
GateObstructionSaveHook = {}
function GateObstructionSaveHook:saveToXMLFile()
    saveClearedState(self.savegameDirectory)
end

if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil and Utils ~= nil and Utils.appendedFunction ~= nil then
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, GateObstructionSaveHook.saveToXMLFile)
end


-- =====================================================================
-- Hooks
-- =====================================================================
if FSBaseMission ~= nil and FSBaseMission.loadMapFinished ~= nil and Utils ~= nil and Utils.appendedFunction ~= nil then
    FSBaseMission.loadMapFinished = Utils.appendedFunction(
        FSBaseMission.loadMapFinished,
        function(self) setupAllObstructions() end
    )
end

if BaseMission ~= nil and BaseMission.update ~= nil and Utils ~= nil and Utils.appendedFunction ~= nil then
    BaseMission.update = Utils.appendedFunction(
        BaseMission.update,
        function(self, dt) updateGateScan(dt) end
    )
end

if g_messageCenter ~= nil and MessageType ~= nil and MessageType.MISSION_DELETED ~= nil then
    g_messageCenter:subscribe(MessageType.MISSION_DELETED, cleanupAllInstances, GateObstruction)
end
