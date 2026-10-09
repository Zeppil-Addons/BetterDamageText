-- Better Damage Text
-- Draws our own floating damage numbers above enemy nameplates, with the icon
-- of the spell that caused each hit, and only for hits that are ours.
--
-- WoW Forever blocks COMBAT_LOG_EVENT_UNFILTERED, so nothing tells us "spell X
-- of yours hit mob Y". We rebuild that from what we're allowed to see:
--   UNIT_COMBAT (enemy)       - a mob took damage: amount, school, crit/glancing
--   UNIT_SPELLCAST_SUCCEEDED  - which spell we just cast
--   spell descriptions        - each spell's school, and DoT duration ("... over 12 sec")
--   our buffs / weapon        - Lightning Shield, Flametongue... (read out of combat)
--   our threat on the target  - only our own damage raises it
--
-- A hit is only shown when it's provably ours: our threat rose for it, or its
-- timing, school and amount all match one of our casts, DoTs, procs or shields.
--
-- Timing facts measured in game (Forever 1.60.1), which the rules below rely on:
--   * spell damage is reported the moment it happens
--   * melee hits (ours and the mob's on us) are reported ~0.3-0.8s late, to
--     line up with the swing animation, so a Flametongue proc or Lightning
--     Shield zap arrives BEFORE the swing that caused it
--   * DoTs tick exactly every 3s after the cast (a few every 2s, see DOT_INTERVALS)
--   * threat can only be read on "target", not on nameplate units

local ADDON, ns = ... -- ns is shared with Options.lua

-- Everything the settings window can change. Saved per account.
local defaults = {
    font         = "Fonts\\FRIZQT__.TTF",
    outline      = "OUTLINE",  -- "", "OUTLINE" or "THICKOUTLINE"
    shadow       = false,      -- drop shadow behind the text
    fontSize     = 26,
    critScale    = 1.7,        -- crit size compared to a normal hit
    critPop      = 3.0,        -- size a crit starts at before shrinking to critScale
    showIcon     = true,
    showMeleeIcon = true,      -- icon on white hits too
    iconSide     = "LEFT",     -- which side of the number the icon goes
    iconSize     = 26,
    animation    = "rise",     -- see MOTIONS
    duration     = 1.4,        -- seconds a number stays on screen
    rise         = 70,         -- pixels the number floats upward
    colorMelee   = { 1, 1, 1 },
    colorSpell   = { 1, 0.85, 0.1 },
    showAvoids   = true,       -- show Miss / Dodge / Parry...
    showSuffixes = true,       -- show "(blocked)", "(glancing)"...
    hideBlizzard = true,       -- turn off the default floating damage numbers
    minimapButton = true,
    minimapAngle = 225,        -- where the minimap button sits, in degrees
}
ns.defaults = defaults

-- Where players send bug reports and ideas. Shown in the settings window and
-- by /bdt feedback. The game can't open a browser, so it goes in a box the
-- player can copy from.
ns.FEEDBACK_URL = "https://github.com/Zeppil-Addons/BetterDamageText/issues"

local AUTO_ATTACK_ID = 6603

local CAST_WINDOW     = 1.5  -- a cast is credited with the first matching hit within this many seconds
local INSTANT_WINDOW  = 0.25 -- instant spells land this soon after the cast (measured: same frame)
local AMOUNT_TOLERANCE = 0.15 -- a proc/shield/tick hit within 15% of its usual damage counts as a match
local CHANNEL_GRACE   = 0.3  -- a channel's last tick can land just after it ends
local TICK_INTERVAL   = 3    -- seconds between DoT ticks, unless listed below
local TICK_TOLERANCE  = 0.25

-- DoTs that don't tick every 3s (spell name -> seconds between ticks). Keyed
-- by name so every rank matches. Ticks that miss the expected rhythm fall
-- through to "unknown magic damage" and get the wrong icon.
local DOT_INTERVALS = {
    ["Curse of Agony"] = 2,
    ["Bane of Agony"]  = 2,
    ["Rupture"]        = 2,
    ["Insect Swarm"]   = 2,
    ["Rip"]            = 2,
}
local THREAT_WAIT     = 1.5  -- how long a hit waits for our threat to rise before it's judged not ours
                             -- (measured: up to 1.2s after a proc or shield hit, in step with the late swing)
local CREDIT_KEEP     = 1.0  -- how long a threat rise waits for its (late) melee hit event
local SWING_TOLERANCE = 0.2  -- a swing may be reported this much earlier than weapon speed says

-- Our threat rises by at least this much per point of damage. Salvation and
-- rogue threat reduction bring it down to about 0.5; it's never lower.
local MIN_THREAT_PER_DAMAGE = 0.5

-- Damage school bitmask values from UNIT_COMBAT
local SCHOOL_PHYSICAL = 1
local SCHOOL_WORDS = { Holy = 2, Fire = 4, Nature = 8, Frost = 16, Shadow = 32, Arcane = 64 }

-- Buffs that deal damage to whoever hits you (buff name -> school)
local DAMAGE_SHIELDS = {
    ["Lightning Shield"] = 8,
    ["Thorns"]           = 8,
    ["Fire Shield"]      = 4,
    ["Retribution Aura"] = 2,
}

-- Weapon enchants that add damage when a swing lands. `name` is matched
-- against the green enchant line on the weapon's tooltip ("Flametongue 3 (30 min)").
local WEAPON_PROCS = {
    { name = "Flametongue",    school = 4,  spellID = 8024 },
    { name = "Frostbrand",     school = 16, spellID = 8033 },
    { name = "Instant Poison", school = 8,  spellID = 8679 },
}

-- hit colours are looked up from the settings when shown, so changes apply at once
local COLOR_MELEE = "colorMelee"
local COLOR_SPELL = "colorSpell"

local CRIT_POP_TIME = 0.12  -- seconds for a crit to shrink from its pop size

local db

-- Values from restricted APIs can be "secret": we may display them but not
-- compare or do math on them.
local function IsSecret(v)
    return issecretvalue and issecretvalue(v) or false
end

local function GetIcon(spellID)
    if C_Spell and C_Spell.GetSpellTexture then
        return C_Spell.GetSpellTexture(spellID)
    end
    return GetSpellTexture and GetSpellTexture(spellID)
end

local function SpellName(spellID)
    return C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID) or tostring(spellID)
