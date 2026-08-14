--[[
    BuscotAnimalMarket.lua

    Adds a randomised premium (default +10% .. +30%) to a GtX ExtendedProductionPoint
    that sells animals. Rather than hooking a sell-price function (the production
    point sells outputs via 'sellDirectly', which does not go through a
    SellingStation), this scales each production's OUTPUT AMOUNT by the premium.
    More product per animal => more money, regardless of how the sale is routed.

    Re-rolled per production once per in-game day, saved to the savegame, and
    synced in multiplayer (server rolls, clients receive).

    Companion to GtX's PlaceableExtendedProductionPoint.lua (must load first).
    Author: DrXmL (premium layer)
]]

BuscotAnimalMarket = {}

BuscotAnimalMarket.DEFAULT_MIN_PREMIUM = 0.10
BuscotAnimalMarket.DEFAULT_MAX_PREMIUM = 0.30

function BuscotAnimalMarket.prerequisitesPresent(specializations)
    return true
end

function BuscotAnimalMarket.registerXMLPaths(schema, basePath)
    schema:register(XMLValueType.FLOAT, basePath .. ".buscotAnimalMarket#minPremium",
        "Minimum premium fraction (0.10 = +10%)", BuscotAnimalMarket.DEFAULT_MIN_PREMIUM)
    schema:register(XMLValueType.FLOAT, basePath .. ".buscotAnimalMarket#maxPremium",
        "Maximum premium fraction (0.30 = +30%)", BuscotAnimalMarket.DEFAULT_MAX_PREMIUM)
end

function BuscotAnimalMarket.registerSavegameXMLPaths(schema, basePath)
    schema:register(XMLValueType.FLOAT, basePath .. ".premium(?)#factor", "Saved premium factor")
end

function BuscotAnimalMarket.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad",              BuscotAnimalMarket)
    SpecializationUtil.registerEventListener(placeableType, "onFinalizePlacement", BuscotAnimalMarket)
    SpecializationUtil.registerEventListener(placeableType, "onDelete",            BuscotAnimalMarket)
    SpecializationUtil.registerEventListener(placeableType, "onReadStream",        BuscotAnimalMarket)
    SpecializationUtil.registerEventListener(placeableType, "onWriteStream",       BuscotAnimalMarket)
    SpecializationUtil.registerEventListener(placeableType, "onReadUpdateStream",  BuscotAnimalMarket)
    SpecializationUtil.registerEventListener(placeableType, "onWriteUpdateStream", BuscotAnimalMarket)
end

local function getProductionPoint(self)
    local epp = self.spec_extendedProductionPoint
    if epp ~= nil then
        return epp.productionPoint
    end
    return nil
end

function BuscotAnimalMarket:onLoad(savegame)
    local spec = self.spec_buscotAnimalMarket
    if spec == nil then
        spec = {}
        self.spec_buscotAnimalMarket = spec
    end

    local minPremium = self.xmlFile:getValue("placeable.buscotAnimalMarket#minPremium", BuscotAnimalMarket.DEFAULT_MIN_PREMIUM)
    local maxPremium = self.xmlFile:getValue("placeable.buscotAnimalMarket#maxPremium", BuscotAnimalMarket.DEFAULT_MAX_PREMIUM)
    if maxPremium < minPremium then
        minPremium, maxPremium = maxPremium, minPremium
    end
    spec.minPremium = minPremium
    spec.maxPremium = maxPremium

    spec.factors = {}
    spec.baseAmounts = {}
    spec.numProductions = 0
    spec.applied = false

    if savegame ~= nil then
        local baseKey = savegame.key .. ".buscotAnimalMarket"
        local i = 0
        while true do
            local key = string.format("%s.premium(%d)", baseKey, i)
            if not savegame.xmlFile:hasProperty(key) then
                break
            end
            spec.factors[i + 1] = savegame.xmlFile:getValue(key .. "#factor")
            i = i + 1
        end
    end

    spec.dirtyFlag = self:getNextDirtyFlag()
end

