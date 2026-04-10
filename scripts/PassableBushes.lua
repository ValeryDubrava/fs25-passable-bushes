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

-- Set to true to log nearby object collision masks whenever the vehicle
-- gets stuck. Check log.txt, find the seedling/bush entry, note its mask
-- value, then add the missing bit to EXTRA_VEGETATION_MASKS below and
-- set this back to false.
local DIAGNOSTIC_MODE = true

-- Additional collision mask bits to strip beyond CollisionFlag.TREE.
-- Fill these in based on DIAGNOSTIC_MODE output, e.g. { 64, 512 }.
local EXTRA_VEGETATION_MASKS = {}

PassableBushes = {}

-- Per-vehicle storage: rootNode id -> list of {node, originalMask}
local vehicleData = {}

-- ============================================================
-- Collision mask helpers
-- ============================================================

local function dumpCollisionFlags()
    if CollisionFlag == nil then
        print("PassableBushes: CollisionFlag table not available")
        return
    end
    print("PassableBushes: all CollisionFlag values:")
    for name, value in pairs(CollisionFlag) do
        if type(value) == "number" then
            print(string.format("  %-30s = %10d  (0x%08X)", name, value, value))
        end
    end
end

local function getVegetationMask()
    local mask = 0

    if CollisionFlag ~= nil then
        local candidates = { "TREE", "FOLIAGE", "BUSH", "STATIC_TREE", "SPLIT_SHAPE",
                              "PLANT", "DYNAMIC_OBJECT", "VEGETATION" }
        for _, name in ipairs(candidates) do
            if CollisionFlag[name] ~= nil then
                mask = bitOR(mask, CollisionFlag[name])
                print(string.format("PassableBushes: using CollisionFlag.%s = %d (0x%X)",
                    name, CollisionFlag[name], CollisionFlag[name]))
            end
        end
    end

    for _, extra in ipairs(EXTRA_VEGETATION_MASKS) do
        mask = bitOR(mask, extra)
        print(string.format("PassableBushes: using extra mask bit %d (0x%X)", extra, extra))
    end

    if mask == 0 then
        mask = 1048576  -- 2^20, fallback
        print("PassableBushes: no CollisionFlag constants matched, using fallback mask " .. mask)
    end

    return mask
end

local VEGETATION_MASK = getVegetationMask()
local INVERSE_MASK    = bitNOT(VEGETATION_MASK)

-- ============================================================
-- Diagnostic: overlap sphere scan when vehicle appears stuck
-- ============================================================

local diagCooldown = {}  -- rootNode -> last scan timestamp

local function runDiagnostic(vehicle)
    local now  = getTime and getTime() or 0
    local key  = vehicle.rootNode
    if diagCooldown[key] and now - diagCooldown[key] < 3000 then return end
    diagCooldown[key] = now

    local x, y, z = getWorldTranslation(vehicle.rootNode)
    print(string.format("PassableBushes DIAG: scanning 3m sphere around '%s'",
        getName(vehicle.rootNode)))

    local seen = {}
    local function onOverlap(hitId)
        if hitId == vehicle.rootNode or seen[hitId] then return true end
        seen[hitId] = true

        local name = getName(hitId) or "?"
        local ok, mask = pcall(getCollisionMask, hitId)
        if ok and mask ~= nil and mask ~= 0 then
            print(string.format("PassableBushes DIAG:   '%s'  mask=%d  (0x%08X)",
                name, mask, mask))
        end
        return true
    end

    overlapSphere(x, y + 0.5, z, 3.0, onOverlap, 0xFFFFFFFF)
end

-- ============================================================
-- Per-vehicle apply / restore
-- ============================================================

local function applyToVehicle(vehicle)
    if vehicle == nil or vehicle.rootNode == nil then return end
    if vehicle.spec_drivable == nil then return end
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
            .. getName(vehicle.rootNode) .. "'.")
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
    diagCooldown[vehicle.rootNode] = nil
end

-- ============================================================
-- Hook into the Vehicle base class
-- ============================================================

if Vehicle ~= nil then
    local origPostLoad = Vehicle.postLoad
    Vehicle.postLoad = function(self, ...)
        local result = origPostLoad(self, ...)
        applyToVehicle(self)
        return result
    end

    local origUpdateTick = Vehicle.updateTick
    Vehicle.updateTick = function(self, dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
        local result = origUpdateTick(self, dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
        if DIAGNOSTIC_MODE
            and isActiveForInput
            and self.spec_drivable ~= nil
            and (self.lastSpeed == nil or math.abs(self.lastSpeed) < 0.001) then
            runDiagnostic(self)
        end
        return result
    end

    local origDelete = Vehicle.delete
    Vehicle.delete = function(self, ...)
        removeFromVehicle(self)
        return origDelete(self, ...)
    end
else
    print("PassableBushes: ERROR — Vehicle class not found. Mod will not work.")
end

-- Dump all known collision flags once on load so we have the full picture
dumpCollisionFlags()
