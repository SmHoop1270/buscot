UIManager = {}
local UIManager_mt = Class(UIManager)

function UIManager.new()
    local self = setmetatable({}, UIManager_mt)
    self.cooldowns       = {}
    self.tempMessage     = nil
    self.tempMessageEnd  = 0
    self.blockedMessage  = nil
    self.blockedEnd      = 0
    return self
end

-- General notification - open/close state changes etc
-- Shows amber text, fades after durationMs (default 10 seconds)
function UIManager:notify(text, cooldownMs)
    cooldownMs = cooldownMs or 10000
    local now  = g_time or 0
    local last = self.cooldowns[text] or (now - cooldownMs - 1)
    if (now - last) < cooldownMs then return end
    self.cooldowns[text] = now
    self.tempMessage    = text
    self.tempMessageEnd = now + 10000
end

-- Blocked action notification - tipping or buying outside hours
-- Shows red text, stays visible for durationMs (default 15 seconds)
function UIManager:blocked(text, durationMs)
    self.blockedMessage = text
    self.blockedEnd     = (g_time or 0) + (durationMs or 15000)
end

-- Legacy pulse call still works - maps to blocked with default message
function UIManager:pulse(durationMs)
    self.blockedEnd = (g_time or 0) + (durationMs or 15000)
end

function UIManager:drawHUD(isOpen, scheduleManager)
    local ok, err = pcall(function() self:_render(isOpen, scheduleManager) end)
    if not ok then
        if not self.errorLogged then
            self.errorLogged = true
            print("[OpeningHours] drawHUD error: " .. tostring(err))
        end
    end
end

function UIManager:_render(isOpen, scheduleManager)
    if scheduleManager == nil then return end
    if g_currentMission == nil or g_currentMission.environment == nil then return end
    if not scheduleManager.enabled then
        self.tempMessage    = nil
        self.blockedMessage = nil
        return
    end

    local now  = g_time or 0
    local time = g_currentMission.environment.dayTime

    setTextAlignment(1)

    -- Blocked action message (red, larger, shown when player tries to sell/buy)
    if self.blockedMessage ~= nil and now < self.blockedEnd then
        local alpha     = 1.0
        local remaining = self.blockedEnd - now
        if remaining < 1500 then alpha = remaining / 1500 end
        setTextColor(1.0, 0.2, 0.2, alpha)
        setTextBold(true)
        renderText(0.5, 0.92, 0.030, self.blockedMessage)
        setTextBold(false)
    elseif self.blockedMessage ~= nil and now >= self.blockedEnd then
        self.blockedMessage = nil
    end

    -- General amber notification (open/close events)
    if self.tempMessage ~= nil and now < self.tempMessageEnd then
        local alpha     = 1.0
        local remaining = self.tempMessageEnd - now
        if remaining < 1500 then alpha = remaining / 1500 end
        setTextColor(1, 0.85, 0, alpha)
        setTextBold(true)
        renderText(0.5, 0.875, 0.024, self.tempMessage)
        setTextBold(false)
    elseif self.tempMessage ~= nil and now >= self.tempMessageEnd then
        self.tempMessage = nil
    end

    setTextColor(1, 1, 1, 1)
    setTextAlignment(0)
end

-- ============================================================
ScheduleManager = {}
local ScheduleManager_mt = Class(ScheduleManager)

function ScheduleManager.new()
    local self = setmetatable({}, ScheduleManager_mt)
    self.schedules  = {}
    self.enabled    = true
    self.xmlPath    = nil
    return self
end

local function parseHour(timeStr)
    local h, m = timeStr:match("(%d+):(%d+)")
    if h == nil then
        print("[OpeningHours] WARNING: could not parse time: " .. tostring(timeStr))
        return 0
    end
    return tonumber(h) + tonumber(m) / 60
end

local function formatHour(h)
    return string.format("%02d:%02d", math.floor(h), math.floor((h % 1) * 60))
end