end

---------------------------------------------------------------------------
-- Debug output and recording
---------------------------------------------------------------------------
-- /bdt debug prints decisions to chat. /bdt record saves them to
-- WTF\Account\<account>\SavedVariables\BetterDamageText.lua (on /reload or logout).
local debugMode, recording = false, false
local MAX_LOG_LINES = 3000

local function Debug(...)
    if not debugMode and not recording then return end
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        parts[i] = IsSecret(v) and "<secret>" or tostring(v)
    end
    local line = table.concat(parts, " ")
    if debugMode then
        print("|cff88ccffBDT:|r " .. line)
    end
    if recording and #BetterDamageTextLog < MAX_LOG_LINES then
        table.insert(BetterDamageTextLog, string.format("%.3f %s", GetTime(), line))
    end
end

---------------------------------------------------------------------------
-- Floating text
---------------------------------------------------------------------------
local pool, active = {}, {}

local function Acquire(showIcon)
    local f = table.remove(pool)
    if not f then
        f = CreateFrame("Frame", nil, UIParent)
        f:SetFrameStrata("HIGH")
        f:SetSize(1, 1)

        f.icon = f:CreateTexture(nil, "OVERLAY")
        f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- trim the default icon border

        f.text = f:CreateFontString(nil, "OVERLAY")

        -- "(blocked)", "(glancing)"... kept separate from the number because the
        -- number can be a secret value, which can't be joined onto other text
        f.suffix = f:CreateFontString(nil, "OVERLAY")
    end

    -- fall back to the default font if the chosen file can't be loaded
    if not f.text:SetFont(db.font, db.fontSize, db.outline) then
        f.text:SetFont(defaults.font, db.fontSize, db.outline)
    end
    if not f.suffix:SetFont(db.font, db.fontSize * 0.7, db.outline) then
        f.suffix:SetFont(defaults.font, db.fontSize * 0.7, db.outline)
    end
    local shadow = db.shadow and math.max(1, db.fontSize / 12) or 0
    for _, fs in ipairs({ f.text, f.suffix }) do
        fs:SetShadowColor(0, 0, 0, 1)
        fs:SetShadowOffset(shadow, -shadow)
    end
    f.icon:SetSize(db.iconSize, db.iconSize)
    f.icon:SetShown(showIcon)

    -- the number sits in the middle, the icon on the chosen side, the suffix after
    f.icon:ClearAllPoints()
    f.text:ClearAllPoints()
    f.suffix:ClearAllPoints()
    if not showIcon then
        f.text:SetPoint("CENTER", f, "CENTER")
        f.suffix:SetPoint("LEFT", f.text, "RIGHT", 4, 0)
    elseif db.iconSide == "RIGHT" then
        f.text:SetPoint("RIGHT", f, "CENTER", -2, 0)
        f.icon:SetPoint("LEFT", f, "CENTER", 2, 0)
        f.suffix:SetPoint("LEFT", f.icon, "RIGHT", 4, 0)
    else
        f.icon:SetPoint("RIGHT", f, "CENTER", -2, 0)
        f.text:SetPoint("LEFT", f, "CENTER", 2, 0)
        f.suffix:SetPoint("LEFT", f.text, "RIGHT", 4, 0)
    end
    return f
end

local function Release(f)
    f:Hide()
    f:ClearAllPoints()
    active[f] = nil
    table.insert(pool, f)
end

-- Nameplates are protected in Forever: addons may attach to them but not
-- measure them. When a mob dies its nameplate is hidden but stays where it
-- was, so its numbers simply stay attached and finish their animation. If the
-- game reuses that nameplate for another mob, the old numbers are removed
-- (see ns.OnNamePlateAdded) so they never jump to the new mob.
local orphaned = {} -- nameplate -> true while it's hidden after its mob died

function ns.OnNamePlateRemoved(plate)
    if plate then orphaned[plate] = true end
end

function ns.OnNamePlateAdded(plate)
    if not plate or not orphaned[plate] then return end
    orphaned[plate] = nil
    for f in pairs(active) do
        if f.anchor == plate then Release(f) end
    end
end

-- Animation styles. Each takes a number's frame and its progress p (0 to 1)
-- and returns its offset from the nameplate in pixels, its opacity, and an
-- extra size multiplier. db.rise sets how far it travels.
local function FadeAfter(p, start)
    return p < start and 1 or (1 - p) / (1 - start)
end

