# Passable Bushes — FS25 Mod

Tired of your tractor stopping dead every time it touches a small bush or sapling?
This mod makes all drivable vehicles pass through small trees and bushes instead of getting stuck.

## Installation

1. Go to the [Releases](../../releases) page and download `FS25_PassableBushes.zip`.
2. Copy the zip file into your FS25 mods folder:
   - **Windows:** `C:\Users\<YourName>\Documents\My Games\FarmingSimulator2025\mods\`
   - **macOS:** `~/Library/Application Support/FarmingSimulator2025/mods/`
3. Launch Farming Simulator 25, open the **Mod Hub**, and enable **Passable Bushes**.
4. Start or load a save — the mod applies automatically to every drivable vehicle.

> Do **not** unzip the file. FS25 reads mods directly from the `.zip`.

## How it works

The mod adds a specialization to every drivable vehicle (tractors, combines, etc.) that strips the tree and bush collision bits from the vehicle's physics mask. The engine then ignores contacts with those objects, so the vehicle passes straight through.

## Compatibility

- Farming Simulator 25
- Multiplayer: supported
- Should be compatible with all vehicles and map mods

## Building from source

```bash
git clone git@github.com:ValeryDubrava/fs25-passable-bushes.git
cd fs25-passable-bushes
./build.sh
# → FS25_PassableBushes.zip
```
