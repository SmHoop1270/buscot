-- DisableExoticCrops - hides crops that don't fit Buscot Park's UK setting from
-- the shop, price list and growth calendar.
--
-- The base game always loads data/maps/maps_fruitTypes.xml as default fruit types
-- on every map (FruitTypeManager:loadMapData -> loadDefaultTypes), regardless of
-- what this map's own <fruitTypes> list in map.xml contains - so sugarcane, cotton
-- and olive can't be removed by editing map.xml alone, they get re-added right after.
--
-- shownOnMap is the engine's own supported flag for exactly this (FruitTypeDesc.lua),
-- so this only affects map-facing UI - it does not unregister the fruit types or
-- change their indices, so nothing else (saves, foliage, other specializations) is
-- affected.

DisableExoticCrops = {}
DisableExoticCrops.HIDDEN_CROPS = {
    "SUGARCANE",
    "COTTON",
    "OLIVE",
}

function DisableExoticCrops.hideCrops()
    for _, cropName in ipairs(DisableExoticCrops.HIDDEN_CROPS) do
        local fruitType = g_fruitTypeManager:getFruitTypeByName(cropName)
        if fruitType ~= nil then
            fruitType.shownOnMap = false
        end
    end
end

FruitTypeManager.loadMapData = Utils.overwrittenFunction(FruitTypeManager.loadMapData, function(self, superFunc, xmlFileHandle, missionInfo, baseDirectory)
    local retVal = superFunc(self, xmlFileHandle, missionInfo, baseDirectory)
    DisableExoticCrops.hideCrops()
    return retVal
end)