local MOTIONS = {
    -- float straight up, like Blizzard's (new numbers push older ones up)
    rise = function(f, p)
        return f.xOffset, db.rise * p + f.push, FadeAfter(p, 0.5)
    end,
    -- drop downward (new numbers push older ones down)
    fall = function(f, p)
        return f.xOffset, -(db.rise * p + f.push), FadeAfter(p, 0.5)
    end,
    -- arc out to one side, then drop
    fountain = function(f, p)
        return f.xOffset + f.dir * db.rise * 0.9 * p, db.rise * (3.2 * p - 3.6 * p * p), FadeAfter(p, 0.6)
    end,
    -- burst outward in a random upward direction, slowing down
    scatter = function(f, p)
        local d = db.rise * (1 - (1 - p) ^ 2)
        return math.cos(f.angle) * d, math.sin(f.angle) * d, FadeAfter(p, 0.5)
    end,
    -- bounce in place, drift up a little, fade late
    pop = function(f, p)
        local bounce = 1
        if not f.isCrit and f.elapsed < 0.2 then
            bounce = 1 + 0.35 * math.sin(math.pi * f.elapsed / 0.2)
        end
        return f.xOffset, f.push + db.rise * 0.15 * p, FadeAfter(p, 0.7), bounce
    end,
}

-- names shown in the settings window, in order
ns.ANIMATIONS = {
    { "rise",     "Rise (Blizzard-like)" },
    { "fountain", "Fountain" },
    { "fall",     "Fall" },
    { "scatter",  "Scatter" },
    { "pop",      "Pop" },
}

local function Animate(f)
    local p = f.elapsed / db.duration
    local motion = MOTIONS[db.animation] or MOTIONS.rise
    local dx, dy, alpha, bounce = motion(f, p)

    local scale = 1
    if f.isCrit then
        -- Blizzard-style crit: start huge, snap down to crit size
        local t = math.min(f.elapsed / CRIT_POP_TIME, 1)
        scale = db.critPop + (db.critScale - db.critPop) * t
    end
    scale = scale * (bounce or 1)
    f:SetScale(scale)
    -- offsets are in the frame's own (scaled) units, so divide to keep them in screen pixels
    f:SetPoint("BOTTOM", f.anchor, "TOP", dx / scale, dy / scale)
    f:SetAlpha(math.max(0, math.min(1, alpha)))
end

-- `anchor` is the nameplate (or other frame) to float above. A hidden
-- nameplate is fine: its mob just died and it's still where the mob was.
local function ShowHit(anchor, amount, icon, color, isCrit, suffix)
    if not anchor then return end

    -- push numbers already on this enemy upward so the new one doesn't overlap them
    local lineHeight = math.max(db.fontSize, db.iconSize) + 4
    for other in pairs(active) do
        if other.anchor == anchor then
            other.pushTarget = other.pushTarget + lineHeight * (isCrit and db.critScale or 1)
        end
    end

    local f = Acquire(db.showIcon and (color ~= COLOR_MELEE or db.showMeleeIcon))
    f.anchor = anchor
    f.elapsed = 0
    f.isCrit = isCrit
    f.push, f.pushTarget = 0, 0
    f.xOffset = math.random(-15, 15)
    f.dir = math.random() < 0.5 and -1 or 1          -- fountain: which side it arcs to
    f.angle = math.rad(math.random(25, 155))         -- scatter: direction it flies

    f.icon:SetTexture(icon or GetIcon(AUTO_ATTACK_ID))
    f.text:SetText(amount)  -- SetText accepts secret numbers
    f.text:SetTextColor(unpack(db[color]))
    f.suffix:SetText(db.showSuffixes and suffix or "")
    f.suffix:SetTextColor(unpack(db[color]))

    Animate(f)
    f:Show()
    active[f] = true
end

local animator = CreateFrame("Frame")
animator:SetScript("OnUpdate", function(_, elapsed)
    for f in pairs(active) do
        f.elapsed = f.elapsed + elapsed
        local p = f.elapsed / db.duration
        if p >= 1 then
            Release(f)
        else
            -- glide toward the pushed-up position instead of jumping
            f.push = f.push + (f.pushTarget - f.push) * math.min(elapsed * 15, 1)
            Animate(f)
        end
    end
end)

---------------------------------------------------------------------------
-- What we know about our spells, buffs and weapons
---------------------------------------------------------------------------
-- Parsed from the spell description: { damage = bool, school = mask, dot = seconds or nil }.
-- nil while the description hasn't loaded yet.
local spellInfo = {}

local function GetSpellData(spellID)
    if spellInfo[spellID] then return spellInfo[spellID] end
    local desc = C_Spell and C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(spellID)
    if not desc or IsSecret(desc) or desc == "" then return nil end

    local data = { damage = desc:find("damage") ~= nil, school = SCHOOL_PHYSICAL }
    for word, mask in pairs(SCHOOL_WORDS) do
        if desc:find(word .. " damage") then
            data.school = mask
            break
        end
    end
    data.dot = tonumber(desc:match("damage over (%d+) sec"))
    -- the direct damage it lists: "19 to 22 Nature damage" or "25 Fire damage"
    local low, high = desc:match("(%d+) to (%d+)")
    low = tonumber(low or desc:match("(%d+) %a* ?damage"))
    data.minDamage, data.maxDamage = low, tonumber(high) or low
    spellInfo[spellID] = data
    return data
end

-- Auras and tooltips are secret in combat on Forever (touching them throws a
-- taint error), so both scans only run out of combat. In combat we keep the
-- last known state and update it from our own casts (see the cast handler).
local shields = {}      -- school -> icon of an active damage shield buff
local weaponProcs = {}  -- school -> icon of an active weapon enchant

local function UpdateDamageShields()
    if InCombatLockdown() or not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return end
    local found = {}
    local ok = pcall(function()
        for i = 1, 40 do
            local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
            if not aura then return end
            local school = not IsSecret(aura.name) and DAMAGE_SHIELDS[aura.name]
            if school then
                found[school] = aura.icon
            end
        end
    end)
    if ok then shields = found end
