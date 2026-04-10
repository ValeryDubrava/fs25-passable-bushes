-- PassableBushes.lua
-- Farming Simulator 25 mod: lets all drivable vehicles pass through
-- small trees and bushes instead of being stopped by them.
--
-- Strategy:
--   1. Strip CollisionFlag.TREE (and any other named vegetation flags) from
--      the vehicle's own collision nodes the first time the player sits in it.
--   2. Every ~500 ms scan a sphere around the controlled vehicle for
--      STATIC_OBJECT hits (seedlings, decorative bushes). For each hit that
--      is small enough (bounding-box check), temporarily strip the VEHICLE
--      collision bit from that world object so the tractor passes through.
--      Restore the bit when the vehicle moves away.
--
-- All periodic work runs through addModEventListener:update which is the
-- guaranteed FS25 mod API and does not depend on Vehicle class internals.

local MOD_NAME = g_currentModName

-- Set false once you're happy with the mod behaviour.
local DIAGNOSTIC_MODE = true

-- Size thresholds for "passable vegetation".
local MAX_VEGETATION_HEIGHT = 3.0   -- metres
local MAX_VEGETATION_WIDTH  = 2.0   -- metres
local SCAN_RADIUS           = 5.0   -- metres around the vehicle

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
-- Vegetation mask stripped from the vehicle's own nodes
-- ============================================================
local function buildVegetationMask()
    local mask = 0
    if CollisionFlag ~= nil then
        local candidates = {
            "TREE", "FOLIAGE", "BUSH", "STATIC_TREE", "SPLIT_SHAPE",
            "PLANT", "VEGETATION",
        }
        for _, name in ipairs(candidates) do
            if CollisionFlag[name] ~= nil then
                mask = bitOR(mask, CollisionFlag[name])
                print(string.format(
                    "PassableBushes: vehicle-node mask — stripping CollisionFlag.%s = %d (0x%X)",
                    name, CollisionFlag[name], CollisionFlag[name]))
            end
        end
    end
    if mask == 0 then
        mask = 1048576   -- 2^20 fallback
        print("PassableBushes: no named flags found, using fallback mask " .. mask)
    end
    return mask
end

local VEG_MASK     = buildVegetationMask()
local VEG_INV_MASK = bitNOT(VEG_MASK)
local VEHICLE_FLAG = CollisionFlag ~= nil and CollisionFlag.VEHICLE       or 65536   -- 0x10000
local STATIC_FLAG  = CollisionFlag ~= nil and CollisionFlag.STATIC_OBJECT or 2       -- 0x00002

-- ============================================================
-- State
-- ============================================================
local vehiclePatched = {}   -- rootNode -> list of {node, originalMask}
local nearbyPatched  = {}   -- objectId -> {originalMask, lastSeenMs}

