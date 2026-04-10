-- PassableBushes.lua
-- Farming Simulator 25 mod: lets all drivable vehicles pass through
-- small trees and bushes instead of being stopped by them.
--
-- Strategy:
--   1. Strip CollisionFlag.TREE from the vehicle's own mask at load time
--      (handles full-grown trees that use the TREE group).
--   2. Every ~500 ms scan a sphere around the active vehicle for
--      STATIC_OBJECT hits (seedlings, decorative bushes). For each hit
--      that is small enough (bounding-box check), temporarily strip the
--      VEHICLE collision bit from that world object so the vehicle passes
--      through it. Restore the bit when the vehicle moves away.

local MOD_NAME = g_currentModName

-- Set false once you're happy with the mod behaviour.
local DIAGNOSTIC_MODE = true

-- Size thresholds for "passable vegetation".
-- Objects with a bounding box taller or wider than these are left alone.
local MAX_VEGETATION_HEIGHT = 3.0   -- metres
local MAX_VEGETATION_WIDTH  = 2.0   -- metres
local SCAN_RADIUS           = 5.0   -- metres around the vehicle

PassableBushes = {}

-- ============================================================
-- Module-level state
-- ============================================================

-- rootNode -> list of {node, originalMask}   (for vehicle-node patching)
local vehiclePatches = {}

-- objectId -> {originalMask, lastSeenMs}   (for nearby world-object patching)
local nearbyPatched = {}

-- ============================================================
-- Startup: dump all numeric CollisionFlag entries
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

-- ============================================================
-- Build the vegetation mask stripped from the vehicle's OWN nodes
-- (handles CollisionFlag.TREE and any other explicit vegetation flags)
-- ============================================================
local function buildVegetationMask()
    local mask = 0
    if CollisionFlag ~= nil then
        local candidates = {
            "TREE", "FOLIAGE", "BUSH", "STATIC_TREE", "SPLIT_SHAPE",
            "PLANT", "VEGETATION", "DYNAMIC_OBJECT",
        }
        for _, name in ipairs(candidates) do
            if CollisionFlag[name] ~= nil then
                mask = bitOR(mask, CollisionFlag[name])
                print(string.format("PassableBushes: vehicle-node mask — stripping CollisionFlag.%s = %d (0x%X)",
                    name, CollisionFlag[name], CollisionFlag[name]))
            end
        end
    end
    if mask == 0 then
        mask = 1048576  -- 2^20 fallback
        print("PassableBushes: no named flags found, using fallback mask " .. mask)
    end
    return mask
end

local VEHICLE_NODE_VEG_MASK = buildVegetationMask()
local VEHICLE_NODE_INV_MASK = bitNOT(VEHICLE_NODE_VEG_MASK)