end

local function UpdateWeaponProcs()
    if InCombatLockdown() or not (C_TooltipInfo and C_TooltipInfo.GetInventoryItem) then return end
    local found = {}
    local ok = pcall(function()
        for _, slot in ipairs({ 16, 17 }) do -- main hand, off hand
            local info = C_TooltipInfo.GetInventoryItem("player", slot)
            for _, line in ipairs(info and info.lines or {}) do
                local text = line.leftText
                if text and not IsSecret(text) then
                    for _, proc in ipairs(WEAPON_PROCS) do
                        if text:find(proc.name, 1, true) then
                            found[proc.school] = GetIcon(proc.spellID)
                        end
                    end
                end
            end
        end
    end)
    if ok then weaponProcs = found end
end

---------------------------------------------------------------------------
-- Our recent actions
---------------------------------------------------------------------------
local lastCast          -- { spellID, school, time, credited = { unit = true } }
local channel           -- { spellID, school, endTime }
local dots = {}         -- spellID -> { school, duration, interval, times = { cast times } }
local schoolSpell = {}  -- school -> last spell of ours that hit with it (fallback icon)
local autoAttacking = false
local autoAttackEnded = 0 -- when auto attack last switched off

-- Auto attack switches off the moment the mob dies, but the killing swing is
-- reported ~0.6s later, so a swing just after it stopped still counts.
local function Attacking(now)
    return autoAttacking or now - autoAttackEnded < 1.5
end
local lastSwing = { main = 0, off = 0 } -- when each hand's last confirmed swing landed

-- Damage our procs, shields, DoT ticks and channels usually do, learned from
-- hits our threat confirmed. Saved between sessions. Keys: "proc:4", "shield:8",
-- "tick:<spellID>", "channel:<spellID>".
local learned

-- Returns true for casts that never hit a mob themselves (shields, weapon
-- enchants), after noting their effect.
local function NoteBuffCast(spellID)
    local name = SpellName(spellID)
    if IsSecret(name) then return false end
    if DAMAGE_SHIELDS[name] then
        shields[DAMAGE_SHIELDS[name]] = GetIcon(spellID)
        return true
    end
    for _, proc in ipairs(WEAPON_PROCS) do
        if name:find(proc.name, 1, true) then
            weaponProcs[proc.school] = GetIcon(proc.spellID)
            return true
        end
    end
    return false
end

local function OnCast(spellID)
    if IsSecret(spellID) or spellID == AUTO_ATTACK_ID or NoteBuffCast(spellID) then return end
    local data = GetSpellData(spellID)
    Debug("cast", SpellName(spellID), spellID, "school", data and data.school, "dot", data and data.dot,
        "damage", data and data.damage)
    if data and not data.damage then return end -- heals, totems without damage text...

    local now = GetTime()
    lastCast = { spellID = spellID, school = data and data.school, time = now, credited = {} }
    if data and data.dot then
        local name = SpellName(spellID)
        local d = dots[spellID] or { school = data.school, duration = data.dot, times = {},
                                     interval = not IsSecret(name) and DOT_INTERVALS[name] or TICK_INTERVAL }
        dots[spellID] = d
        -- forget casts whose DoT has run out
        for i = #d.times, 1, -1 do
            if now - d.times[i] > d.duration + 1 then table.remove(d.times, i) end
        end
        table.insert(d.times, now)
    end
end

-- Is `now` exactly on one of this DoT's ticks?
local function DotTicking(school, now)
    for spellID, d in pairs(dots) do
        if d.school == school then
            local interval = d.interval or TICK_INTERVAL
            for _, t in ipairs(d.times) do
                local dt = now - t
                if dt > interval - TICK_TOLERANCE and dt < d.duration + TICK_TOLERANCE then
                    local phase = dt % interval
                    if phase < TICK_TOLERANCE or phase > interval - TICK_TOLERANCE then
                        return spellID
                    end
                end
            end
        end
    end
end

-- Does this damage match what this source usually does?
local function MatchesLearned(key, base)
    local usual = base and learned[key]
    return usual ~= nil and math.abs(base - usual) <= math.max(1, usual * AMOUNT_TOLERANCE)
end

-- Does this damage fit the range in the spell's description? Spell power and
-- level differences move it a bit, so the range is widened. Physical spells
-- (Heroic Strike...) describe a bonus, not their damage, so they always fit.
local function FitsSpellRange(spellID, school, base)
    local data = GetSpellData(spellID)
    -- no amount to check: a full resist/immune, or a hidden number
    if base == nil or school == SCHOOL_PHYSICAL or not (data and data.minDamage) then return true end
    return base >= data.minDamage * 0.7 and base <= data.maxDamage * 1.3 + 10
end

-- Weapon procs happen the moment a swing lands, but the swing itself is
-- reported ~0.5-0.8s later, so a proc comes shortly before our next swing is
-- due to be reported. Before we know our swing rhythm, any time fits.
local function FitsProcTiming(now)
    local mh = UnitAttackSpeed("player")
    if not mh or IsSecret(mh) or now - lastSwing.main > mh * 2 then return true end
    local untilSwing = lastSwing.main + mh - now
    return untilSwing > -0.1 and untilSwing < 1.3
end

-- true only if `amount` is clearly closer to a than to b; with either unknown, false
local function Closer(amount, a, b)
    if not amount or not a or not b then return false end
    return math.abs(amount - a) < math.abs(amount - b)
