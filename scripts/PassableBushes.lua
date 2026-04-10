-- PassableBushes.lua
-- Farming Simulator 25 mod: lets all drivable vehicles pass through
-- small trees and bushes instead of being stopped by them.
--
-- How it works:
--   GIANTS Engine uses bitmask-based collision filtering. Every rigid body
--   has a "collision mask" that lists which other layers it reacts to.
--   Trees and bushes live on specific bit layers. This mod strips those
--   bits from the vehicle's collision mask so the physics engine ignores
--   those contacts entirely — the vehicle passes straight through.

local MOD_NAME = g_currentModName

-- ============================================================
-- Specialization definition
-- ============================================================
PassableBushes = {}
PassableBushes.MOD_NAME = MOD_NAME

function PassableBushes.prerequisitesPresent(specializations)
    return true
end

function PassableBushes:onLoad(savegame)
    self.spec_passableBushes = {
        modifiedNodes = {}  -- {node, originalMask} pairs for clean restore
    }
end

function PassableBushes:onPostLoad(savegame)
    PassableBushes.applyCollisionOverride(self)
end

function PassableBushes:onDelete()
    -- Restore original masks so vehicles are correct if the mod is removed
    local spec = self.spec_passableBushes
    if spec == nil then return end
    for _, entry in ipairs(spec.modifiedNodes) do
        if entry.node ~= nil and entityExists(entry.node) then
            setCollisionMask(entry.node, entry.originalMask)
        end
    end
end

-- Build a bitmask covering all vegetation / tree collision layers.
-- Tries CollisionFlag named constants first; falls back to the known
-- bit-20 value (0x100000) used for trees and split shapes in FS25.
function PassableBushes.getVegetationMask()
    local mask = 0

    if CollisionFlag ~= nil then
        local candidates = { "TREE", "FOLIAGE", "BUSH", "STATIC_TREE", "SPLIT_SHAPE" }
        for _, name in ipairs(candidates) do
            if CollisionFlag[name] ~= nil then
                mask = bitOR(mask, CollisionFlag[name])
                print(string.format("PassableBushes: found CollisionFlag.%s = %d", name, CollisionFlag[name]))
            end
        end
    end

    if mask == 0 then
        -- Bit 20 is the standard tree / split-shape collision layer in GIANTS Engine.
        -- If vegetation still stops you after installing the mod, try adjusting this.
        mask = 1048576  -- 2^20
        print("PassableBushes: CollisionFlag constants not found, using fallback mask " .. mask)
    end

    return mask
end

-- Walk the vehicle node tree and strip vegetation bits from every
-- rigid-body node's collision mask.
function PassableBushes.applyCollisionOverride(vehicle)
    local spec = vehicle.spec_passableBushes
    if spec == nil or vehicle.rootNode == nil then return end

    local vegetationMask = PassableBushes.getVegetationMask()
    local inverseMask    = bitNOT(vegetationMask)
    local count          = 0

    local function processNode(node)
        -- pcall guards against nodes that have no rigid body
        local ok, currentMask = pcall(getCollisionMask, node)
        if ok and currentMask ~= nil and currentMask ~= 0 then
            if bitAND(currentMask, vegetationMask) ~= 0 then
                local newMask = bitAND(currentMask, inverseMask)
                setCollisionMask(node, newMask)
                table.insert(spec.modifiedNodes, { node = node, originalMask = currentMask })
                count = count + 1
            end
        end

        local numChildren = getNumOfChildren(node)
        for i = 0, numChildren - 1 do
            processNode(getChildAt(node, i))
        end
    end

    processNode(vehicle.rootNode)

    if count > 0 then
        print(string.format("PassableBushes: patched %d collision node(s) on %s",
            count, getName(vehicle.rootNode)))
    else
        -- No nodes matched the vegetation mask. This can happen if FS25
        -- stores the vegetation layer on a different bit. Check the game log
        -- for the CollisionFlag dump above and adjust getVegetationMask().
        print("PassableBushes: WARNING — no collision nodes matched vegetation mask on "
            .. getName(vehicle.rootNode)
            .. ". Vegetation bits may differ in this FS25 build.")
    end
end

-- ============================================================
-- Mod registration
-- ============================================================
local function registerMod()
    -- Make our specialization known to the game
    g_specializationManager:addSpecialization(
        "passableBushes",
        "PassableBushes",
        Utils.getFilename("scripts/PassableBushes.lua", MOD_NAME),
        nil
    )

    -- Hook into the vehicle-type validation pass (runs after all mods are
    -- loaded) so we can inject our spec into every drivable vehicle type.
    VehicleTypeManager.validateVehicleTypes = Utils.appendedFunction(
        VehicleTypeManager.validateVehicleTypes,
        function(vtManager)
            local specName = MOD_NAME .. ".passableBushes"
            for typeName, vehicleType in pairs(vtManager.vehicleTypes) do
                if vehicleType.specializationsByName["drivable"] ~= nil
                    and vehicleType.specializationsByName["passableBushes"] == nil then
                    vtManager:addSpecialization(typeName, specName)
                end
            end
        end
    )
end

registerMod()
