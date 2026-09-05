-- DynamicHusbandryStorage - scales a husbandry pen's animal capacity AND its
-- food/water/straw/output storage capacity to match the actual fenced pasture area.
--
-- IMPORTANT: this does NOT use self:getMaxNumOfAnimals(). That call returns
-- spec.maxNumAnimals or spec.baseMaxNumAnimals - and spec.maxNumAnimals is never assigned
-- anywhere in the base game's Lua (confirmed by reading PlaceableHusbandryAnimals.lua in
-- full), so it can only be set by native/compiled engine code after
-- clusterHusbandry:create(), using an internal formula we cannot inspect, audit, or predict
-- (real-world testing showed sqmPerAnimal=2500 and sqmPerAnimal=5000 on the same pasture
-- produced nearly identical animal counts - proof the naive "area / sqmPerAnimal" model
-- does not describe what that native code actually does).
--
-- Instead we compute the animal count ourselves from getNavMeshSurfaceArea(), a genuine
-- native MEASUREMENT function (not a capacity decision) confirmed called by the base game
-- itself in PlaceableHusbandryAnimals:createHusbandry(), immediately before it raises
-- onHusbandryAnimalsCreated - so by the time this handler runs, the nav mesh is guaranteed
-- freshly (re)computed for the pasture's current fence outline. We divide that raw area by
-- our own sqmPerAnimal (read straight from the XML, no native transformation involved) to
-- get our own animal count, then write it back into spec_husbandryAnimals.maxNumAnimals so
-- the engine's own reproduction/buy-slot logic uses OUR number too.
--
-- Only touches placeables belonging to THIS mod (checked via customEnvironment), even
-- though the specialization is injected into the shared base-game placeable type.
--
-- This specialization is shared across every pasture type this mod ships (cow, sheep, ...).
-- Each pasture type gets its own cap and per-fillType capacities via PASTURE_CONFIGS below,
-- looked up by a distinguishing substring of the placeable's own configFileName - a value
-- the engine guarantees is stable and never touched by the native maxNumAnimals formula this
-- file's header warns about, unlike self:getMaxNumOfAnimals().
--
-- Safety property: every per-animal rate below is (static XML capacity at maxAnimals) /
-- maxAnimals, using that SAME config's maxAnimals for both halves of the ratio. Since our
-- computed count is clamped to that same hard cap, the computed capacity can never exceed
-- the capacity the engine already sized its storage/serialization for at onLoad - so this
-- never needs to touch FILLLEVEL_NUM_BITS or any other width/serialization sizing at
-- runtime. If a config's maxAnimals ever changes, the static <capacity>/<food capacity>
-- values in that pasture type's own XML must be >= maxAnimals * (per-animal rate).

DynamicHusbandryStorage = {}

DynamicHusbandryStorage.MOD_NAME = g_currentModName
DynamicHusbandryStorage.SPEC_NAME = string.format("%s.dynamicHusbandryStorage", g_currentModName)
DynamicHusbandryStorage.SPEC_TABLE_NAME = string.format("spec_%s", DynamicHusbandryStorage.SPEC_NAME)

-- Never scale storage below this many animals' worth, even on a freshly placed,
-- un-extended pasture, so a tiny pen never ends up with near-zero storage.
DynamicHusbandryStorage.MIN_ANIMALS_FOR_SCALING = 1

--- Per-pasture-type configuration. `match` is checked against the placeable's own
--- configFileName (the XML it was loaded from) as a plain substring - first match wins,
--- so keep these mutually exclusive folder names. Add a new entry here for each new
--- pasture type this mod ships; nothing else in this file needs to change.
DynamicHusbandryStorage.PASTURE_CONFIGS = {
    {
        match = "FS25_OpenPastures_Milk",
        label = "cow pasture",
        maxAnimals = 500,
        staticCapacityAtMax = {
            MILK = 700000,
            BUFFALOMILK = 700000,
            STRAW = 2700000,
        },
        foodStaticCapacityAtMax = 1125000,
    },
    {
        match = "FS25_OpenPastures_Sheep",
        label = "sheep pasture",
        maxAnimals = 1000,
        staticCapacityAtMax = {},
        foodStaticCapacityAtMax = 1125000,
    },
}