end

-- Which hand swung? Each hand lands on its own rhythm (its weapon speed), so
-- pick the hand whose next swing was due closest to this one. Only fed with
-- swings our threat confirmed, so other players' hits can't throw it off.
local function AssignHand(t)
    local mh, oh = UnitAttackSpeed("player")
    if not oh or IsSecret(oh) or IsSecret(mh) then
        lastSwing.main = t
        return "main"
    end
    local mainOff = math.abs(t - (lastSwing.main + mh))
    local offOff = math.abs(t - (lastSwing.off + oh))
    local hand = offOff < mainOff and "off" or "main"
    lastSwing[hand] = t
    return hand
end

-- Is one of our weapons due to swing now? (for misses, which raise no threat)
local function SwingDue(t)
    if not Attacking(t) then return false end
    local mh, oh = UnitAttackSpeed("player")
    if IsSecret(mh) then return true end
    for hand, speed in pairs({ main = mh, off = (not IsSecret(oh)) and oh or nil }) do
        if speed and t >= lastSwing[hand] + speed - SWING_TOLERANCE then
            lastSwing[hand] = t
            return true
        end
    end
    return false
end

-- Decide what caused a hit. Returns a table:
--   icon, color, label
--   certain  - so clearly ours (timing, school and usual amount all match) that
--              it can be shown without waiting for the threat check
--   likely   - plausibly ours; only used for a killing blow, whose threat is never seen
--   key      - which learned amount this kind of hit updates once confirmed
--   cast     - the cast this hit is credited to, marked used once it's shown
--   melee    - a white hit (its weapon icon is picked when it's shown)
local function Attribute(unit, school, amount, isCrit, now)
    local physical = school == SCHOOL_PHYSICAL
    -- damage without the crit bonus, for comparing with what this source usually does
    local base = not IsSecret(amount) and amount > 0 and (isCrit and amount / 1.5 or amount) or nil

    -- 1. the spell we just cast (once per mob, matching school). Instant
    -- spells land the moment they're cast, so a hit right then is certain.
    if lastCast and now - lastCast.time <= CAST_WINDOW and not lastCast.credited[unit]
        and (lastCast.school == nil or lastCast.school == school) then
        if not physical then schoolSpell[school] = lastCast.spellID end
        return { icon = GetIcon(lastCast.spellID), color = COLOR_SPELL, cast = lastCast, likely = true,
                 certain = lastCast.school ~= nil and now - lastCast.time <= INSTANT_WINDOW
                     and FitsSpellRange(lastCast.spellID, school, base),
                 label = "cast " .. SpellName(lastCast.spellID) }
    end

    -- 2. a spell we're channelling
    if channel and now <= channel.endTime + CHANNEL_GRACE and (channel.school == nil or channel.school == school) then
        local key = "channel:" .. channel.spellID
        return { icon = GetIcon(channel.spellID), color = COLOR_SPELL, key = key, likely = true,
                 certain = MatchesLearned(key, base), label = "channel " .. SpellName(channel.spellID) }
    end

    -- 3. a DoT tick or a weapon proc; if both fit, the usual amounts decide
    local dot = DotTicking(school, now)
    local proc = not physical and Attacking(now) and weaponProcs[school]
    if dot and proc and Closer(base, learned["proc:" .. school], learned["tick:" .. dot]) then
        dot = nil
    end
    if dot then
        local key = "tick:" .. dot
        return { icon = GetIcon(dot), color = COLOR_SPELL, key = key, likely = true,
                 certain = MatchesLearned(key, base), label = "dot " .. SpellName(dot) }
    end
    if proc then
        local key = "proc:" .. school
        return { icon = proc, color = COLOR_SPELL, key = key, likely = true,
                 certain = MatchesLearned(key, base) and FitsProcTiming(now), label = "weapon proc" }
    end

    -- 4. a white hit: only ever ours on our target, and always threat-checked
    if physical then
        return { icon = GetIcon(AUTO_ATTACK_ID), color = COLOR_MELEE, melee = true,
                 likely = unit == "target" and Attacking(now), label = "melee" }
    end

    -- 5. a damage shield, which only fires when the mob hits us
    if shields[school] then
        local ok, onMe = pcall(UnitIsUnit, unit .. "target", "player")
        onMe = not ok or IsSecret(onMe) or onMe
        local key = "shield:" .. school
        return { icon = shields[school], color = COLOR_SPELL, key = key, likely = onMe,
                 certain = onMe and MatchesLearned(key, base), label = "shield" }
    end

    -- 6. unknown magic damage: only shown if threat proves it's ours
    local spellID = schoolSpell[school]
    return { icon = GetIcon(spellID or AUTO_ATTACK_ID), color = COLOR_SPELL,
             label = "unknown, guessed " .. tostring(spellID) }
end

---------------------------------------------------------------------------
-- Showing a hit
---------------------------------------------------------------------------
local function Display(hit)
    if hit.shown then return end
    hit.shown = true
    if hit.cast then hit.cast.credited[hit.unit] = true end
    if hit.melee and hit.landed then
        local hand = AssignHand(hit.time)
        hit.icon = GetInventoryItemTexture("player", hand == "off" and 17 or 16) or hit.icon
    end
    ShowHit(hit.anchor, hit.amount, hit.icon, hit.color, hit.isCrit, hit.suffix)
end

-- A hit our threat proved is ours: remember its amount for next time.
-- Crits and partial (resisted...) hits aren't typical, so they're not learned.
local function Learn(hit)
    if hit.key and hit.base and not hit.isCrit and not hit.suffix then
        learned[hit.key] = hit.base
    end
end

---------------------------------------------------------------------------
-- Ownership by threat (target only)
--
-- Only our own damage raises our threat. Hits on our target wait a moment for
-- our threat to rise; hits that never raise it aren't ours and are never shown.
---------------------------------------------------------------------------
local threat -- { value, credit, creditTime, hits = {} } for "target"

local function ReadThreat()
    local ok, _, _, _, _, value = pcall(UnitDetailedThreatSituation, "player", "target")
    if not ok or IsSecret(value) then return nil end
    return value or 0 -- nil means we're not on the mob's threat list yet
end

local function ResetThreat()
    local exists = UnitExists("target")
    local value = (IsSecret(exists) or exists) and ReadThreat()
    threat = value and { value = value, credit = 0, creditTime = 0, hits = {} } or nil
end

local function ProcessThreat(now)
    if not threat then return end
    local value = ReadThreat()
    if value then
        if value > threat.value then
            Debug("threat +" .. (value - threat.value))
            threat.credit = threat.credit + (value - threat.value)
            threat.creditTime = now
        end
        threat.value = value
    end

    -- Spend the rise on waiting hits, oldest first, letting the hits most likely
    -- to be ours claim it first. Melee hits are reported after their threat
    -- arrives, so leftover rise is kept for a moment.
    for _, pass in ipairs({ true, false }) do
        for _, hit in ipairs(threat.hits) do
            local secret = IsSecret(hit.amount)
            if not hit.done and (hit.likely or false) == pass and threat.credit > 0
                and (secret or threat.credit >= hit.amount * MIN_THREAT_PER_DAMAGE) then
                Debug("confirmed", hit.label, string.format("after %.2fs", now - hit.time))
                hit.done = true
                Learn(hit)
                Display(hit)
                threat.credit = secret and 0 or math.max(0, threat.credit - hit.amount)
            end
        end
    end

    -- A dead mob's threat list is wiped, so the killing blow (and any hit still
    -- waiting) will never see a rise. Decide those straight away by their timing.
    local dead = UnitIsDead("target")
    dead = not IsSecret(dead) and dead

    local waiting = {}
    for _, hit in ipairs(threat.hits) do
        if hit.done then
            -- confirmed above
        elseif dead then
            -- a white hit only counts if one of our weapons was due to swing
            local ours = hit.likely and (not hit.melee or SwingDue(hit.time))
            if not hit.shown and ours then
                Debug("shown", hit.label, "- killing blow")
                Display(hit)
            elseif not hit.shown then
                Debug("dropped", hit.label, "- mob died, not ours")
            end
        elseif now - hit.time > THREAT_WAIT then
            if not hit.shown then
                Debug("dropped", hit.label, "- threat didn't rise, not ours")
            end
        else
            table.insert(waiting, hit)
        end
    end
    threat.hits = waiting

    if now - threat.creditTime > CREDIT_KEEP then threat.credit = 0 end
