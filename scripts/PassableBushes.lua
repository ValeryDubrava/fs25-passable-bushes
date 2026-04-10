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

PassableBushes = {}

-- Per-vehicle storage: rootNode id -> list of {node, originalMask}
-- Kept outside vehicles so we don't pollute vehicle objects.
local vehicleData = {}

-- ============================================================
-- Collision mask helpers
-- ============================================================

-- Build a bitmask covering all vegetation / tree collision layers.
-- Tries CollisionFlag named constants first; falls back to the known
-- bit-20 value (0x100000) used for trees and split shapes in FS25.
local function getVegetationMask()
    local mask = 0

    if CollisionFlag ~= nil then
        local candidates = { "TREE", "FOLIAGE", "BUSH", "STATIC_TREE", "SPLIT_SHAPE" }
        for _, name in ipairs(candidates) do
            if CollisionFlag[name] ~= nil then
                mask = bitOR(mask, CollisionFlag[name])
                print(string.format("PassableBushes: using CollisionFlag.%s = %d", name, CollisionFlag[name]))
            end
        end
    end

    if mask == 0 then
        -- Bit 20 is the standard tree / split-shape collision layer in GIANTS Engine.
        -- If vegetation still stops you after installing the mod, check log.txt for
        -- CollisionFlag values and adjust this number accordingly.
        mask = 1048576  -- 2^20
        print("PassableBushes: CollisionFlag constants not found, using fallback mask " .. mask)
    end

    return mask
end

local VEGETATION_MASK = getVegetationMask()
local INVERSE_MASK    = bitNOT(VEGETATION_MASK)

-- ============================================================
-- Per-vehicle apply / restore
-- ============================================================

local function applyToVehicle(vehicle)
    if vehicle == nil or vehicle.rootNode == nil then return end
    -- Only drivable vehicles (tractors, combines, trucks …)
    if vehicle.spec_drivable == nil then return end
    -- Skip if already patched
    if vehicleData[vehicle.rootNode] ~= nil then return end

    local modified = {}

    local function processNode(node)
        local ok, currentMask = pcall(getCollisionMask, node)
        if ok and currentMask ~= nil and currentMask ~= 0 then
            if bitAND(currentMask, VEGETATION_MASK) ~= 0 then
                setCollisionMask(node, bitAND(currentMask, INVERSE_MASK))
                table.insert(modified, { node = node, originalMask = currentMask })
            end
        end
        for i = 0, getNumOfChildren(node) - 1 do
            processNode(getChildAt(node, i))
        end
    end

    processNode(vehicle.rootNode)
    vehicleData[vehicle.rootNode] = modified

    if #modified > 0 then
        print(string.format("PassableBushes: patched %d node(s) on '%s'",
            #modified, getName(vehicle.rootNode)))
    else
        print("PassableBushes: WARNING — no nodes matched vegetation mask on '"
            .. getName(vehicle.rootNode)
            .. "'. The vegetation collision bit may differ in this FS25 build.")
    end
end

local function removeFromVehicle(vehicle)
    if vehicle == nil or vehicle.rootNode == nil then return end
    local modified = vehicleData[vehicle.rootNode]
    if modified == nil then return end
    for _, entry in ipairs(modified) do
        if entry.node ~= nil and entityExists(entry.node) then
            setCollisionMask(entry.node, entry.originalMask)
        end
    end
    vehicleData[vehicle.rootNode] = nil
end

-- ============================================================
-- Hook into the Vehicle base class
-- Runs after all specialisations have finished postLoad so that
-- spec_drivable is guaranteed to be present when we check it.
-- ============================================================

if Vehicle ~= nil then
    -- Apply after vehicle is fully initialised
    local origPostLoad = Vehicle.postLoad
    Vehicle.postLoad = function(self, ...)
        local result = origPostLoad(self, ...)
        applyToVehicle(self)
        return result
    end

    -- Restore before vehicle is destroyed
    local origDelete = Vehicle.delete
    Vehicle.delete = function(self, ...)
        removeFromVehicle(self)
        return origDelete(self, ...)
    end
else
    print("PassableBushes: ERROR — Vehicle class not found. Mod will not work.")
end