function BuscotAnimalMarket:onFinalizePlacement()
    local spec = self.spec_buscotAnimalMarket
    local pp = getProductionPoint(self)
    if pp == nil or pp.productions == nil then
        return
    end

    spec.numProductions = #pp.productions

    for i, production in ipairs(pp.productions) do
        spec.baseAmounts[i] = {}
        if production.outputs ~= nil then
            for j, output in ipairs(production.outputs) do
                spec.baseAmounts[i][j] = output.amount
            end
        end
    end

    if self.isServer then
        local haveFactors = false
        for i = 1, spec.numProductions do
            if spec.factors[i] ~= nil then
                haveFactors = true
                break
            end
        end
        if not haveFactors then
            BuscotAnimalMarket.rollPremiums(self)
        end

        g_messageCenter:subscribe(MessageType.DAY_CHANGED, BuscotAnimalMarket.onDayChanged, self)
    end

    BuscotAnimalMarket.applyFactors(self)
end

function BuscotAnimalMarket:onDelete()
    g_messageCenter:unsubscribeAll(self)
end

function BuscotAnimalMarket.rollPremiums(self)
    local spec = self.spec_buscotAnimalMarket
    local span = spec.maxPremium - spec.minPremium
    for i = 1, math.max(spec.numProductions, 1) do
        spec.factors[i] = 1.0 + spec.minPremium + math.random() * span
    end
end

function BuscotAnimalMarket.applyFactors(self)
    local spec = self.spec_buscotAnimalMarket
    local pp = getProductionPoint(self)
    if pp == nil or pp.productions == nil then
        return
    end

    for i, production in ipairs(pp.productions) do
        local factor = spec.factors[i] or 1.0
        local baseList = spec.baseAmounts[i]
        if baseList ~= nil and production.outputs ~= nil then
            for j, output in ipairs(production.outputs) do
                if baseList[j] ~= nil then
                    output.amount = baseList[j] * factor
                end
            end
        end
    end
    spec.applied = true
end

function BuscotAnimalMarket:onDayChanged()
    if self.isServer then
        BuscotAnimalMarket.rollPremiums(self)
        BuscotAnimalMarket.applyFactors(self)
        self:raiseDirtyFlags(self.spec_buscotAnimalMarket.dirtyFlag)
    end
end

function BuscotAnimalMarket:saveToXMLFile(xmlFile, key, usedModNames)
    local spec = self.spec_buscotAnimalMarket
    for i = 1, spec.numProductions do
        if spec.factors[i] ~= nil then
            xmlFile:setValue(string.format("%s.premium(%d)#factor", key, i - 1), spec.factors[i])
        end
    end
end

function BuscotAnimalMarket:onWriteStream(streamId, connection)
    local spec = self.spec_buscotAnimalMarket
    local n = #spec.factors
    streamWriteUInt8(streamId, n)
    for i = 1, n do
        streamWriteFloat32(streamId, spec.factors[i] or 1.0)
    end
end

function BuscotAnimalMarket:onReadStream(streamId, connection)
    local spec = self.spec_buscotAnimalMarket
    local n = streamReadUInt8(streamId)
    spec.factors = {}
    for i = 1, n do
        spec.factors[i] = streamReadFloat32(streamId)
    end
end

function BuscotAnimalMarket:onWriteUpdateStream(streamId, connection, dirtyMask)
    if not connection:getIsServer() then
        local spec = self.spec_buscotAnimalMarket
        if streamWriteBool(streamId, bitAND(dirtyMask, spec.dirtyFlag) ~= 0) then
            local n = #spec.factors
            streamWriteUInt8(streamId, n)
            for i = 1, n do
                streamWriteFloat32(streamId, spec.factors[i] or 1.0)
            end
        end
    end
end

function BuscotAnimalMarket:onReadUpdateStream(streamId, timestamp, connection)
    if connection:getIsServer() then
        if streamReadBool(streamId) then
            local spec = self.spec_buscotAnimalMarket
            local n = streamReadUInt8(streamId)
            spec.factors = {}
            for i = 1, n do
                spec.factors[i] = streamReadFloat32(streamId)
            end
            BuscotAnimalMarket.applyFactors(self)
        end
    end
end
