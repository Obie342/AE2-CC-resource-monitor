--=============================================================================
-- me system monitor  (advanced peripherals me bridge -> advanced monitor)
-- target: allthemods 10 v5.3.1 | ae2 19.2.17 | advanced peripherals 0.7.57b
--         cc:tweaked 1.116.2 | applied flux for fe-backed network power
--
-- method names confirmed from bridge_methods.txt on this build:
--   getItems           listItems fallback
--   getFluids          listFluids fallback
--   getChemicals       listChemicals fallback
--   getCells           listCells fallback
--   getStoredEnergy    getEnergyStorage fallback
--   getEnergyCapacity  getMaxEnergyStorage fallback
--   getAverageEnergyInput  getAvgPowerInjection fallback
--   getUsedChemicalStorage / getTotalChemicalStorage  (confirmed present)
--   getCraftingTasks   getCraftingCPUs  isOnline  isConnected  (all confirmed)
--
-- multi-monitor: a second monitor auto-detected via peripheral.find() becomes
-- a dedicated crafting & activity screen. or merge into one wider wall for
-- an automatic two-column layout.
--=============================================================================

--============================== config =======================================
local CONFIG = {
    monitorTextScale = 1.0,
    pollInterval     = 2,
    frameRate        = 10,
    topItemCount     = 20,
    aeToFe           = 2,       -- multiply AE by this for the FE equivalent
    barEase          = 0.20,
    sparkSamples     = 64,
    sparkRows        = 3,
    twoColMinWidth   = 64,
    tpsAvgSamples    = 5,
    infThreshold     = 2147483640,   -- 2^31-1 sentinel = infinite/void cell (items)
    infThresholdMb   = 2100000000000, -- ~2.1 trillion mB sentinel = infinite fluid/chem cell

    -- cell name substrings for exotic types; adjust if addon uses different names
    sourceMatch = { "source", "arseng", "ars_eng", "energistique" },
    soulMatch   = { "soul" },
    showSource  = true,
    showSoul    = true,

    -- optional: pin primary monitor by peripheral name, e.g. "monitor_0"
    primaryMonitor = nil,
    dumpMethods    = true,
}

local TH = {
    bg = colors.black,  panel = colors.gray,     panelHi = colors.lightGray,
    title = colors.white, titleBg = colors.blue,
    label = colors.lightGray, value = colors.white,
    good = colors.lime, okay = colors.yellow, warn = colors.orange, bad = colors.red,
    accent = colors.cyan, empty = colors.gray, inf = colors.white,
    inflow = colors.lime, outflow = colors.red,
    item = colors.cyan,  fluid = colors.lightBlue, chem = colors.green,
    source = colors.purple, soul = colors.magenta, craft = colors.orange,
}
--=============================================================================

local CH_UP, CH_DOWN = string.char(30), string.char(31)
local SPINNER = { "|", "/", "-", "\\" }

--============================== peripherals ==================================
local function findBridge()
    return peripheral.find("me_bridge") or peripheral.find("meBridge")
end

local allMonitors = { peripheral.find("monitor") }
if #allMonitors == 0 then
    error("no monitor found. attach an advanced monitor via wired modem or directly.", 0)
end
local primaryMon, secondaryMon = allMonitors[1], nil
if CONFIG.primaryMonitor then
    for _, m in ipairs(allMonitors) do
        if peripheral.getName(m) == CONFIG.primaryMonitor then primaryMon = m end
    end
end
for _, m in ipairs(allMonitors) do
    if m ~= primaryMon and not secondaryMon then secondaryMon = m end
end
for _, m in ipairs(allMonitors) do m.setTextScale(CONFIG.monitorTextScale) end
local monitor = primaryMon
local g_hasSecondary = (secondaryMon ~= nil)

local playerDetector = peripheral.find("playerDetector")

--============================== api layer ====================================
-- build a concrete method table from the bridge's actual getMethods() output.
-- candidates are tried in order; the first that exists in the method set wins.
-- a final fuzzy predicate is tried if all candidates miss.

local apiRef, api, methodSet = nil, nil, {}

local function loadMethods(bridge)
    methodSet = {}
    local ok, names = pcall(peripheral.getMethods, peripheral.getName(bridge))
    if ok and type(names) == "table" then
        for _, n in ipairs(names) do methodSet[n] = true end
        if CONFIG.dumpMethods then
            local f = fs.open("bridge_methods.txt", "w")
            if f then
                for _, n in ipairs(names) do f.write(n .. "\n") end
                f.close()
            end
        end
    end
end

local function resolve(candidates, fuzzyFn)
    for _, c in ipairs(candidates) do if methodSet[c] then return c end end
    if fuzzyFn then
        for n in pairs(methodSet) do if fuzzyFn(n:lower()) then return n end end
    end
    return nil
end