--- Resolve which PASTURE_CONFIGS entry applies to a given placeable instance.
function DynamicHusbandryStorage.getConfig(placeable)
    local configFileName = placeable.configFileName
    if configFileName == nil then
        return nil
    end

    for _, config in ipairs(DynamicHusbandryStorage.PASTURE_CONFIGS) do
        if configFileName:find(config.match, 1, true) ~= nil then
            return config
        end
    end

    return nil
end

function DynamicHusbandryStorage.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(PlaceableHusbandryAnimals, specializations)
        and SpecializationUtil.hasSpecialization(PlaceableHusbandry, specializations)
end

function DynamicHusbandryStorage.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onHusbandryAnimalsCreated", DynamicHusbandryStorage)
end

--- Fires whenever the game (re)creates the husbandry animal system: on initial placement,
--- after the player finishes customizing the fence, and again on savegame load. Fires on
--- every peer with identical, deterministic inputs (nav mesh / fence area is shared game
--- state), so no network sync is needed for the capacity number itself.
---
--- rawMaxAnimals is OUR OWN calculation: getNavMeshSurfaceArea(animalsSpec.navigationMesh)
--- (real m^2, freshly computed by the engine for the current fence outline just before this
--- event fires) divided by animalsSpec.sqmPerAnimal (the plain XML value, no native
--- transformation). We do not read or rely on self:getMaxNumOfAnimals() anywhere - see the
--- file header for why. We clamp the result ourselves and write it directly back into
--- spec_husbandryAnimals.maxNumAnimals, which is the same technique the "Limit Husbandry
--- Animals" style mods use to make the engine's own reproduction/buy-slot logic respect a
--- number it didn't compute itself.
function DynamicHusbandryStorage:onHusbandryAnimalsCreated(husbandryId)
    Logging.info("[OpenPastures DIAG] onHusbandryAnimalsCreated fired: name=%s customEnvironment=%s MOD_NAME=%s configFileName=%s",
        tostring(self.getName ~= nil and self:getName() or nil), tostring(self.customEnvironment),
        tostring(DynamicHusbandryStorage.MOD_NAME), tostring(self.configFileName))

    if self.customEnvironment ~= DynamicHusbandryStorage.MOD_NAME then
        Logging.info("[OpenPastures DIAG] bailing: customEnvironment mismatch")
        return
    end

    local config = DynamicHusbandryStorage.getConfig(self)
    if config == nil then
        Logging.info("[OpenPastures DIAG] bailing: getConfig returned nil for configFileName=%s", tostring(self.configFileName))
        return
    end

    local husbandrySpec = self.spec_husbandry
    local animalsSpec = self.spec_husbandryAnimals
    -- husbandrySpec.storage only exists for pasture types with bulk output (e.g. cow's milk
    -- tank) - pasture types that only produce pallet-based output (e.g. sheep wool) never
    -- create one, and that's expected, not an error. Only bail if the specs we actually need
    -- (husbandry + animals) are missing; applyOutputCapacities below already no-ops safely
    -- when storage is nil.
    if husbandrySpec == nil or animalsSpec == nil then
        return
    end

    if animalsSpec.navigationMesh == nil or getNavMeshSurfaceArea == nil then
        Logging.info("[OpenPastures DIAG] bailing: navigationMesh=%s getNavMeshSurfaceArea=%s",
            tostring(animalsSpec.navigationMesh), tostring(getNavMeshSurfaceArea))
        return
    end

    local navMeshArea = getNavMeshSurfaceArea(animalsSpec.navigationMesh)
    local sqmPerAnimal = animalsSpec.sqmPerAnimal
    if navMeshArea == nil or navMeshArea <= 0 or sqmPerAnimal == nil or sqmPerAnimal <= 0 then
        Logging.info("[OpenPastures DIAG] bailing: navMeshArea=%s sqmPerAnimal=%s",
            tostring(navMeshArea), tostring(sqmPerAnimal))
        return
    end

    local rawMaxAnimals = math.floor(navMeshArea / sqmPerAnimal)

    local maxAnimals = math.min(math.max(rawMaxAnimals, DynamicHusbandryStorage.MIN_ANIMALS_FOR_SCALING),
        config.maxAnimals)

    Logging.info("[OpenPastures] %s: nav mesh area %.0f m^2 / %d m^2 per animal = %d animals (capped at %d) -> %d",
        self:getName() or config.label, navMeshArea, sqmPerAnimal, rawMaxAnimals, config.maxAnimals, maxAnimals)

    if rawMaxAnimals > config.maxAnimals then
        Logging.warning("[OpenPastures] %s: pasture area supports %d animals, but this pasture type has a %d animal maximum - clamping to %d",
            self:getName() or config.label, rawMaxAnimals, config.maxAnimals, config.maxAnimals)

        -- onHusbandryAnimalsCreated also fires on every savegame load, not just when the fence
        -- is actively resized - only pop the on-screen warning when the oversized value is new
        -- or changed, so reloading an already-oversized save doesn't nag on every load.
        -- isClient-gated: a headless dedicated server has no HUD to show this on.
        if self.isClient and g_currentMission ~= nil then
            local spec = self[DynamicHusbandryStorage.SPEC_TABLE_NAME]
            if spec == nil then
                spec = {}
                self[DynamicHusbandryStorage.SPEC_TABLE_NAME] = spec
            end

            if spec.lastWarnedRawMaxAnimals ~= rawMaxAnimals then
                g_currentMission:showBlinkingWarning(
                    string.format("%s: area supports %d animals, but this pasture type is limited to a %d animal maximum",
                        self:getName() or config.label, rawMaxAnimals, config.maxAnimals),
                    5000)
                spec.lastWarnedRawMaxAnimals = rawMaxAnimals
            end
        end
    end

    -- Overwrite the engine's own (unrelated, uninitialized) value so reproduction/buy logic
    -- respects our calculation too.
    animalsSpec.maxNumAnimals = maxAnimals

    DynamicHusbandryStorage.applyOutputCapacities(self, husbandrySpec.storage, maxAnimals, config)
    DynamicHusbandryStorage.applyFoodCapacity(self, maxAnimals, config)