-- ============================================================
-- Part 1 — patch the vehicle's own collision nodes at load time
-- ============================================================
local function applyVehicleNodePatch(vehicle)
    if vehicle == nil or vehicle.rootNode == nil then return end
    if vehicle.spec_drivable == nil then return end
    if vehiclePatches[vehicle.rootNode] ~= nil then return end

    local patches = {}
    local function walk(node)
        local ok, mask = pcall(getCollisionMask, node)
        if ok and mask ~= nil and mask ~= 0 then
            if bitAND(mask, VEHICLE_NODE_VEG_MASK) ~= 0 then
                setCollisionMask(node, bitAND(mask, VEHICLE_NODE_INV_MASK))
                table.insert(patches, { node = node, originalMask = mask })
            end
        end
        for i = 0, getNumOfChildren(node) - 1 do
            walk(getChildAt(node, i))
        end
    end
    walk(vehicle.rootNode)

    vehiclePatches[vehicle.rootNode] = patches
    print(string.format("PassableBushes: vehicle-node patch applied — %d node(s) on '%s'",
        #patches, getName(vehicle.rootNode)))
end

local function removeVehicleNodePatch(vehicle)
    if vehicle == nil or vehicle.rootNode == nil then return end
    local patches = vehiclePatches[vehicle.rootNode]
    if patches == nil then return end
    for _, p in ipairs(patches) do
        if p.node ~= nil and entityExists(p.node) then
            setCollisionMask(p.node, p.originalMask)
        end
    end
    vehiclePatches[vehicle.rootNode] = nil
end

-- ============================================================
-- Part 2 — dynamically patch small world objects near the vehicle
-- ============================================================
local function isBoundingBoxSmall(nodeId)
    -- Try getWorldBoundingBox(nodeId) → minX,minY,minZ,maxX,maxY,maxZ
    local ok, x1, y1, z1, x2, y2, z2 = pcall(getWorldBoundingBox, nodeId)
    if ok and x1 ~= nil then
        local h = math.abs(y2 - y1)
        local w = math.max(math.abs(x2 - x1), math.abs(z2 - z1))
        return h < MAX_VEGETATION_HEIGHT and w < MAX_VEGETATION_WIDTH
    end
    -- If bounding box is unavailable, fall back to a name heuristic
    local name = (getName(nodeId) or ""):lower()
    return name:find("tree") ~= nil
        or name:find("bush") ~= nil
        or name:find("plant") ~= nil
        or name:find("shrub") ~= nil
        or name:find("hedge") ~= nil
        or name:find("sapling") ~= nil
        or name:find("seedling") ~= nil
end

local VEHICLE_FLAG = CollisionFlag ~= nil and CollisionFlag.VEHICLE or 65536
local STATIC_FLAG  = CollisionFlag ~= nil and CollisionFlag.STATIC_OBJECT or 2

local function scanNearbyObjects(vehicle, nowMs)
    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)

    local function onOverlap(hitId, ...)
        if hitId == nil or hitId == vehicle.rootNode then return true end

        if nearbyPatched[hitId] then
            -- Still nearby — update timestamp so we don't restore too early
            nearbyPatched[hitId].lastSeenMs = nowMs
            return true
        end

        local ok, mask = pcall(getCollisionMask, hitId)
        if not ok or mask == nil or mask == 0 then return true end

        -- Only act on objects that actually block vehicles
        if bitAND(mask, VEHICLE_FLAG) == 0 then return true end

        if isBoundingBoxSmall(hitId) then
            setCollisionMask(hitId, bitAND(mask, bitNOT(VEHICLE_FLAG)))
            nearbyPatched[hitId] = { originalMask = mask, lastSeenMs = nowMs }
            if DIAGNOSTIC_MODE then
                print(string.format(
                    "PassableBushes: disabled VEHICLE collision on '%s' (mask was %d 0x%08X)",
                    getName(hitId) or "?", mask, mask))
            end
        end
        return true
    end

    -- Scan for STATIC_OBJECT things around the vehicle
    overlapSphere(vx, vy + 0.5, vz, SCAN_RADIUS, onOverlap, STATIC_FLAG)

    -- Restore objects that are no longer nearby
    for nodeId, data in pairs(nearbyPatched) do
        if nowMs - data.lastSeenMs > 5000 then
            if nodeId ~= nil and entityExists(nodeId) then
                setCollisionMask(nodeId, data.originalMask)
                if DIAGNOSTIC_MODE then
                    print(string.format("PassableBushes: restored collision on '%s'",
                        getName(nodeId) or "?"))
                end
            end
            nearbyPatched[nodeId] = nil
        end
    end
end

-- ============================================================
-- Diagnostic — log everything in a 3 m sphere around the vehicle
-- ============================================================
local function runDiagnostic(vehicle)
    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
    print(string.format("PassableBushes DIAG: 3 m sphere around '%s':", getName(vehicle.rootNode)))
    local count = 0
    local function onOverlap(hitId, ...)
        if hitId == nil or hitId == vehicle.rootNode then return true end
        local ok, mask = pcall(getCollisionMask, hitId)
        local maskStr = (ok and mask ~= nil) and string.format("%d (0x%08X)", mask, mask) or "N/A"
        print(string.format("  '%s'  mask=%s", getName(hitId) or "?", maskStr))
        count = count + 1
        return true
    end
    overlapSphere(vx, vy + 0.5, vz, 3.0, onOverlap, 0xFFFFFFFF)
    if count == 0 then print("  (nothing found)") end
end

-- ============================================================
-- Vehicle hooks
-- ============================================================
if Vehicle ~= nil then
    local origPostLoad = Vehicle.postLoad
    Vehicle.postLoad = function(self, ...)
        local result = origPostLoad(self, ...)
        applyVehicleNodePatch(self)
        return result
    end

    -- Track last scan times per vehicle
    local lastScanMs  = {}
    local lastDiagMs  = {}

    local origUpdateTick = Vehicle.updateTick
    Vehicle.updateTick = function(self, dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
        local result = origUpdateTick(self, dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)

        if not isActiveForInput or self.spec_drivable == nil then return result end

        local now  = g_currentMission and g_currentMission.time or 0
        local key  = self.rootNode

        -- Dynamic nearby-object scan every 500 ms
        if now - (lastScanMs[key] or 0) >= 500 then
            lastScanMs[key] = now
            scanNearbyObjects(self, now)
        end

        -- Diagnostic scan every 5 s
        if DIAGNOSTIC_MODE and now - (lastDiagMs[key] or 0) >= 5000 then
            lastDiagMs[key] = now
            runDiagnostic(self)
        end

        return result
    end

    local origDelete = Vehicle.delete
    Vehicle.delete = function(self, ...)
        removeVehicleNodePatch(self)
        lastScanMs[self.rootNode] = nil
        lastDiagMs[self.rootNode] = nil
        return origDelete(self, ...)
    end
else
    print("PassableBushes: ERROR — Vehicle class not found. Mod will not work.")
end

dumpCollisionFlags()