function ScheduleManager:loadFromXML(path)
    self.xmlPath = path

    local xmlFile = loadXMLFile("openingHours", path)
    if xmlFile == nil or xmlFile == 0 then
        print("[OpeningHours] No saved settings found at " .. tostring(path) .. " - using defaults")
        self.enabled = true
        self.schedules.default = { {startHour = 8, endHour = 19} }
        return
    end

    local enabledVal = getXMLBool(xmlFile, "openingHours.settings#enabled")
    if enabledVal ~= nil then self.enabled = enabledVal end

    self.schedules.default = {}
    local i = 0
    while true do
        local key      = string.format("openingHours.default.period(%d)", i)
        local startStr = getXMLString(xmlFile, key .. "#start")
        if startStr == nil then break end
        local endStr = getXMLString(xmlFile, key .. "#end")
        table.insert(self.schedules.default, {
            startHour = parseHour(startStr),
            endHour   = parseHour(endStr)
        })
        i = i + 1
    end

    delete(xmlFile)

    if #self.schedules.default == 0 then
        print("[OpeningHours] WARNING: no periods found - using fallback")
        self.schedules.default = { {startHour = 8, endHour = 19} }
    end

    print(string.format("[OpeningHours] Loaded %d period(s) from %s  enabled=%s",
        #self.schedules.default, path, tostring(self.enabled)))
end

function ScheduleManager:saveToXML()
    local path = self.xmlPath
    if path == nil then
        print("[OpeningHours] WARNING: cannot save - no XML path set")
        return false
    end

    local xmlFile = createXMLFile("openingHoursWrite", path, "openingHours")
    if xmlFile == nil or xmlFile == 0 then
        print("[OpeningHours] WARNING: cannot write to " .. tostring(path))
        return false
    end

    setXMLBool(xmlFile, "openingHours.settings#enabled", self.enabled)

    for i, period in ipairs(self.schedules.default) do
        local key = string.format("openingHours.default.period(%d)", i - 1)
        setXMLString(xmlFile, key .. "#start", string.format("%02d:00", math.floor(period.startHour)))
        setXMLString(xmlFile, key .. "#end",   string.format("%02d:00", math.floor(period.endHour)))
    end

    saveXMLFile(xmlFile)
    delete(xmlFile)
    return true
end

function ScheduleManager:setEnabled(enabled)
    self.enabled = enabled
end

function ScheduleManager:setHours(startHour, endHour)
    self.schedules.default[1] = { startHour = startHour, endHour = endHour }
end

function ScheduleManager:getOpenHour()
    return self.schedules.default[1] and math.floor(self.schedules.default[1].startHour) or 8
end

function ScheduleManager:getCloseHour()
    return self.schedules.default[1] and math.floor(self.schedules.default[1].endHour) or 19
end

function ScheduleManager:isOpen(time, day)
    if not self.enabled then return true end
    local hour = time / (1000 * 60 * 60)
    for _, period in ipairs(self.schedules.default) do
        if hour >= period.startHour and hour <= period.endHour then
            return true
        end
    end
    return false
end

function ScheduleManager:getHoursString()
    if not self.enabled then return "Always open" end
    local parts = {}
    for _, period in ipairs(self.schedules.default) do
        table.insert(parts, formatHour(period.startHour) .. " - " .. formatHour(period.endHour))
    end
    return table.concat(parts, ", ")
end

function ScheduleManager:getNextOpenHour(time)
    if not self.enabled then return "now" end
    local hour = time / (1000 * 60 * 60)
    for _, period in ipairs(self.schedules.default) do
        if period.startHour > hour then return formatHour(period.startHour) end
    end
    return #self.schedules.default > 0 and formatHour(self.schedules.default[1].startHour) or "?"
end

-- ============================================================
-- QueueManager is retained as a stub for future use but is no longer active.
-- The queue approach was removed because sellFillType handles the entire transaction
-- (grain removal + payment) atomically. Intercepting it means grain stays in the
-- trailer, so there is nothing to queue -- the player just retries when the store opens.
QueueManager = {}
local QueueManager_mt = Class(QueueManager)

function QueueManager.new()
    local self = setmetatable({}, QueueManager_mt)
    return self
end

function QueueManager:processAll()
    -- No-op: queue approach removed. See SellPointExtension for current logic.
end

-- ============================================================
SellPointExtension = {}

local function isAIVehicle(vehicle)
    if vehicle == nil or type(vehicle) ~= "table" then return false end
    while vehicle.attacherVehicle ~= nil do
        vehicle = vehicle.attacherVehicle
    end
    if vehicle.spec_aiVehicle ~= nil and vehicle.spec_aiVehicle.isActive then
        return true
    end
    for _, player in pairs(g_currentMission.players) do
        if player.isControlled and player.controlledVehicle == vehicle then
            return false
        end
    end
    if g_currentMission.controlledVehicle == vehicle then
        return false
    end
    return true
end

function SellPointExtension.getIsFillAllowedFromFarm(self, superFunc, ...)
    local system = g_currentMission.openingHoursSystem
    if system ~= nil and not system.isOpen then
        if BaleUnloadTrigger ~= nil and self:isa(BaleUnloadTrigger) then
            return superFunc(self, ...)
        end
        if not self:isa(SellingStation) then
            return superFunc(self, ...)
        end
        local cv = g_currentMission.controlledVehicle
        if cv ~= nil then
            if cv.spec_combine ~= nil or cv.spec_trailer ~= nil or cv.spec_shovel ~= nil then
                local nextOpen = system.scheduleManager:getNextOpenHour(g_currentMission.environment.dayTime)
                system.uiManager:blocked("SHOP CLOSED  |  Opens at " .. nextOpen, 15000)
                return false
            end
        end
        return superFunc(self, ...)
    end
    return superFunc(self, ...)
end

function SellPointExtension.addFillLevelFromTool(self, superFunc, tool, ...)
    local system = g_currentMission.openingHoursSystem
    if system ~= nil and not system.isOpen then
        if BaleUnloadTrigger ~= nil and type(self) == "table" and self:isa(BaleUnloadTrigger) then
            return superFunc(self, tool, ...)
        end
        if not self:isa(SellingStation) then
            return superFunc(self, tool, ...)
        end
        if isAIVehicle(tool) then
            return superFunc(self, tool, ...)
        end
        return false
    end
    return superFunc(self, tool, ...)
end

function SellPointExtension.sell(self, superFunc, ...)
    local system = g_currentMission.openingHoursSystem
    if system == nil or system.isOpen then
        return superFunc(self, ...)
    end
    if not self:isa(SellingStation) then
        return superFunc(self, ...)
    end
    local args = {...}
    local tool = args[1]
    if tool ~= nil and isAIVehicle(tool) then
        return superFunc(self, ...)
    end
    if g_currentMission.controlledVehicle == nil then
        return superFunc(self, ...)
    end
    return 0
end

-- ============================================================
ShopExtension = {}

local function blockBuy(self, superFunc, ...)
    local system = g_currentMission.openingHoursSystem
    if system == nil or system.isOpen then return superFunc(self, ...) end
    local nextOpen = system.scheduleManager:getNextOpenHour(g_currentMission.environment.dayTime)
    system.uiManager:blocked("SHOP CLOSED  |  Opens at " .. nextOpen, 12000)
    return false
end

function ShopExtension.buyVehicle(self, superFunc, ...)  return blockBuy(self, superFunc, ...) end
function ShopExtension.buy(self, superFunc, ...)         return blockBuy(self, superFunc, ...) end
function ShopExtension.buyObject(self, superFunc, ...)   return blockBuy(self, superFunc, ...) end
function ShopExtension.buyHandTool(self, superFunc, ...) return blockBuy(self, superFunc, ...) end

-- ============================================================
-- ProductionExtension.lua
-- Production runs 24/7 at a boosted rate during opening hours so that
-- daily output equals what would be produced over a full 24-hour day.
--
-- Maths:
--   openHours  = closeHour - openHour  (e.g. 08:00-19:00 = 11 hours)
--   multiplier = 24 / openHours        (e.g. 24 / 11 = 2.18x)
--
-- Compatible with all production mods - only changes rate, no hooks on fill methods.

ProductionExtension = {}

ProductionExtension.originals = {}

local function getMultiplier(scheduleManager)
    local openHours = scheduleManager:getCloseHour() - scheduleManager:getOpenHour()
    if openHours <= 0 then openHours = 1 end
    return 24 / openHours
end

function ProductionExtension.applyMultiplier(multiplier)
    if g_currentMission == nil then return end
    local count = 0
    for _, placeable in pairs(g_currentMission.placeableSystem.placeables) do
        if placeable.spec_productionPoint ~= nil then
            local pp  = placeable.spec_productionPoint
            local key = tostring(placeable)
            if pp.productions ~= nil then
                if ProductionExtension.originals[key] == nil then
                    ProductionExtension.originals[key] = {}
                end
                for _, prod in pairs(pp.productions) do
                    local id = prod.id or tostring(prod)
                    if ProductionExtension.originals[key][id] == nil then
                        ProductionExtension.originals[key][id] = prod.cyclesPerHour
                    end
                    local orig = ProductionExtension.originals[key][id]
                    prod.cyclesPerHour   = orig * multiplier
                    prod.cyclesPerMinute = prod.cyclesPerHour / 60
                    prod.cyclesPerMonth  = prod.cyclesPerHour * 24
                    count = count + 1
                end
            end
        end
    end
    print(string.format("[OpeningHours] Production boost: %.2fx on %d productions", multiplier, count))
end

function ProductionExtension.restoreDefaults()
    if g_currentMission == nil then return end
    local count = 0
    for _, placeable in pairs(g_currentMission.placeableSystem.placeables) do
        if placeable.spec_productionPoint ~= nil then
            local pp  = placeable.spec_productionPoint
            local key = tostring(placeable)
            if pp.productions ~= nil and ProductionExtension.originals[key] ~= nil then
                for _, prod in pairs(pp.productions) do
                    local id   = prod.id or tostring(prod)
                    local orig = ProductionExtension.originals[key][id]
                    if orig ~= nil then
                        prod.cyclesPerHour   = orig
                        prod.cyclesPerMinute = orig / 60
                        prod.cyclesPerMonth  = orig * 24
                        count = count + 1
                    end
                end
            end
        end
    end
    print(string.format("[OpeningHours] Production restored to default on %d productions", count))
end

function ProductionExtension.onStateChange(isOpen, scheduleManager)
    if not scheduleManager.enabled then
        ProductionExtension.restoreDefaults()
        return
    end
    if isOpen then
        ProductionExtension.applyMultiplier(getMultiplier(scheduleManager))
    else
        ProductionExtension.restoreDefaults()
    end
end

-- ============================================================
-- Network event for syncing opening hours state.
-- On listen server: admin IS the server, broadcasts directly.
-- On dedicated server: admin is a client, sends to server which rebroadcasts.
-- Payload: 1 bit (enabled) + 5 bits (openHour 0-31) + 5 bits (closeHour 0-31) = 11 bits.

OpeningHoursEvent = {}
OpeningHoursEvent_mt = Class(OpeningHoursEvent, Event)

InitEventClass(OpeningHoursEvent, "OpeningHoursEvent")

function OpeningHoursEvent.emptyNew()
    local self = Event.new(OpeningHoursEvent_mt)
    return self
end

function OpeningHoursEvent.new(enabled, openHour, closeHour)
    local self = OpeningHoursEvent.emptyNew()
    self.enabled   = enabled
    self.openHour  = openHour
    self.closeHour = closeHour
    return self
end

function OpeningHoursEvent:writeStream(streamId, connection)
    streamWriteBool(streamId,   self.enabled)
    streamWriteUIntN(streamId,  self.openHour,  5)
    streamWriteUIntN(streamId,  self.closeHour, 5)
end

function OpeningHoursEvent:readStream(streamId, connection)
    self.enabled   = streamReadBool(streamId)
    self.openHour  = streamReadUIntN(streamId, 5)
    self.closeHour = streamReadUIntN(streamId, 5)
    self:run(connection)
end

function OpeningHoursEvent:run(connection)
    local system = g_currentMission and g_currentMission.openingHoursSystem
    if system == nil then return end

    -- If running on the dedicated server, apply and rebroadcast to all clients
    if g_server ~= nil then
        system.scheduleManager:setEnabled(self.enabled)
        system.scheduleManager:setHours(self.openHour, self.closeHour)
        system.isOpen = system.scheduleManager:isOpen(g_currentMission.environment.dayTime)
        ProductionExtension.onStateChange(system.isOpen, system.scheduleManager)
        g_server:broadcastEvent(OpeningHoursEvent.new(self.enabled, self.openHour, self.closeHour), false, connection)
        print(string.format("[OpeningHours] Server applied and rebroadcast: enabled=%s open=%02d:00 close=%02d:00",
            tostring(self.enabled), self.openHour, self.closeHour))
    else
        -- Client receiving from server - just apply locally
        system.scheduleManager:setEnabled(self.enabled)
        system.scheduleManager:setHours(self.openHour, self.closeHour)
        system.isOpen = system.scheduleManager:isOpen(g_currentMission.environment.dayTime)
        ProductionExtension.onStateChange(system.isOpen, system.scheduleManager)
        print(string.format("[OpeningHours] Client synced: enabled=%s open=%02d:00 close=%02d:00",
            tostring(self.enabled), self.openHour, self.closeHour))
    end
end

-- Send event - works for both listen server and dedicated server
function OpeningHoursEvent.broadcast(enabled, openHour, closeHour)
    local event = OpeningHoursEvent.new(enabled, openHour, closeHour)
    if g_server ~= nil then
        -- Listen server: we ARE the server, broadcast directly to all clients
        g_server:broadcastEvent(event, false)
    elseif g_client ~= nil then
        -- Dedicated server: we are a client, send to server which rebroadcasts
        g_client:getServerConnection():sendEvent(event)
    end
end

-- ============================================================
-- SettingsUI only runs on clients with a GUI (not on dedicated server)
OpeningHoursSettingsUI = {}
if g_gui ~= nil and g_gui.screenControllers ~= nil and g_gui.screenControllers[InGameMenu] ~= nil then
    local inGameMenu     = g_gui.screenControllers[InGameMenu]
    local settingsPage   = inGameMenu.pageSettings
    local settingsLayout = settingsPage.gameSettingsLayout
    local template       = settingsPage.checkWoodHarvesterAutoCutBox
    if settingsLayout ~= nil and template ~= nil then
        print("[OpeningHours] SettingsUI initialising...")

OpeningHoursSettingsUI              = {}
OpeningHoursSettingsUI.name         = settingsPage.name
OpeningHoursSettingsUI.controls     = {}
OpeningHoursSettingsUI.openGroup    = {}
OpeningHoursSettingsUI.closeGroup   = {}
OpeningHoursSettingsUI.collapsibles = {}
OpeningHoursSettingsUI.ignoreState  = false  -- guard against setState loops

local AM_LABELS = {
    "12:00 AM","1:00 AM","2:00 AM","3:00 AM","4:00 AM","5:00 AM",
    "6:00 AM","7:00 AM","8:00 AM","9:00 AM","10:00 AM","11:00 AM"
}
local PM_LABELS = {
    "12:00 PM","1:00 PM","2:00 PM","3:00 PM","4:00 PM","5:00 PM",
    "6:00 PM","7:00 PM","8:00 PM","9:00 PM","10:00 PM","11:00 PM"
}

local function refreshFocusIds(element)
    if not element then return end
    element.focusId = FocusManager:serveAutoFocusId()
    for _, child in pairs(element.elements) do refreshFocusIds(child) end
end

local function selectHour(group, hour)
    OpeningHoursSettingsUI.ignoreState = true
    for h, ctrl in pairs(group) do
        if ctrl ~= nil then ctrl:setState(h == hour and 2 or 1) end
    end
    OpeningHoursSettingsUI.ignoreState = false
end

local function setCollapsed(collapsed)
    for _, entry in ipairs(OpeningHoursSettingsUI.collapsibles) do
        if collapsed then
            entry.element:setSize(entry.w, 0)
            entry.element:setVisible(false)
        else
            entry.element:setSize(entry.w, entry.h)
            entry.element:setVisible(true)
        end
    end
    settingsLayout:invalidateLayout()
    if settingsPage.generalSettingsLayout then
        settingsPage.generalSettingsLayout:invalidateLayout()
    end
end

local function broadcastAndSave(system)
    system.scheduleManager:saveToXML()

    local enabled   = system.scheduleManager.enabled
    local openHour  = system.scheduleManager:getOpenHour()
    local closeHour = system.scheduleManager:getCloseHour()

    -- Broadcast to all clients
    OpeningHoursEvent.broadcast(enabled, openHour, closeHour)

    -- Apply on server using same path as clients so state is identical
    system.scheduleManager:setEnabled(enabled)
    system.scheduleManager:setHours(openHour, closeHour)
    system.isOpen = system.scheduleManager:isOpen(g_currentMission.environment.dayTime)
    ProductionExtension.onStateChange(system.isOpen, system.scheduleManager)

    local hours = system.scheduleManager:getHoursString()
    if system.isOpen then
        system.uiManager:notify("Stores and production are now open  |  " .. hours, 0)
    else
        local nextOpen = system.scheduleManager:getNextOpenHour(g_currentMission.environment.dayTime)
        system.uiManager:notify("Stores and production are now closed  |  Opens " .. nextOpen, 0)
    end
end

-- ── CALLBACKS defined BEFORE controls ────────────────────────────────────────

-- Used only for the Shop Hours Active toggle (genuine two-state)
function OpeningHoursSettingsUI.onEnabledChanged(self, state, option)
    local system = g_currentMission and g_currentMission.openingHoursSystem
    if system == nil then return end
    local enabling = (state == 2)
    system.scheduleManager:setEnabled(enabling)
    system.isOpen = system.scheduleManager:isOpen(g_currentMission.environment.dayTime)
    setCollapsed(not enabling)
    if enabling then
        system.uiManager:notify("Opening hours active  |  " .. system.scheduleManager:getHoursString(), 0)
    else
        system.uiManager:notify("Opening hours disabled  |  All stores now open", 0)
    end
    broadcastAndSave(system)
end

-- Used for hour rows - fires after state has settled
-- ignoreState guard prevents re-entry when selectHour calls setState
function OpeningHoursSettingsUI.onHourStateChanged(self, state, option)
    if OpeningHoursSettingsUI.ignoreState then return end

    local system = g_currentMission and g_currentMission.openingHoursSystem
    if system == nil then return end

    local id = option.id

    if id:sub(1, 8) == "oh_open_" then
        local hour = tonumber(id:sub(9))
        if hour == nil then return end

        if state == 1 then
            -- User clicked an On row turning it Off - snap it back to On immediately
            OpeningHoursSettingsUI.ignoreState = true
            option:setState(2)
            OpeningHoursSettingsUI.ignoreState = false
            return
        end

        -- state == 2: user clicked an Off row turning it On - this is a valid selection
        selectHour(OpeningHoursSettingsUI.openGroup, hour)
        settingsLayout:invalidateLayout()
        system.scheduleManager:setHours(hour, system.scheduleManager:getCloseHour())
        broadcastAndSave(system)

    elseif id:sub(1, 9) == "oh_close_" then
        local hour = tonumber(id:sub(10))
        if hour == nil then return end

        if state == 1 then
            OpeningHoursSettingsUI.ignoreState = true
            option:setState(2)
            OpeningHoursSettingsUI.ignoreState = false
            return
        end

        selectHour(OpeningHoursSettingsUI.closeGroup, hour)
        settingsLayout:invalidateLayout()
        system.scheduleManager:setHours(system.scheduleManager:getOpenHour(), hour)
        broadcastAndSave(system)
    end
end

-- ── Build controls ────────────────────────────────────────────────────────────

local function addToggle(id, labelText, texts, callbackName, collapsible)
    local box = template:clone(settingsLayout)
    if box == nil then return nil end
    box.id = id .. "_box"
    local option = box.elements[1]
    if option == nil then return nil end
    option.id     = id
    option.target = OpeningHoursSettingsUI
    option:setCallback("onClickCallback", callbackName)
    option:setDisabled(false)
    local tooltip = option.elements[1]
    if tooltip and tooltip.setText then tooltip:setText("") end
    local label = box.elements[2]
    if label then label:setText(labelText) end
    option:setTexts(texts)
    option:setState(1)
    refreshFocusIds(box)
    table.insert(settingsPage.controlsList, box)
    OpeningHoursSettingsUI.controls[id] = option
    if collapsible then
        table.insert(OpeningHoursSettingsUI.collapsibles, {
            element = box, w = box.size[1], h = box.size[2]
        })
    end
    return option
end

local function addHeader(text, collapsible)
    for _, elem in ipairs(settingsLayout.elements) do
        if elem.name == "sectionHeader" then
            local header = elem:clone(settingsLayout)
            if header then
                header:setText(text)
                header.focusId = FocusManager:serveAutoFocusId()
                table.insert(settingsPage.controlsList, header)
                OpeningHoursSettingsUI.controls["hdr_" .. text] = header
                if collapsible then
                    table.insert(OpeningHoursSettingsUI.collapsibles, {
                        element = header, w = header.size[1], h = header.size[2]
                    })
                end
            end
            return header
        end
    end
end

-- Shop Hours Active: uses onEnabledChanged (genuine two-state toggle)
addHeader("Opening Hours", false)
OpeningHoursSettingsUI.enabledControl = addToggle(
    "oh_enabled", "Shop Hours Active", {"Disabled","Enabled"}, "onEnabledChanged", false)

-- Hour rows: use onHourStateChanged (radio button enforcement)
addHeader("Opens at", true)
for h = 0, 11 do
    OpeningHoursSettingsUI.openGroup[h] = addToggle(
        "oh_open_" .. h, AM_LABELS[h + 1], {"Off","On"}, "onHourStateChanged", true)
end

addHeader("Closes at", true)
for h = 12, 23 do
    OpeningHoursSettingsUI.closeGroup[h] = addToggle(
        "oh_close_" .. h, PM_LABELS[h - 11], {"Off","On"}, "onHourStateChanged", true)
end

settingsLayout:invalidateLayout()
print("[OpeningHours] SettingsUI ready - " .. #OpeningHoursSettingsUI.collapsibles .. " collapsibles")

-- ── Sync when settings screen opens ──────────────────────────────────────────

InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen, function()
    local system  = g_currentMission and g_currentMission.openingHoursSystem
    local isAdmin = g_currentMission ~= nil and
                    (not g_currentMission.missionDynamicInfo.isMultiplayer or
                     g_currentMission:getIsServer() or
                     g_currentMission.isMasterUser)

    if system ~= nil and system.scheduleManager ~= nil then
        local sm = system.scheduleManager
        if OpeningHoursSettingsUI.enabledControl then
            OpeningHoursSettingsUI.enabledControl:setState(sm.enabled and 2 or 1)
        end
        selectHour(OpeningHoursSettingsUI.openGroup,  sm:getOpenHour())
        selectHour(OpeningHoursSettingsUI.closeGroup, sm:getCloseHour())
        setCollapsed(not sm.enabled)
    end

    for id, control in pairs(OpeningHoursSettingsUI.controls) do
        if id:sub(1, 4) ~= "hdr_" and control.setDisabled then
            control:setDisabled(not isAdmin)
        end
    end
end)

FocusManager.setGui = Utils.appendedFunction(FocusManager.setGui, function(_, gui)
    if gui == "ingameMenuSettings" then
        for _, control in pairs(OpeningHoursSettingsUI.controls) do
            if not control.focusId or
               not FocusManager.currentFocusData.idToElementMapping[control.focusId] then
                FocusManager:loadElementFromCustomValues(control, nil, nil, false, false)
            end
        end
        if settingsPage.generalSettingsLayout then
            settingsPage.generalSettingsLayout:invalidateLayout()
        end
    end
end)

    print("[OpeningHours] SettingsUI ready")
    end -- settingsLayout check
end -- DS GUI guard

-- ============================================================
OpeningHoursSystem = {}
local OpeningHoursSystem_mt = Class(OpeningHoursSystem)

local MOD_DIR = g_currentModDirectory

function OpeningHoursSystem.new(mission)
    local self = setmetatable({}, OpeningHoursSystem_mt)
    self.mission         = mission
    self.isOpen          = false
    self.sellHookApplied = false
    self.updateTimer     = 0
    self.boostPending    = false
    return self
end

function OpeningHoursSystem:trySellHook()
    if SellingStation ~= nil then
        if SellingStation.getIsFillAllowedFromFarm ~= nil then
            SellingStation.getIsFillAllowedFromFarm = Utils.overwrittenFunction(
                SellingStation.getIsFillAllowedFromFarm, SellPointExtension.getIsFillAllowedFromFarm)
            print("[OpeningHours] Sell hook: SellingStation.getIsFillAllowedFromFarm")
        end
        if SellingStation.addFillLevelFromTool ~= nil then
            SellingStation.addFillLevelFromTool = Utils.overwrittenFunction(
                SellingStation.addFillLevelFromTool, SellPointExtension.addFillLevelFromTool)
            print("[OpeningHours] Sell hook: SellingStation.addFillLevelFromTool")
        end
        if SellingStation.sellFillType ~= nil then
            SellingStation.sellFillType = Utils.overwrittenFunction(
                SellingStation.sellFillType, SellPointExtension.sell)
            print("[OpeningHours] Sell hook: SellingStation.sellFillType")
        end
        self.sellHookApplied = true
    end
end

function OpeningHoursSystem:loadMap(name)
    self.scheduleManager = ScheduleManager.new()
    self.scheduleManager:loadFromXML(Utils.getFilename("map/config/openingHours.xml", MOD_DIR))
    self.queueManager = QueueManager.new()
    self.uiManager    = UIManager.new()

    g_currentMission.openingHoursSystem = self

    self:trySellHook()

    if ShopController ~= nil then
        local hooks = {
            { method = "buyVehicle",  fn = ShopExtension.buyVehicle  },
            { method = "buy",         fn = ShopExtension.buy         },
            { method = "buyObject",   fn = ShopExtension.buyObject   },
            { method = "buyHandTool", fn = ShopExtension.buyHandTool },
        }
        for _, h in ipairs(hooks) do
            if ShopController[h.method] ~= nil then
                ShopController[h.method] = Utils.overwrittenFunction(ShopController[h.method], h.fn)
                print("[OpeningHours] Shop hook: ShopController." .. h.method)
            end
        end
    end

    -- Production boost applied on first update tick after placeables are loaded
    self.boostPending = true
    print("[OpeningHours] Production boost system ready (24h equivalent output during open hours)")

    if Mission00 ~= nil and Mission00.draw ~= nil then
        Mission00.draw = Utils.overwrittenFunction(Mission00.draw, function(mission, superFunc)
            superFunc(mission)
            local system = g_currentMission and g_currentMission.openingHoursSystem
            if system ~= nil and system.uiManager ~= nil then
                system.uiManager:drawHUD(system.isOpen, system.scheduleManager)
            end
        end)
        print("[OpeningHours] Draw hook registered")
    end

    -- Send current state to any client joining mid-session
    FSBaseMission.sendInitialClientState = Utils.appendedFunction(
        FSBaseMission.sendInitialClientState,
        function(mission, connection, user, farm)
            local system = g_currentMission and g_currentMission.openingHoursSystem
            if system ~= nil and g_server ~= nil then
                connection:sendEvent(OpeningHoursEvent.new(
                    system.scheduleManager.enabled,
                    system.scheduleManager:getOpenHour(),
                    system.scheduleManager:getCloseHour()
                ))
            end
        end)

    print("[OpeningHours] Loaded - settings in ESC > Settings")
end

function OpeningHoursSystem:deleteMap()
    g_currentMission.openingHoursSystem = nil
end

function OpeningHoursSystem:update(dt)
    if not self.sellHookApplied then
        self:trySellHook()
    end

    -- Apply initial production boost on first tick after placeables are loaded
    if self.boostPending then
        self.boostPending = false
        local time  = g_currentMission.environment.dayTime
        self.isOpen = self.scheduleManager:isOpen(time)
        ProductionExtension.onStateChange(self.isOpen, self.scheduleManager)
    end

    -- Throttle: check open/close transition once per second
    self.updateTimer = self.updateTimer + dt
    if self.updateTimer < 1000 then return end
    self.updateTimer = 0

    local time   = g_currentMission.environment.dayTime
    local isOpen = self.scheduleManager:isOpen(time)

    if isOpen ~= self.isOpen then
        self.isOpen = isOpen

        ProductionExtension.onStateChange(isOpen, self.scheduleManager)

        if g_server ~= nil then
            OpeningHoursEvent.broadcast(
                self.scheduleManager.enabled,
                self.scheduleManager:getOpenHour(),
                self.scheduleManager:getCloseHour()
            )
        end

        local hours = self.scheduleManager:getHoursString()
        if isOpen then
            self.uiManager:notify("Stores and production are now open  |  " .. hours, 0)
        else
            local nextOpen = self.scheduleManager:getNextOpenHour(time)
            self.uiManager:notify("Stores and production are now closed  |  Opens " .. nextOpen, 0)
        end
    end
end

local g_openingHoursSystem = OpeningHoursSystem.new(g_currentMission)
addModEventListener(g_openingHoursSystem)

print("[OpeningHours] Registered event listener")
