-- OpenPastures Milk - Main entry point (loader only)
--
-- Loads the DynamicHusbandryStorage specialization and injects it into placeable
-- types that support both animals and storage (husbandry pens). The specialization
-- itself scopes its behaviour to this mod's own placeables only (see customEnvironment
-- check in DynamicHusbandryStorage.lua) since the injection below runs against the
-- shared base-game type ("cowHusbandryPastureStraw") that other mods' pens may also use.

-- Embedded in FS25_Buscot_Park's own mod directory, under this fixed subfolder -
-- g_currentModDirectory here points at Buscot Park's root, not this subfolder.
local sourceDirectory = g_currentModDirectory .. "map/inports/FS25_OpenPastures_Milk/"

source(sourceDirectory .. "scripts/DynamicHusbandryStorage.lua")

--- Inject the specialization into any placeable type that has both
--- PlaceableHusbandryAnimals (for getMaxNumOfAnimals) and PlaceableHusbandry (for storage).
local function validatePlaceableTypes(typeManager)
    if typeManager.typeName ~= "placeable" then
        return
    end

    local specializationName = DynamicHusbandryStorage.SPEC_NAME
    local specializationObject = g_placeableSpecializationManager:getSpecializationObjectByName(specializationName)
    if specializationObject == nil then
        return
    end

    for typeName, typeEntry in pairs(typeManager:getTypes()) do
        if specializationObject.prerequisitesPresent(typeEntry.specializations) then
            typeManager:addSpecialization(typeName, specializationName)
        end
    end
end

local function init()
    g_placeableSpecializationManager:addSpecialization(
        "dynamicHusbandryStorage",
        "DynamicHusbandryStorage",
        sourceDirectory .. "scripts/DynamicHusbandryStorage.lua",
        nil
    )

    TypeManager.validateTypes = Utils.prependedFunction(TypeManager.validateTypes, validatePlaceableTypes)
end

init()