end

-- Our target's nameplate, remembered so hits reported just after it was hidden
-- (the late killing swing) can still be attached to it, where the mob died.
local lastTargetPlate, lastTargetPlateTime = nil, 0

local threatFrame = CreateFrame("Frame")
threatFrame:SetScript("OnUpdate", function()
    local now = GetTime()
    local plate = C_NamePlate.GetNamePlateForUnit("target")
    if plate then
        lastTargetPlate, lastTargetPlateTime = plate, now
    end
    ProcessThreat(now)
end)

---------------------------------------------------------------------------
-- Hits on enemies
---------------------------------------------------------------------------
-- Avoided or fully blocked hits (UNIT_COMBAT action -> text shown instead of a number)
local AVOID_TEXT = {
    MISS    = MISS or "Miss",
    DODGE   = DODGE or "Dodge",
    PARRY   = PARRY or "Parry",
    BLOCK   = BLOCK or "Block",
    DEFLECT = DEFLECT or "Deflect",
    IMMUNE  = IMMUNE or "Immune",
    EVADE   = EVADE or "Evade",
    RESIST  = RESIST or "Resist",
    ABSORB  = ABSORB or "Absorb",
    REFLECT = REFLECT or "Reflect",
}

-- Partial results on a hit that landed, matched against the UNIT_COMBAT flags
local HIT_SUFFIXES = {
    { flag = "BLOCK",    text = "(blocked)" },
    { flag = "RESIST",   text = "(resisted)" },
    { flag = "ABSORB",   text = "(absorbed)" },
    { flag = "GLANCING", text = "(glancing)" },
    { flag = "CRUSHING", text = "(crushing)" },
}