local function bind(bridge, name)
    if not name or not bridge[name] then
        return function() return nil, "unsupported" end
    end
    local fn = bridge[name]
    return function(...)
        local res = { pcall(fn, ...) }
        if res[1] then return res[2], res[3] else return nil, tostring(res[2]) end
    end
end

local function buildApi(bridge)
    loadMethods(bridge)
    api = {
        -- energy (exact names confirmed from bridge_methods.txt)
        storedEnergy = bind(bridge, resolve({ "getStoredEnergy",         "getEnergyStorage" })),
        energyCap    = bind(bridge, resolve({ "getEnergyCapacity",        "getMaxEnergyStorage" })),
        energyUsage  = bind(bridge, resolve({ "getEnergyUsage" })),
        avgInjection = bind(bridge, resolve({ "getAverageEnergyInput",    "getAvgPowerInjection" })),

        -- status
        isOnline     = bind(bridge, resolve({ "isOnline" })),
        isConnected  = bind(bridge, resolve({ "isConnected" })),

        -- item / fluid / chemical lists
        listItems    = bind(bridge, resolve({ "getItems",     "listItems",     "items" })),
        listFluids   = bind(bridge, resolve({ "getFluids",    "listFluids",    "listFluid" })),
        listChemicals= bind(bridge, resolve({ "getChemicals", "listChemicals", "listGas" })),

        -- cells (getCells confirmed; fallbacks for other builds)
        listCells    = bind(bridge, resolve({ "getCells", "listCells" })),
        getDrives    = bind(bridge, resolve({ "getDrives" })),

        -- crafting
        craftTasks   = bind(bridge, resolve({ "getCraftingTasks" })),
        craftCPUs    = bind(bridge, resolve({ "getCraftingCPUs" })),

        -- item storage (bytes)
        totalItem    = bind(bridge, resolve({ "getTotalItemStorage" })),
        usedItem     = bind(bridge, resolve({ "getUsedItemStorage" })),

        -- fluid storage (bytes)
        totalFluid   = bind(bridge, resolve({ "getTotalFluidStorage" })),
        usedFluid    = bind(bridge, resolve({ "getUsedFluidStorage" })),

        -- chemical storage (bytes) — confirmed in bridge_methods.txt
        totalChem    = bind(bridge, resolve({ "getTotalChemicalStorage" })),
        usedChem     = bind(bridge, resolve({ "getUsedChemicalStorage" })),
    }
end

-- try calling fn with an empty filter first, then with no args;
-- return the first response that is a table.
local function tryList(fn)
    local r, e = fn({})
    if type(r) == "table" then return r end
    local r2, e2 = fn()
    if type(r2) == "table" then return r2 end
    return nil, (e2 or e or "no table returned")
end

--============================== shared state =================================
local function emptyStore() return { ok = false, used = nil, total = 0, count = 0 } end

local state = {
    status = "init", err = nil,
    energy = 0, maxEnergy = 0, usage = 0, inject = 0,
    storage = {
        item = emptyStore(), fluid = emptyStore(), chemical = emptyStore(),
        source = emptyStore(), soul = emptyStore(),
    },
    items = {}, movers = {}, itemTypes = 0, chemTypes = 0,
    fluidList = {}, chemList = {}, combined = {},
    itemDataOk = false, itemErr = nil,
    craftActive = 0, cpus = { busy = 0, total = 0, has = false }, craftJobs = {},
    inPerSec = 0, outPerSec = 0, netPerSec = 0, spark = {},
    players = nil,
    tps = 20, mspt = 50, tpsHist = {},
    lastUpdate = 0, startEpoch = os.epoch("utc"),
}

local anim = { energy = 0, frame = 0,
               item = 0, fluid = 0, chemical = 0, source = 0, soul = 0 }

--============================== helpers ======================================
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function isInf(n)   return n ~= nil and n >= CONFIG.infThreshold end
local function isInfMB(n) return n ~= nil and n >= CONFIG.infThresholdMb end

local function fmt(n)
    n = n or 0
    local a = math.abs(n)
    if a >= 1e12 then return string.format("%.2fT", n / 1e12)
    elseif a >= 1e9 then return string.format("%.2fB", n / 1e9)
    elseif a >= 1e6 then return string.format("%.2fM", n / 1e6)
    elseif a >= 1e3 then return string.format("%.2fK", n / 1e3)
    else return tostring(math.floor(n + 0.5)) end
end
local function fmtAmt(n) return isInf(n) and "INF" or fmt(n) end
local function fmtRate(r)
    local arrow = r > 0 and CH_UP or (r < 0 and CH_DOWN or " ")
    return arrow .. fmt(math.abs(r)) .. "/s"
end

local function writeAt(x, y, text, fg, bg)
    monitor.setCursorPos(x, y)
    if fg then monitor.setTextColor(fg) end
    if bg then monitor.setBackgroundColor(bg) end
    monitor.write(text)