end

--- Scale this pasture type's output fillType capacities on the husbandry output Storage
--- object. Fill types with no entry in config.staticCapacityAtMax (e.g. MANURE, capacity 0,
--- unused) are left untouched.
--- Plain module function (not a placeable method) - placeable is passed explicitly since this
--- specialization never registers these as callable methods on the placeable itself.
function DynamicHusbandryStorage.applyOutputCapacities(placeable, storage, maxAnimals, config)
    if storage == nil or storage.capacities == nil then
        return
    end

    for fillTypeIndex, _ in pairs(storage.capacities) do
        local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        local staticCapacity = fillType ~= nil and config.staticCapacityAtMax[fillType.name] or nil
        if staticCapacity ~= nil then
            local perAnimal = staticCapacity / config.maxAnimals
            local newCapacity = math.floor(perAnimal * maxAnimals)

            storage.capacities[fillTypeIndex] = newCapacity

            if placeable.isServer then
                local currentFill = storage.fillLevels ~= nil and storage.fillLevels[fillTypeIndex] or 0
                if currentFill > newCapacity then
                    storage:setFillLevel(newCapacity, fillTypeIndex)
                end
            end
        end
    end
end

--- Scale the husbandryFood capacity (dynamicFoodPlane-backed) to match maxAnimals.
--- Plain module function (not a placeable method) - see applyOutputCapacities above.
function DynamicHusbandryStorage.applyFoodCapacity(placeable, maxAnimals, config)
    local foodSpec = placeable.spec_husbandryFood
    if foodSpec == nil then
        return
    end

    local perAnimal = config.foodStaticCapacityAtMax / config.maxAnimals
    local newCapacity = math.floor(perAnimal * maxAnimals)
    if newCapacity == foodSpec.capacity then
        return
    end

    foodSpec.capacity = newCapacity

    if placeable.isServer and foodSpec.fillLevels ~= nil and placeable.removeFood ~= nil then
        local totalFood = placeable.getTotalFood ~= nil and placeable:getTotalFood() or 0
        if totalFood > newCapacity and totalFood > 0 then
            local ratio = newCapacity / totalFood
            for fillTypeIndex, level in pairs(foodSpec.fillLevels) do
                if level > 0 then
                    local excess = level - math.floor(level * ratio)
                    if excess > 0 then
                        placeable:removeFood(excess, fillTypeIndex)
                    end
                end
            end
        end
    end
end