local function OnEnemyHit(unit, action, flags, amount, school)
    if IsSecret(action) or (action ~= "WOUND" and not AVOID_TEXT[action]) then return end
    if action ~= "WOUND" and not db.showAvoids then return end
    -- Next-swing abilities (Maul, Heroic Strike, Raptor Strike...) report an
    -- empty 0 "wound" the moment they fire, before the real hit. Left in, it
    -- takes the cast's credit and shows up as a 0 with the spell's icon, and
    -- the real hit then loses its icon. Must run before Attribute().
    -- Thanks to the CurseForge commenter who tracked this down.
    if action == "WOUND" and not IsSecret(amount) and (amount or 0) <= 0 then
        Debug("ignored", unit, "0 damage wound")
        return
    end
    if IsSecret(flags) then flags = nil end
    if IsSecret(school) or not school then school = SCHOOL_PHYSICAL end
    local now = GetTime()
    local hostile, dead = UnitCanAttack("player", unit), UnitIsDead(unit)
    if not IsSecret(hostile) and not hostile and not (not IsSecret(dead) and dead) then return end

    -- Every hit on our target fires twice: as "target" and as its nameplate.
    -- Use the "target" one, since that's the only unit we can read threat on.
    local anchor
    if unit == "target" then
        anchor = C_NamePlate.GetNamePlateForUnit("target")
        if not anchor and lastTargetPlate and orphaned[lastTargetPlate] and now - lastTargetPlateTime < 3 then
            anchor = lastTargetPlate -- its nameplate was just hidden (it died): stay where it was
        end
        anchor = anchor or TargetFrame
    else
        anchor = C_NamePlate.GetNamePlateForUnit(unit)
        if anchor and anchor == C_NamePlate.GetNamePlateForUnit("target") then
            return -- our target: handled by the "target" event
        end
    end
    if not anchor then return end

    local landed = action == "WOUND"
    local isCrit = landed and flags == "CRITICAL"
    local hit = Attribute(unit, school, landed and amount or 0, isCrit, now)
    hit.anchor, hit.unit, hit.time, hit.landed = anchor, unit, now, landed
    hit.label = hit.label .. " (" .. (landed and (IsSecret(amount) and "?" or amount) or action) .. ")"

    if not landed then
        -- misses raise no threat: a melee miss is ours if one of our weapons was
        -- due, a spell miss if it came the instant we cast
        hit.amount = AVOID_TEXT[action]
        if (hit.melee and unit == "target" and SwingDue(now)) or (hit.cast and hit.certain) then
            Debug("shown", hit.label, "- miss matches our swing or cast")
            Display(hit)
        else
            Debug("dropped", hit.label, "- miss not ours")
        end
        return
    end

    hit.amount = amount
    hit.isCrit = isCrit
    hit.base = not IsSecret(amount) and amount > 0 and (isCrit and amount / 1.5 or amount) or nil
    for _, s in ipairs(HIT_SUFFIXES) do
        if flags and flags:find(s.flag, 1, true) then
            hit.suffix = s.text
            break
        end
    end

    if hit.certain then
        Debug("shown", hit.label, "- certain")
        Display(hit)
    end
    if unit == "target" and threat then
        -- Everything on our target goes through the threat check: uncertain hits
        -- are shown once it confirms them, and certain ones still use up their
        -- share of the rise so it can't vouch for someone else's hit.
        table.insert(threat.hits, hit)
        ProcessThreat(now)
    elseif not hit.certain then
        Debug("dropped", hit.label, "- can't be confirmed as ours")
    end
end

---------------------------------------------------------------------------
-- Blizzard's own damage numbers
---------------------------------------------------------------------------
-- Forever uses the "_v2" names; the old one is kept in case a client still reads it.
local DAMAGE_CVARS = {
    "floatingCombatTextCombatDamage_v2",
    "floatingCombatTextCombatLogPeriodicSpells_v2",
    "floatingCombatTextPetMeleeDamage_v2",
    "floatingCombatTextPetSpellDamage_v2",
    "floatingCombatTextCombatDamage",
}