end
local function center(y, text, fg, bg, w)
    writeAt(math.max(1, math.floor((w - #text) / 2) + 1), y, text, fg, bg)
end
local function clearScreen()
    monitor.setBackgroundColor(TH.bg); monitor.setTextColor(TH.value); monitor.clear()
end
local function fillRow(x, y, width, bg)
    monitor.setBackgroundColor(bg); monitor.setCursorPos(x, y)
    monitor.write(string.rep(" ", width))
end
local function easeToward(cur, target, rate) return cur + (target - cur) * rate end

local function drawBar(x, y, width, frac, filledColor, emptyColor)
    frac = clamp(frac, 0, 1)
    local filled = math.floor(frac * width + 0.5)
    local shine = (anim.frame % (width + 8)) - 4
    for i = 1, width do
        local bg = emptyColor
        if i <= filled then
            bg = filledColor
            if i == shine or i == shine + 1 then bg = TH.panelHi end
        end
        monitor.setBackgroundColor(bg)
        monitor.setCursorPos(x + i - 1, y)
        monitor.write(" ")
    end
end

-- indeterminate scanning bar for jobs still calculating
local function drawIndet(x, y, width, color)
    local seg = anim.frame % (width + 4)
    for i = 1, width do
        monitor.setBackgroundColor(math.abs(i - seg) <= 1 and color or TH.empty)
        monitor.setCursorPos(x + i - 1, y)
        monitor.write(" ")
    end
end

local function drawSpark(x, y, width, rows, samples)
    local n = #samples
    local si = math.max(1, n - width + 1)
    local maxMag = 1
    for i = si, n do maxMag = math.max(maxMag, math.abs(samples[i])) end
    local mid = math.floor(rows / 2)
    local col = 0
    for i = si, n do
        col = col + 1
        local v, mag = samples[i], math.floor((math.abs(samples[i]) / maxMag) * mid + 0.5)
        for r = 1, rows do
            local cx = mid + 1
            local bg = TH.bg
            if v > 0 and r < cx and (cx - r) <= mag then bg = TH.inflow
            elseif v < 0 and r > cx and (r - cx) <= mag then bg = TH.outflow
            elseif r == cx then bg = TH.panel end
            monitor.setBackgroundColor(bg)
            monitor.setCursorPos(x + col - 1, y + r - 1)
            monitor.write(" ")
        end
    end
end

local function fracColor(f) return f >= 0.5 and TH.good or (f >= 0.2 and TH.okay or TH.bad) end
local function usageColor(f) return f >= 0.85 and TH.bad or (f >= 0.6 and TH.warn or TH.good) end

local ITEM_PALETTE = {
    colors.lime, colors.green, colors.cyan, colors.lightBlue, colors.blue,
    colors.purple, colors.magenta, colors.pink, colors.red, colors.orange, colors.yellow,
}

--============================== data loop ====================================
local prevSnap, prevTime, nameMap = nil, nil, {}

-- scan cells via getCells() for exotic types (source/soul)
-- cell fields: item (registry name), cellType, totalBytes; format may vary by addon
local function scanCells()
    local src, soul = emptyStore(), emptyStore()
    local cells = tryList(api.listCells)
    if type(cells) ~= "table" then
        -- fallback: try getDrives which returns a list of drives each with cells
        local drives = api.getDrives()
        if type(drives) == "table" then
            local flat = {}
            for _, d in ipairs(drives) do
                if type(d.cells) == "table" then
                    for _, c in ipairs(d.cells) do flat[#flat + 1] = c end
                end
            end
            cells = flat
        end
    end
    if type(cells) ~= "table" then return src, soul end

    local function matches(s, pats)
        s = string.lower(s or "")
        for _, p in ipairs(pats) do if s:find(p, 1, true) then return true end end
        return false
    end
    for _, c in ipairs(cells) do
        local ok_c, err_c = pcall(function()
            local tag   = tostring(c.item or c.name or "") .. "|" .. tostring(c.cellType or c.type or "")
            local bytes = tonumber(c.totalBytes) or tonumber(c.maxBytes) or 0
            if CONFIG.showSource and matches(tag, CONFIG.sourceMatch) then
                src.ok = true; src.total = src.total + bytes; src.count = src.count + 1
            elseif CONFIG.showSoul and matches(tag, CONFIG.soulMatch) then
                soul.ok = true; soul.total = soul.total + bytes; soul.count = soul.count + 1
            end
        end)
        -- a bad cell entry is silently skipped; it won't crash the poll
        if not ok_c then end  -- ok_c referenced to satisfy lint
    end
    return src, soul
end

local function readStore(usedFn, totalFn)
    local s = emptyStore()
    local t, u = totalFn(), usedFn()
    if type(t) == "number" then s.ok = true; s.total = t end
    if type(u) == "number" then s.used = u end
    return s
end

local function itemAmount(it) return tonumber(it.count) or tonumber(it.amount) or 0 end

local function pollOnce()
    local bridge = findBridge()
    if not bridge then
        state.status, state.err = "nobridge", "no me bridge peripheral"; return
    end
    if bridge ~= apiRef then apiRef = bridge; buildApi(bridge) end

    -- read energy and item storage first — these are used as an online probe
    local energy = api.storedEnergy()
    local maxE   = api.energyCap()
    local itemStore = readStore(api.usedItem, api.totalItem)

    -- online detection: trust isOnline/isConnected when available
    local online, connected = api.isOnline(), api.isConnected()
    local up
    if online ~= nil then
        up = online and (connected ~= false)
    else
        up = (type(energy) == "number") or (type(maxE) == "number") or itemStore.ok
    end
    if not up then state.status, state.err = "offline", "system offline / no power"; return end

    -- energy
    state.energy    = tonumber(energy) or 0
    state.maxEnergy = tonumber(maxE) or 0
    state.usage     = tonumber((api.energyUsage())) or 0
    state.inject    = tonumber((api.avgInjection())) or 0

    -- storage classes
    state.storage.item     = itemStore
    state.storage.fluid    = readStore(api.usedFluid, api.totalFluid)
    state.storage.chemical = readStore(api.usedChem, api.totalChem)
    state.storage.source, state.storage.soul = scanCells()

    -- fluid list
    local fluids = tryList(api.listFluids)
    state.fluidList = {}
    if type(fluids) == "table" then
        for _, fl in ipairs(fluids) do
            local amt  = tonumber(fl.count) or tonumber(fl.amount) or 0
            local name = fl.displayName or fl.name or "?"
            state.fluidList[#state.fluidList + 1] = { name = name, amount = amt }
        end
    end

    -- chemical list
    local chems = tryList(api.listChemicals)
    state.chemList = {}
    if type(chems) == "table" then
        state.chemTypes = #chems
        for _, ch in ipairs(chems) do
            local amt  = tonumber(ch.count) or tonumber(ch.amount) or 0
            local name = ch.displayName or ch.name or "?"
            state.chemList[#state.chemList + 1] = { name = name, amount = amt }
        end
    else
        state.chemTypes = 0
    end

    -- combined list: finite items + fluids + chemicals, sorted by amount
    local combined = {}
    for _, it in ipairs(state.items) do
        if not isInf(it.amount) then
            combined[#combined + 1] = {
                name = it.name, amount = it.amount, kind = "item"
            }
        end
    end
    for _, fl in ipairs(state.fluidList) do
        combined[#combined + 1] = {
            name = fl.name, amount = fl.amount,
            kind = "fluid", infinite = isInfMB(fl.amount)
        }
    end
    for _, ch in ipairs(state.chemList) do
        combined[#combined + 1] = {
            name = ch.name, amount = ch.amount,
            kind = "chem", infinite = isInfMB(ch.amount)
        }
    end
    table.sort(combined, function(a, b) return a.amount > b.amount end)
    state.combined = combined

    -- crafting
    local cpus = api.craftCPUs()
    if type(cpus) == "table" then
        local busy = 0
        for _, c in ipairs(cpus) do if c.isBusy then busy = busy + 1 end end
        state.cpus = { busy = busy, total = #cpus, has = true }
    end

    local jobs = {}
    local tasks = api.craftTasks()
    if type(tasks) == "table" then
        for _, v in ipairs(tasks) do
            local r = (type(v.resource) == "table") and v.resource or {}
            jobs[#jobs + 1] = {
                name = r.displayName or r.name or "?",
                quantity = tonumber(v.quantity) or 0,
                crafted  = tonumber(v.crafted) or -1,
                status   = tostring(v.status or ""),
            }
        end
        state.craftActive = #tasks
    end
    state.craftJobs = jobs

    -- player count (optional)
    if playerDetector then
        local ok, pl = pcall(playerDetector.getOnlinePlayers)
        if ok and type(pl) == "table" then state.players = #pl end
    end

    -- item listing (best-effort; failure does NOT take dashboard offline)
    local items, listErr = tryList(api.listItems)
    state.itemDataOk = (items ~= nil)
    state.itemErr = listErr
    if items then
        local snap = {}; nameMap = {}
        for _, it in ipairs(items) do
            local key = it.fingerprint or (it.name .. "|" .. (it.nbt or ""))
            snap[key] = (snap[key] or 0) + itemAmount(it)
            nameMap[key] = it.displayName or it.name or "?"
        end
        state.itemTypes = #items
        local list = {}
        for key, amt in pairs(snap) do
            list[#list + 1] = { name = nameMap[key], amount = amt }
        end
        table.sort(list, function(a, b) return a.amount > b.amount end)
        state.items = list

        local now = os.epoch("utc") / 1000
        if prevSnap then
            local dt = now - prevTime
            if dt > 0 then
                local inSum, outSum, movers = 0, 0, {}
                for key, amt in pairs(snap) do
                    if not isInf(amt) then
                        local d = amt - (prevSnap[key] or 0)
                        if d > 0 then inSum = inSum + d
                        elseif d < 0 then outSum = outSum - d end
                        if d ~= 0 then
                            movers[#movers + 1] = { name = nameMap[key] or "?", rate = d / dt }
                        end
                    end
                end
                for key, amt in pairs(prevSnap) do
                    if snap[key] == nil and not isInf(amt) then outSum = outSum + amt end
                end
                state.inPerSec  = inSum / dt
                state.outPerSec = outSum / dt
                state.netPerSec = (inSum - outSum) / dt
                state.spark[#state.spark + 1] = state.netPerSec
                while #state.spark > CONFIG.sparkSamples do
                    table.remove(state.spark, 1)
                end
                table.sort(movers, function(a, b)
                    return math.abs(a.rate) > math.abs(b.rate)
                end)
                state.movers = movers
            end
        end
        prevSnap, prevTime = snap, now
    end

    state.status, state.err, state.lastUpdate = "online", nil, os.epoch("utc")
end

local function dataLoop()
    while true do
        local ok, err = pcall(pollOnce)
        if not ok then
            state.status = "offline"
            state.err    = "poll error: " .. tostring(err)
        end
        sleep(CONFIG.pollInterval)
    end
end

local function tpsLoop()
    while true do
        local t0 = os.epoch("utc")
        sleep(1)
        local dt = (os.epoch("utc") - t0) / 1000
        local tps = math.min(20, dt > 0 and (20 / dt) or 20)
        state.tpsHist[#state.tpsHist + 1] = tps
        while #state.tpsHist > CONFIG.tpsAvgSamples do
            table.remove(state.tpsHist, 1)
        end
        local sum = 0
        for _, v in ipairs(state.tpsHist) do sum = sum + v end
        state.tps  = sum / #state.tpsHist
        state.mspt = state.tps > 0 and math.min(1000 / state.tps, 999) or 999
    end
end

--============================== render helpers ===============================
local function drawTitle(w, label)
    fillRow(1, 1, w, TH.titleBg)
    local sweep = (anim.frame % (w + 10)) - 5
    if sweep >= 1 and sweep <= w then
        writeAt(sweep, 1, " ", nil, colors.lightBlue)
    end
    local dot = SPINNER[(math.floor(anim.frame / 2) % #SPINNER) + 1]
    center(1, label .. " " .. dot, TH.title, TH.titleBg, w)
end

local function drawPower(x, y, w)
    local frac = state.maxEnergy > 0 and (state.energy / state.maxEnergy) or 0
    anim.energy = easeToward(anim.energy, frac, CONFIG.barEase)

    writeAt(x, y, "NETWORK POWER", TH.accent, TH.bg)
    drawBar(x, y + 1, w, anim.energy, fracColor(frac), TH.empty)

    -- row 1: AE stored / capacity + %
    local pct = string.format("%d%%", math.floor(frac * 100 + 0.5))
    writeAt(x, y + 2, fmt(state.energy) .. "/" .. fmt(state.maxEnergy) .. " AE", TH.value, TH.bg)
    writeAt(x + w - #pct, y + 2, pct, fracColor(frac), TH.bg)

    -- row 2: drain + injection left, FE stored/capacity right
    local drainStr = "Drain " .. fmt(state.usage)
        .. (state.inject > 0 and ("  In " .. fmt(state.inject)) or "")
        .. " AE/t"
    writeAt(x, y + 3, drainStr, TH.label, TH.bg)
    local fe = fmt(state.energy * CONFIG.aeToFe)
        .. "/" .. fmt(state.maxEnergy * CONFIG.aeToFe) .. " FE"
    writeAt(x + w - #fe, y + 3, fe, TH.label, TH.bg)

    return y + 5
end

-- single-row storage entry: Label  used/total pct | animated bar
local function drawStoreRow(x, y, w, label, d, color, animKey, fallbackText)
    local barW  = math.max(6, math.floor(w * 0.28))
    local textW = w - barW - 1
    local hasUsed = d.ok and d.total > 0 and d.used ~= nil
    local frac = hasUsed and clamp(d.used / d.total, 0, 1) or 0
    anim[animKey] = easeToward(anim[animKey] or 0, frac, CONFIG.barEase)

    writeAt(x, y, label, color, TH.bg)

    if hasUsed then
        local pct  = string.format("%d%%", math.floor(frac * 100 + 0.5))
        local nums = fmt(d.used) .. "/" .. fmt(d.total) .. " " .. pct
        if #nums > textW - #label - 1 then nums = fmt(d.used) .. " " .. pct end
        writeAt(x + textW - #nums, y, nums, usageColor(frac), TH.bg)
        drawBar(x + textW + 1, y, barW, anim[animKey], usageColor(frac), TH.empty)
    elseif d.ok and d.used ~= nil and d.used > 0 then
        -- has data but total unknown (e.g. third-party chemical cells)
        local nums = fmt(d.used) .. " in use"
        writeAt(x + textW - #nums, y, nums, TH.okay, TH.bg)
        drawBar(x + textW + 1, y, barW, 1, color, TH.empty)
    elseif d.ok and d.total > 0 then
        local nums = "cap " .. fmt(d.total)
            .. (d.count > 0 and (" (" .. d.count .. ")") or "")
        writeAt(x + textW - #nums, y, nums, TH.label, TH.bg)
        drawBar(x + textW + 1, y, barW, 1, color, TH.empty)
    else
        local txt = fallbackText or (d.ok and "empty" or "n/a")
        writeAt(x + textW - #txt, y, txt, TH.label, TH.bg)
        fillRow(x + textW + 1, y, barW, TH.empty)
    end
    return y + 1
end

local function drawStorageBlock(x, y, w)
    writeAt(x, y, "STORAGE (AE2 bytes)", TH.accent, TH.bg)
    y = y + 1
    y = drawStoreRow(x, y, w, "Items",    state.storage.item,     TH.item,   "item")
    y = drawStoreRow(x, y, w, "Fluids",   state.storage.fluid,    TH.fluid,  "fluid")
    local chemFallback = state.chemTypes > 0 and (state.chemTypes .. " types") or nil
    y = drawStoreRow(x, y, w, "Chem", state.storage.chemical, TH.chem, "chemical", chemFallback)
    if CONFIG.showSource then
        y = drawStoreRow(x, y, w, "Source", state.storage.source, TH.source, "source")
    end
    if CONFIG.showSoul then
        y = drawStoreRow(x, y, w, "Souls",  state.storage.soul,   TH.soul,   "soul")
    end
    return y
end

local function drawCraftSummary(x, y, w)
    local s = "CRAFTING  jobs:" .. state.craftActive
    if state.cpus.has then
        s = s .. "  cpu:" .. state.cpus.busy .. "/" .. state.cpus.total
    end
    writeAt(x, y, s, state.craftActive > 0 and TH.craft or TH.accent, TH.bg)
    return y + 1
end

local function drawCraftJobs(x, y, w, rows)
    writeAt(x, y, "CRAFTING JOBS (" .. #state.craftJobs .. ")", TH.craft, TH.bg)
    if #state.craftJobs == 0 then
        if state.cpus.has and state.cpus.busy > 0 then
            writeAt(x, y + 1, state.cpus.busy .. " CPU(s) busy (terminal job)", TH.warn, TH.bg)
            writeAt(x, y + 2, "only bridge-started jobs tracked", TH.label, TH.bg)
            return y + 3
        end
        writeAt(x, y + 1, "no active jobs", TH.label, TH.bg)
        return y + 2
    end
    local barW  = math.max(6, math.floor(w * 0.30))
    local progW = 11
    local nameW = w - barW - progW - 2
    local shown = math.min(#state.craftJobs, math.max(0, rows - 1))
    for i = 1, shown do
        local j, row = state.craftJobs[i], y + i
        local name = j.name
        if #name > nameW then name = name:sub(1, nameW - 1) .. "\7" end
        writeAt(x, row, name, TH.value, TH.bg)
        if j.quantity > 0 and j.crafted >= 0 then
            local frac = clamp(j.crafted / j.quantity, 0, 1)
            local prog = fmt(j.crafted) .. "/" .. fmt(j.quantity)
            writeAt(x + nameW + 1, row,
                string.rep(" ", math.max(0, progW - #prog)) .. prog, TH.label, TH.bg)
            drawBar(x + w - barW, row, barW, frac, TH.craft, TH.empty)
        else
            writeAt(x + nameW + 1, row,
                string.rep(" ", progW - 4) .. "calc", TH.label, TH.bg)
            drawIndet(x + w - barW, row, barW, TH.craft)
        end
    end
    return y + shown + 1
end

local function drawThroughput(x, y, w)
    writeAt(x, y, "THROUGHPUT", TH.accent, TH.bg)
    if not state.itemDataOk then
        writeAt(x, y + 1, "item data unavailable", TH.warn, TH.bg)
        return y + 2
    end
    local netColor = state.netPerSec > 0 and TH.inflow
                  or (state.netPerSec < 0 and TH.outflow or TH.label)
    writeAt(x + w - #(fmtRate(state.netPerSec)), y,
        fmtRate(state.netPerSec), netColor, TH.bg)
    writeAt(x, y + 1, "In " .. CH_UP .. fmt(state.inPerSec) .. "/s", TH.inflow, TH.bg)
    local outStr = "Out " .. CH_DOWN .. fmt(state.outPerSec) .. "/s"
    writeAt(x + w - #outStr, y + 1, outStr, TH.outflow, TH.bg)
    drawSpark(x, y + 2, w, CONFIG.sparkRows, state.spark)
    return y + 2 + CONFIG.sparkRows + 1
end

local function drawMovers(x, y, w, rows)
    writeAt(x, y, "TOP MOVERS", TH.accent, TH.bg)
    local shown = math.min(#state.movers, math.max(0, rows - 1))
    if shown == 0 then writeAt(x, y + 1, "(quiet)", TH.label, TH.bg) end
    for i = 1, shown do
        local mv, row = state.movers[i], y + i
        local rateStr = fmtRate(mv.rate)
        local nameW = w - #rateStr - 1
        local name = mv.name
        if #name > nameW then name = name:sub(1, nameW - 1) .. "\7" end
        writeAt(x, row, name, TH.value, TH.bg)
        writeAt(x + w - #rateStr, row, rateStr,
            mv.rate > 0 and TH.inflow or TH.outflow, TH.bg)
    end
    return y + shown + 1
end

local function drawTopItems(x, y, w, rows)
    writeAt(x, y, "TOP ITEMS", TH.accent, TH.bg)
    if not state.itemDataOk then
        writeAt(x, y + 1, "getItems: " .. tostring(state.itemErr or "?"), TH.warn, TH.bg)
        return y + 2
    end
    -- scale relative bars to largest finite item
    local maxReal = 1
    for _, it in ipairs(state.items) do
        if not isInf(it.amount) and it.amount > maxReal then maxReal = it.amount end
    end
    local shown = math.min(#state.items, math.max(0, rows - 1), CONFIG.topItemCount)
    local barW  = math.max(5, math.floor(w * 0.22))
    local amtW  = 7
    local nameW = w - barW - amtW - 2
    for i = 1, shown do
        local it, row = state.items[i], y + i
        local inf = isInf(it.amount)
        local name = it.name
        if #name > nameW then name = name:sub(1, nameW - 1) .. "\7" end
        local amtStr = fmtAmt(it.amount)
        writeAt(x, row, name, TH.value, TH.bg)
        writeAt(x + nameW + 1, row,
            string.rep(" ", amtW - #amtStr) .. amtStr,
            inf and TH.inf or TH.label, TH.bg)
        local frac = inf and 1 or (it.amount / maxReal)
        local col  = inf and TH.inf
            or ITEM_PALETTE[((i - 1 + math.floor(anim.frame / 4)) % #ITEM_PALETTE) + 1]
        drawBar(x + w - barW, row, barW, frac, col, TH.empty)
    end
    return y + shown + 1
end

local function drawFooter(w, h, centerText)
    fillRow(1, h - 1, w, TH.panel)
    fillRow(1, h, w, TH.panel)

    local tpsColor = state.tps >= 19 and TH.good
                  or (state.tps >= 15 and TH.okay or TH.bad)
    local tpsStr = string.format("TPS %.1f", state.tps)
    writeAt(2, h - 1, tpsStr, tpsColor, TH.panel)
    writeAt(2 + #tpsStr + 1, h - 1,
        string.format("%dms", math.floor(state.mspt + 0.5)), TH.value, TH.panel)
    local right = textutils.formatTime(os.time(), false)
    if state.players ~= nil then right = state.players .. "p " .. right end
    writeAt(w - #right, h - 1, right, TH.value, TH.panel)
    center(h - 1, "Day " .. os.day(), TH.value, TH.panel, w)

    local up = math.floor((os.epoch("utc") - state.startEpoch) / 1000)
    local uptime = string.format("%02d:%02d:%02d",
        math.floor(up / 3600), math.floor(up / 60) % 60, up % 60)
    writeAt(2, h, "GRID ONLINE", TH.good, TH.panel)
    center(h, centerText or (state.itemTypes .. " item types"), TH.value, TH.panel, w)
    writeAt(w - #uptime, h, uptime, TH.value, TH.panel)
end

--============================== screens =====================================
local function drawPrimary(w, h)
    clearScreen(); drawTitle(w, "ME SYSTEM MONITOR")
    local y = 3
    if w >= CONFIG.twoColMinWidth then
        local colW = math.floor(w / 2) - 2
        local lx, rx = 2, math.floor(w / 2) + 2
        local ly = drawPower(lx, y, colW)
        ly = drawStorageBlock(lx, ly, colW)
        ly = drawCraftSummary(lx, ly, colW)
        if not g_hasSecondary then
            ly = drawCraftJobs(lx, ly + 1, colW, (h - 2) - ly)
        end
        local ry = drawThroughput(rx, y, colW)
        ry = drawTopItems(rx, ry, colW, math.floor(((h - 2) - ry) * 0.7))
        drawMovers(rx, ry, colW, (h - 2) - ry)
    else
        y = drawPower(2, y, w - 2)
        y = drawStorageBlock(2, y, w - 2)
        y = drawCraftSummary(2, y, w - 2)
        if not g_hasSecondary and #state.craftJobs > 0 then
            y = drawCraftJobs(2, y + 1, w - 2, 5) + 1
        end
        y = drawThroughput(2, y, w - 2)
        drawTopItems(2, y, w - 2, (h - 2) - y)
    end
    drawFooter(w, h)
end

local function drawCombinedList(x, y, w, rows)
    local list = state.combined
    local typeColors = { item = TH.item, fluid = TH.fluid, chem = TH.chem }
    local typeTags   = { item = "I",     fluid = "F",      chem  = "C"    }
    writeAt(x, y, "TOP RESOURCES (" .. #list .. ")", TH.accent, TH.bg)
    if #list == 0 then
        writeAt(x, y + 1, "(no data yet)", TH.label, TH.bg); return y + 2
    end
    local maxAmt = 1
    for _, r in ipairs(list) do
        if not r.infinite and r.amount > maxAmt then maxAmt = r.amount end
    end
    local barW  = math.max(5, math.floor(w * 0.20))
    local amtW  = 9      -- room for "123.45MmB"
    local typeW = 1
    local nameW = w - barW - amtW - typeW - 3
    local shown = math.min(#list, math.max(0, rows - 1), 40)
    for i = 1, shown do
        local r, row = list[i], y + i
        local tag      = typeTags[r.kind]  or "?"
        local tagColor = typeColors[r.kind] or TH.value
        local unit   = r.kind ~= "item" and "mB" or ""
        local amtStr = r.infinite and "INF" or (fmt(r.amount) .. unit)
        local frac   = r.infinite and 1 or clamp(r.amount / maxAmt, 0, 1)
        local barColor = r.infinite and TH.inf
            or ITEM_PALETTE[((i - 1 + math.floor(anim.frame / 4)) % #ITEM_PALETTE) + 1]
        local name = r.name
        if #name > nameW then name = name:sub(1, nameW - 1) .. "\7" end
        writeAt(x, row, tag, tagColor, TH.bg)
        writeAt(x + typeW + 1, row, name, TH.value, TH.bg)
        writeAt(x + typeW + 1 + nameW + 1, row,
            string.rep(" ", math.max(0, amtW - #amtStr)) .. amtStr,
            r.infinite and TH.inf or TH.label, TH.bg)
        drawBar(x + w - barW, row, barW, frac, barColor, TH.empty)
    end
    return y + shown + 1
end

local function drawSecondary(w, h)
    clearScreen(); drawTitle(w, "CRAFTING & ACTIVITY")
    local y = 3
    local avail = (h - 2) - y
    y = drawCraftJobs(2, y, w - 2, math.floor(avail * 0.40)) + 1
    y = drawMovers(2, y, w - 2, math.floor(avail * 0.25)) + 1
    drawCombinedList(2, y, w - 2, (h - 2) - y)
    local resLabel = state.itemTypes .. "i  "
        .. #state.fluidList .. "f  "
        .. state.chemTypes .. "c"
    drawFooter(w, h, resLabel)
end

local function drawAlert(w, h, headline, color)
    clearScreen()
    local pulse = (math.floor(anim.frame / 3) % 2 == 0) and color or TH.panel
    for x = 1, w do writeAt(x, 1, " ", nil, pulse); writeAt(x, h, " ", nil, pulse) end
    for yy = 1, h do writeAt(1, yy, " ", nil, pulse); writeAt(w, yy, " ", nil, pulse) end
    local cy = math.floor(h / 2)
    center(cy - 1, "\19 " .. headline .. " \19", color, TH.bg, w)
    if state.err then center(cy + 1, state.err, TH.label, TH.bg, w) end
    local dots = string.rep(".", math.floor(anim.frame / 3) % 4)
    center(cy + 3, "retrying" .. dots
        .. SPINNER[(math.floor(anim.frame / 2) % #SPINNER) + 1], TH.label, TH.bg, w)
end

local function renderOne(mon, isSecondary)
    monitor = mon
    local w, h = monitor.getSize()
    local ok, err = pcall(function()
        if state.status == "online" then
            if isSecondary then drawSecondary(w, h) else drawPrimary(w, h) end
        elseif state.status == "offline" then
            drawAlert(w, h, "SYSTEM OFFLINE", TH.bad)
        elseif state.status == "nobridge" then
            drawAlert(w, h, "WAITING FOR ME BRIDGE", TH.warn)
        else
            clearScreen()
            center(math.floor(h / 2), "starting up "
                .. SPINNER[(math.floor(anim.frame / 2) % #SPINNER) + 1],
                TH.accent, TH.bg, w)
        end
    end)
    if not ok then
        clearScreen()
        center(2, "render error (recovering)", TH.bad, TH.bg, (monitor.getSize()))
        writeAt(2, 4, tostring(err), TH.label, TH.bg)
    end
end

local function renderLoop()
    while true do
        anim.frame = anim.frame + 1
        renderOne(primaryMon, false)
        if secondaryMon then renderOne(secondaryMon, true) end
        sleep(1 / CONFIG.frameRate)
    end
end

--============================== run ==========================================
clearScreen()
parallel.waitForAny(dataLoop, renderLoop, tpsLoop)