-- ============================================================
-- Part 1 — patch the vehicle's own collision nodes (once per vehicle)
-- ============================================================
local function applyVehicleNodePatch(vehicle)
    if vehiclePatched[vehicle.rootNode] ~= nil then return end

    local patches = {}
    local function walk(node)
        local ok, mask = pcall(getCollisionMask, node)
        if ok and mask ~= nil and mask ~= 0 then
            if bitAND(mask, VEG_MASK) ~= 0 then
                setCollisionMask(node, bitAND(mask, VEG_INV_MASK))
                table.insert(patches, { node = node, originalMask = mask })
            end
        end
        for i = 0, getNumOfChildren(node) - 1 do
            walk(getChildAt(node, i))
        end
    end
    walk(vehicle.rootNode)

    vehiclePatched[vehicle.rootNode] = patches
    print(string.format("PassableBushes: vehicle-node patch — %d node(s) patched on '%s'",
        #patches, getName(vehicle.rootNode)))
end

local function restoreVehicleNodePatch(rootNode)
    local patches = vehiclePatched[rootNode]
    if patches == nil then return end
    for _, p in ipairs(patches) do
        if p.node ~= nil and entityExists(p.node) then
            setCollisionMask(p.node, p.originalMask)
        end
    end
    vehiclePatched[rootNode] = nil
end

-- ============================================================
-- Part 2 — dynamically patch small world objects near the vehicle
-- ============================================================
local function isBoundingBoxSmall(nodeId)
    local ok, x1, y1, z1, x2, y2, z2 = pcall(getWorldBoundingBox, nodeId)
    if ok and x1 ~= nil then
        local h = math.abs(y2 - y1)
        local w = math.max(math.abs(x2 - x1), math.abs(z2 - z1))
        return h < MAX_VEGETATION_HEIGHT and w < MAX_VEGETATION_WIDTH
    end
    -- Bounding box unavailable — fall back to name heuristic
    local name = (getName(nodeId) or ""):lower()
    return name:find("tree")     ~= nil
        or name:find("bush")     ~= nil
        or name:find("plant")    ~= nil
        or name:find("shrub")    ~= nil
        or name:find("hedge")    ~= nil
        or name:find("sapling")  ~= nil
        or name:find("seedling") ~= nil
end

local function scanNearbyObjects(vehicle, nowMs)
    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)

    local function onOverlap(hitId, ...)
        if hitId == nil or hitId == vehicle.rootNode then return true end

        if nearbyPatched[hitId] ~= nil then
            nearbyPatched[hitId].lastSeenMs = nowMs
            return true
        end

        local ok, mask = pcall(getCollisionMask, hitId)
        if not ok or mask == nil or mask == 0 then return true end
        if bitAND(mask, VEHICLE_FLAG) == 0 then return true end   -- doesn't block vehicles

        if isBoundingBoxSmall(hitId) then
            setCollisionMask(hitId, bitAND(mask, bitNOT(VEHICLE_FLAG)))
            nearbyPatched[hitId] = { originalMask = mask, lastSeenMs = nowMs }
            if DIAGNOSTIC_MODE then
                print(string.format(
                    "PassableBushes: stripped VEHICLE bit on '%s'  (mask was %d  0x%08X)",
                    getName(hitId) or "?", mask, mask))
            end
        end
        return true
    end

    overlapSphere(vx, vy + 0.5, vz, SCAN_RADIUS, onOverlap, STATIC_FLAG)

    -- Restore objects no longer nearby
    for nodeId, data in pairs(nearbyPatched) do
        if nowMs - data.lastSeenMs > 5000 then
            if nodeId ~= nil and entityExists(nodeId) then
                setCollisionMask(nodeId, data.originalMask)
                if DIAGNOSTIC_MODE then
                    print(string.format("PassableBushes: restored '%s'", getName(nodeId) or "?"))
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
        local maskStr = (ok and mask ~= nil)
            and string.format("%d (0x%08X)", mask, mask)
            or  "N/A"
        print(string.format("  '%s'  mask=%s", getName(hitId) or "?", maskStr))
        count = count + 1
        return true
    end
    overlapSphere(vx, vy + 0.5, vz, 3.0, onOverlap, 0xFFFFFFFF)
    if count == 0 then print("  (nothing found)") end
end

-- ============================================================
-- Periodic update logic (called from whichever hook fires)
-- ============================================================
local lastScanMs  = 0
local lastDiagMs  = 0
local updateFired = false   -- one-shot confirmation log

local function onModUpdate(dt)
    if not updateFired then
        updateFired = true
        print("PassableBushes: update hook firing — mission=" .. tostring(g_currentMission ~= nil))
    end

    if g_currentMission == nil then return end

    local vehicle = g_currentMission.controlledVehicle
    if vehicle == nil or vehicle.rootNode == nil or vehicle.spec_drivable == nil then
        -- Log once per 5 s so we know the hook is alive even without a vehicle
        local now = g_currentMission.time or 0
        if DIAGNOSTIC_MODE and now - lastDiagMs >= 5000 then
            lastDiagMs = now
            print("PassableBushes DIAG: update alive, no controlled vehicle yet")
        end
        return
    end

    local now = g_currentMission.time or 0

    -- One-time patch of the vehicle's own collision nodes
    applyVehicleNodePatch(vehicle)

    -- Scan nearby static objects every 500 ms
    if now - lastScanMs >= 500 then
        lastScanMs = now
        scanNearbyObjects(vehicle, now)
    end

    -- Diagnostic dump every 5 s
    if DIAGNOSTIC_MODE and now - lastDiagMs >= 5000 then
        lastDiagMs = now
        runDiagnostic(vehicle)
    end
end

-- ============================================================
-- Hook 1: addModEventListener (standard FS25 mod API)
-- ============================================================
local PassableBushesListener = {}
function PassableBushesListener:update(dt)
    onModUpdate(dt)
end
addModEventListener(PassableBushesListener)

-- ============================================================
-- Hook 2: FSBaseMission.update (fallback if listener:update never fires)
-- ============================================================
if FSBaseMission ~= nil and FSBaseMission.update ~= nil then
    FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, function(self, dt)
        onModUpdate(dt)
    end)
    print("PassableBushes: FSBaseMission.update hook installed")
else
    print("PassableBushes: FSBaseMission not available")
end

-- ============================================================
-- Vehicle.delete hook — restore masks when a vehicle is removed
-- ============================================================
if Vehicle ~= nil and Vehicle.delete ~= nil then
    local origDelete = Vehicle.delete
    Vehicle.delete = function(self, ...)
        if self.rootNode ~= nil then
            restoreVehicleNodePatch(self.rootNode)
        end
        return origDelete(self, ...)
    end
end

-- ============================================================
dumpCollisionFlags()
print("PassableBushes: mod loaded — listener registered")