local function ApplyBlizzardSetting(verbose)
    if InCombatLockdown() then return end
    local want = db.hideBlizzard and "0" or "1"
    local setCVar = (C_CVar and C_CVar.SetCVar) or SetCVar
    local getCVar = (C_CVar and C_CVar.GetCVar) or GetCVar
    local changed, failed = 0, {}
    for _, name in ipairs(DAMAGE_CVARS) do
        if getCVar(name) ~= nil then -- skip CVars this client doesn't have
            pcall(setCVar, name, want)
            if getCVar(name) == want then
                changed = changed + 1
            else
                table.insert(failed, name)
            end
        end
    end
    if verbose or changed == 0 or #failed > 0 then
        print("|cffffcc00BetterDamageText:|r Blizzard damage numbers " .. (db.hideBlizzard and "hidden" or "shown") ..
            " (" .. changed .. " settings changed" .. (#failed > 0 and ", failed: " .. table.concat(failed, ", ") or "") .. ")")
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_REGEN_ENABLED") -- left combat: buffs and tooltips are readable again
ev:RegisterEvent("PLAYER_ENTER_COMBAT")  -- auto attack switched on
ev:RegisterEvent("PLAYER_LEAVE_COMBAT")  -- auto attack switched off
ev:RegisterEvent("PLAYER_TARGET_CHANGED")
ev:RegisterEvent("NAME_PLATE_UNIT_ADDED")
ev:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
ev:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
ev:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
ev:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
ev:RegisterUnitEvent("UNIT_AURA", "player")
ev:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player") -- fires when a weapon enchant is applied or fades
if not pcall(ev.RegisterEvent, ev, "UNIT_COMBAT") then
    print("|cffffcc00BetterDamageText:|r UNIT_COMBAT is blocked on this client; the addon can't see damage.")
end

ev:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON then return end
        BetterDamageTextDB = BetterDamageTextDB or {}
        db = BetterDamageTextDB
        for k in pairs(db) do
            if defaults[k] == nil then db[k] = nil end -- drop settings from older versions
        end
        for k, v in pairs(defaults) do
            if db[k] == nil or type(db[k]) ~= type(v) then
                db[k] = type(v) == "table" and CopyTable(v) or v
            end
        end
        ns.db = db
        BetterDamageTextLearned = BetterDamageTextLearned or {}
        learned = BetterDamageTextLearned
    elseif event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_REGEN_ENABLED" then
        -- re-applied on every load screen in case Blizzard's settings reset it
        ApplyBlizzardSetting()
        UpdateDamageShields()
        UpdateWeaponProcs()
        if not threat then ResetThreat() end
    elseif event == "UNIT_AURA" then
        UpdateDamageShields()
    elseif event == "UNIT_INVENTORY_CHANGED" then
        UpdateWeaponProcs()
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        ns.OnNamePlateRemoved(C_NamePlate.GetNamePlateForUnit(...))
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        ns.OnNamePlateAdded(C_NamePlate.GetNamePlateForUnit(...))
    elseif event == "PLAYER_TARGET_CHANGED" then
        ResetThreat()
    elseif event == "PLAYER_ENTER_COMBAT" then
        autoAttacking = true
    elseif event == "PLAYER_LEAVE_COMBAT" then
        autoAttacking = false
        autoAttackEnded = GetTime()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, _, spellID = ...
        OnCast(spellID)
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        local _, _, spellID = ...
        if not IsSecret(spellID) then
            local data = GetSpellData(spellID)
            channel = { spellID = spellID, school = data and data.school, endTime = math.huge }
        end
    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        if channel then channel.endTime = GetTime() end
    elseif event == "UNIT_COMBAT" then
        local unit, action, flags, amount, school = ...
        if unit == "player" then
            Debug("you took", action, flags, amount, "school", school)
        elseif unit == "target" or unit:match("^nameplate%d") then
            Debug(unit, action, flags, amount, "school", school)
            OnEnemyHit(unit, action, flags, amount, school)
        end
    end
end)

---------------------------------------------------------------------------
-- Used by the settings window (Options.lua)
---------------------------------------------------------------------------
ns.ApplyBlizzardSetting = ApplyBlizzardSetting

-- where previews appear when there's no target: a bit above the middle of the screen
local previewAnchor = CreateFrame("Frame", nil, UIParent)
previewAnchor:SetSize(1, 1)
previewAnchor:SetPoint("CENTER", UIParent, "CENTER", 0, 120)

-- Shows a few sample hits so changes can be seen straight away.
function ns.Preview()
    local anchor = C_NamePlate.GetNamePlateForUnit("target") or previewAnchor
    local samples = {
        { 34, AUTO_ATTACK_ID, COLOR_MELEE, false, "(glancing)" },
        { 21, 8042, COLOR_SPELL, false },   -- Earth Shock
        { 12, 8024, COLOR_SPELL, false },   -- Flametongue
        { 68, AUTO_ATTACK_ID, COLOR_MELEE, true },
        { db.showAvoids and AVOID_TEXT.PARRY, AUTO_ATTACK_ID, COLOR_MELEE, false },
    }
    for i, s in ipairs(samples) do
        if s[1] then
            C_Timer.After((i - 1) * 0.35, function()
                ShowHit(anchor, s[1], GetIcon(s[2]), s[3], s[4], s[5])
            end)
        end
    end
end

---------------------------------------------------------------------------
-- Slash commands: /bdt
---------------------------------------------------------------------------
local function Schools(t)
    local s = {}
    for school in pairs(t) do table.insert(s, school) end
    return #s > 0 and table.concat(s, ",") or "none"
end

SLASH_BETTERDAMAGETEXT1 = "/bdt"
SlashCmdList.BETTERDAMAGETEXT = function(msg)
    local cmd, val = msg:match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    if cmd == "" or cmd == "config" or cmd == "options" then
        ns.OpenOptions()
    elseif cmd == "blizzard" then
        db.hideBlizzard = not db.hideBlizzard
        ApplyBlizzardSetting(true)
    elseif cmd == "debug" then
        debugMode = not debugMode
        UpdateDamageShields()
        UpdateWeaponProcs()
        print("BetterDamageText: debug " .. (debugMode and "on" or "off") ..
            ". Damage shields (school): " .. Schools(shields) .. ". Weapon enchants (school): " .. Schools(weaponProcs))
    elseif cmd == "record" then
        recording = not recording
        if recording then
            BetterDamageTextLog = {}
            local usual = {}
            for key, amount in pairs(learned) do table.insert(usual, key .. "=" .. amount) end
            Debug("start: shields", Schools(shields), "weapon procs", Schools(weaponProcs),
                "usual amounts", table.concat(usual, " "))
            print("BetterDamageText: recording. Fight for a bit, then type /bdt record again and /reload to save.")
        else
            print("BetterDamageText: stopped recording (" .. #BetterDamageTextLog .. " lines). /reload to save them to disk.")
        end
    elseif cmd == "test" then
        ns.Preview()
    elseif cmd == "minimap" then
        db.minimapButton = not db.minimapButton
        ns.UpdateMinimapButton()
        print("BetterDamageText: minimap button " .. (db.minimapButton and "shown" or "hidden") .. ".")
    elseif cmd == "feedback" or cmd == "bug" then
        print("BetterDamageText: report bugs and suggest ideas at " .. ns.FEEDBACK_URL)
        ns.ShowFeedback() -- opens the settings with the link selected, ready to copy
    else
        print("BetterDamageText commands:")
        print("  /bdt               - open the settings window")
        print("  /bdt test          - show some sample hits")
        print("  /bdt minimap       - show or hide the minimap button")
        print("  /bdt blizzard      - toggle Blizzard's own damage numbers")
        print("  /bdt debug         - print every hit and why it was shown or hidden")
        print("  /bdt record        - start/stop saving that output to disk (read after /reload)")
        print("  /bdt feedback      - where to report bugs and suggest ideas")
    end
end
