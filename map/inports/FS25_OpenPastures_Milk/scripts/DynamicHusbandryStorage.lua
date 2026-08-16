-- DynamicHusbandryStorage - scales a husbandry pen's animal capacity AND its
-- food/water/straw/milk storage capacity to match the actual fenced pasture area.
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
-- Safety property: every per-animal rate below is (static XML capacity at MAX_ANIMALS) /
-- MAX_ANIMALS. Since our computed count is clamped to that same hard cap (both are 500),
-- the computed capacity can never exceed the capacity the engine already sized its
-- storage/serialization for at onLoad - so this never needs to touch FILLLEVEL_NUM_BITS or
-- any other width/serialization sizing at runtime. If MAX_ANIMALS or maxNumAnimals in the
-- XML ever changes, both must be updated together and the static <capacity>/<food capacity>
-- values in cowSmallAutoWater.xml must be >= MAX_ANIMALS * (per-animal rate).

DynamicHusbandryStorage = {}

DynamicHusbandryStorage.MOD_NAME = g_currentModName
DynamicHusbandryStorage.SPEC_NAME = string.format("%s.dynamicHusbandryStorage", g_currentModName)
DynamicHusbandryStorage.SPEC_TABLE_NAME = string.format("spec_%s", DynamicHusbandryStorage.SPEC_NAME)

-- This mod's hard cap (matches maxNumAnimals="500" in cowSmallAutoWater.xml)
DynamicHusbandryStorage.MAX_ANIMALS = 500

-- Never scale storage below this many animals' worth, even on a freshly placed,
-- un-extended pasture, so a tiny pen never ends up with near-zero storage.
DynamicHusbandryStorage.MIN_ANIMALS_FOR_SCALING = 1

--- Per-animal storage capacity, derived from this mod's own static capacities at
--- MAX_ANIMALS, keyed by FillType name (matched via g_fillTypeManager, not raw index,
--- since FillType indices are engine-assigned and not stable enum values).
DynamicHusbandryStorage.STATIC_CAPACITY_AT_MAX = {
    MILK = 700000,
    BUFFALOMILK = 700000,
    STRAW = 2700000,
}
DynamicHusbandryStorage.FOOD_STATIC_CAPACITY_AT_MAX = 1125000

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
    if self.customEnvironment ~= DynamicHusbandryStorage.MOD_NAME then
        return
    end

    local husbandrySpec = self.spec_husbandry
    local animalsSpec = self.spec_husbandryAnimals
    if husbandrySpec == nil or husbandrySpec.storage == nil or animalsSpec == nil then
        return
    end

    if animalsSpec.navigationMesh == nil or getNavMeshSurfaceArea == nil then
        return
    end

    local navMeshArea = getNavMeshSurfaceArea(animalsSpec.navigationMesh)
    local sqmPerAnimal = animalsSpec.sqmPerAnimal
    if navMeshArea == nil or navMeshArea <= 0 or sqmPerAnimal == nil or sqmPerAnimal <= 0 then
        return
    end

    local rawMaxAnimals = math.floor(navMeshArea / sqmPerAnimal)

    local maxAnimals = math.min(math.max(rawMaxAnimals, DynamicHusbandryStorage.MIN_ANIMALS_FOR_SCALING),
        DynamicHusbandryStorage.MAX_ANIMALS)

    Logging.info("[OpenPastures Milk] %s: nav mesh area %.0f m^2 / %d m^2 per animal = %d animals (capped at %d) -> %d",
        self:getName() or "cow pasture", navMeshArea, sqmPerAnimal, rawMaxAnimals, DynamicHusbandryStorage.MAX_ANIMALS, maxAnimals)

    if rawMaxAnimals > DynamicHusbandryStorage.MAX_ANIMALS then
        Logging.warning("[OpenPastures Milk] %s: pasture area supports %d animals, but this pasture type has a %d animal maximum - clamping to %d",
            self:getName() or "cow pasture", rawMaxAnimals, DynamicHusbandryStorage.MAX_ANIMALS, DynamicHusbandryStorage.MAX_ANIMALS)

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
                        self:getName() or "Cow pasture", rawMaxAnimals, DynamicHusbandryStorage.MAX_ANIMALS),
                    5000)
                spec.lastWarnedRawMaxAnimals = rawMaxAnimals
            end
        end
    end

    -- Overwrite the engine's own (unrelated, uninitialized) value so reproduction/buy logic
    -- respects our calculation too.
    animalsSpec.maxNumAnimals = maxAnimals

    DynamicHusbandryStorage.applyOutputCapacities(self, husbandrySpec.storage, maxAnimals)
    DynamicHusbandryStorage.applyFoodCapacity(self, maxAnimals)
end

--- Scale MILK/BUFFALOMILK/STRAW capacities on the husbandry output Storage object.
--- MANURE (capacity 0, unused) is left untouched since it has no entry in STATIC_CAPACITY_AT_MAX.
--- Plain module function (not a placeable method) - placeable is passed explicitly since this
--- specialization never registers these as callable methods on the placeable itself.
function DynamicHusbandryStorage.applyOutputCapacities(placeable, storage, maxAnimals)
    if storage.capacities == nil then
        return
    end

    for fillTypeIndex, _ in pairs(storage.capacities) do
        local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        local staticCapacity = fillType ~= nil and DynamicHusbandryStorage.STATIC_CAPACITY_AT_MAX[fillType.name] or nil
        if staticCapacity ~= nil then
            local perAnimal = staticCapacity / DynamicHusbandryStorage.MAX_ANIMALS
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
function DynamicHusbandryStorage.applyFoodCapacity(placeable, maxAnimals)
    local foodSpec = placeable.spec_husbandryFood
    if foodSpec == nil then
        return
    end

    local perAnimal = DynamicHusbandryStorage.FOOD_STATIC_CAPACITY_AT_MAX / DynamicHusbandryStorage.MAX_ANIMALS
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
