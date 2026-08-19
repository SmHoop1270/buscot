-- OpenPastures Milk - Main entry point (loader only)
--
-- Loads the DynamicHusbandryStorage specialization and injects it into placeable
-- types that support both animals and storage (husbandry pens). The specialization
-- itself scopes its behaviour to this mod's own placeables only (see customEnvironment
-- check in DynamicHusbandryStorage.lua) since the injection below runs against the
-- shared base-game type ("cowHusbandryPastureStraw") that other mods' pens may also use.

local modName = g_currentModName
-- Embedded in FS25_Buscot_Park's own mod directory, under this fixed subfolder -
-- g_currentModDirectory here points at Buscot Park's root, not this subfolder.
local sourceDirectory = g_currentModDirectory .. "map/inports/FS25_OpenPastures_Milk/"

Logging.info("[OpenPastures Milk DIAG] main.lua executing, modName=%s modDirectory=%s sourceDirectory=%s",
    tostring(modName), tostring(g_currentModDirectory), tostring(sourceDirectory))

source(sourceDirectory .. "scripts/DynamicHusbandryStorage.lua")

Logging.info("[OpenPastures Milk DIAG] source() completed, DynamicHusbandryStorage global is %s",
    tostring(DynamicHusbandryStorage))

--- Inject the specialization into any placeable type that has both
--- PlaceableHusbandryAnimals (for getMaxNumOfAnimals) and PlaceableHusbandry (for storage).
local function validatePlaceableTypes(typeManager)
    Logging.info("[OpenPastures Milk DIAG] validatePlaceableTypes called for typeManager.typeName=%s",
        tostring(typeManager.typeName))

    if typeManager.typeName ~= "placeable" then
        return
    end

    local specializationName = DynamicHusbandryStorage.SPEC_NAME
    local specializationObject = g_placeableSpecializationManager:getSpecializationObjectByName(specializationName)
    Logging.info("[OpenPastures Milk DIAG] specializationName=%s specializationObject=%s",
        tostring(specializationName), tostring(specializationObject))
    if specializationObject == nil then
        return
    end

    local addedTo = {}
    for typeName, typeEntry in pairs(typeManager:getTypes()) do
        if specializationObject.prerequisitesPresent(typeEntry.specializations) then
            typeManager:addSpecialization(typeName, specializationName)
            table.insert(addedTo, typeName)
        end
    end
    Logging.info("[OpenPastures Milk DIAG] specialization added to types: %s", table.concat(addedTo, ", "))
end

local function init()
    Logging.info("[OpenPastures Milk DIAG] init() running, g_placeableSpecializationManager=%s TypeManager=%s",
        tostring(g_placeableSpecializationManager), tostring(TypeManager))

    local specId = g_placeableSpecializationManager:addSpecialization(
        "dynamicHusbandryStorage",
        "DynamicHusbandryStorage",
        sourceDirectory .. "scripts/DynamicHusbandryStorage.lua",
        nil
    )
    Logging.info("[OpenPastures Milk DIAG] addSpecialization returned %s", tostring(specId))

    TypeManager.validateTypes = Utils.prependedFunction(TypeManager.validateTypes, validatePlaceableTypes)
    Logging.info("[OpenPastures Milk DIAG] validateTypes hook installed")
end

init()
