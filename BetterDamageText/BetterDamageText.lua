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
-- Timing facts measured in game (Forever 1.60.1), which the rules below rely on:
--   * spell damage is reported the moment it happens
--   * melee hits (ours and the mob's on us) are reported ~0.3-0.8s late, to
--     line up with the swing animation, so a Flametongue proc or Lightning
--     Shield zap arrives BEFORE the swing that caused it
--   * DoTs tick exactly every 3s after the cast
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
    duration     = 1.4,        -- seconds a number stays on screen
    rise         = 70,         -- pixels the number floats upward
    colorMelee   = { 1, 1, 1 },
    colorSpell   = { 1, 0.85, 0.1 },
    showAvoids   = true,       -- show Miss / Dodge / Parry...
    showSuffixes = true,       -- show "(blocked)", "(glancing)"...
    hideBlizzard = true,       -- turn off the default floating damage numbers
    onlyMine     = true,       -- hide other players' and pets' hits
    instant      = true,       -- show hits that clearly match our actions without waiting for threat
}
ns.defaults = defaults

local AUTO_ATTACK_ID = 6603

local CAST_WINDOW     = 1.5  -- a cast is credited with the first matching hit within this many seconds
local CHANNEL_GRACE   = 0.3  -- a channel's last tick can land just after it ends
local TICK_INTERVAL   = 3    -- seconds between DoT ticks
local TICK_TOLERANCE  = 0.25
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

local function Position(f)
    local p = f.elapsed / db.duration
    local scale = f:GetScale()
    -- offsets are in the frame's own (scaled) units, so divide to keep them in screen pixels
    f:SetPoint("BOTTOM", f.anchor, "TOP", f.xOffset / scale, (db.rise * p + f.push) / scale)
end

local function ShowHit(anchor, amount, icon, color, isCrit, suffix)
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

    f.icon:SetTexture(icon or GetIcon(AUTO_ATTACK_ID))
    f.text:SetText(amount)  -- SetText accepts secret numbers
    f.text:SetTextColor(unpack(db[color]))
    f.suffix:SetText(db.showSuffixes and suffix or "")
    f.suffix:SetTextColor(unpack(db[color]))

    f:SetScale(isCrit and db.critPop or 1)
    f:SetAlpha(1)
    Position(f)
    f:Show()
    active[f] = true
end

local animator = CreateFrame("Frame")
animator:SetScript("OnUpdate", function(_, elapsed)
    for f in pairs(active) do
        f.elapsed = f.elapsed + elapsed
        local p = f.elapsed / db.duration
        if p >= 1 or not f.anchor:IsShown() then
            Release(f)
        else
            if f.isCrit then
                -- Blizzard-style pop: start huge, snap down to crit size
                local t = math.min(f.elapsed / CRIT_POP_TIME, 1)
                f:SetScale(db.critPop + (db.critScale - db.critPop) * t)
            end
            -- glide toward the pushed-up position instead of jumping
            f.push = f.push + (f.pushTarget - f.push) * math.min(elapsed * 15, 1)
            Position(f)
            -- stay fully visible for the first half, then fade out
            f:SetAlpha(p < 0.5 and 1 or (1 - p) * 2)
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
local dots = {}         -- spellID -> { school, duration, times = { cast times } }
local schoolSpell = {}  -- school -> last spell of ours that hit with it (fallback icon)
local procAmount = {}   -- school -> last weapon proc damage (tells procs from DoT ticks)
local tickAmount = {}   -- spellID -> last DoT tick damage
local autoAttacking = false
local lastMainHandSwing, lastOffHandSwing = 0, 0

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
        local d = dots[spellID] or { school = data.school, duration = data.dot, times = {} }
        dots[spellID] = d
        -- forget casts whose DoT has run out
        for i = #d.times, 1, -1 do
            if now - d.times[i] > d.duration + 1 then table.remove(d.times, i) end
        end
        table.insert(d.times, now)
    end
end

-- Is `now` exactly on one of this DoT's 3-second ticks?
local function DotTicking(school, now)
    for spellID, d in pairs(dots) do
        if d.school == school then
            for _, t in ipairs(d.times) do
                local dt = now - t
                if dt > TICK_INTERVAL - TICK_TOLERANCE and dt < d.duration + TICK_TOLERANCE then
                    local phase = dt % TICK_INTERVAL
                    if phase < TICK_TOLERANCE or phase > TICK_INTERVAL - TICK_TOLERANCE then
                        return spellID
                    end
                end
            end
        end
    end
end

-- Our white swings land on a fixed rhythm (weapon speed). Only used when
-- threat can't be read: a physical hit before our weapon is ready isn't ours.
local function FitsSwingTimer(now)
    if not autoAttacking then return false end
    local mh, oh = UnitAttackSpeed("player")
    if not mh or IsSecret(mh) then return true end
    if now >= lastMainHandSwing + mh - SWING_TOLERANCE then
        lastMainHandSwing = now
        return true
    end
    if oh and not IsSecret(oh) and now >= lastOffHandSwing + oh - SWING_TOLERANCE then
        lastOffHandSwing = now
        return true
    end
    return false
end

-- true only if `amount` is clearly closer to a than to b; with either unknown, false
local function Closer(amount, a, b)
    if not amount or not a or not b then return false end
    return math.abs(amount - a) < math.abs(amount - b)
end

-- Decide which of our spells caused a hit. Returns icon, color, mine, label;
-- `mine` is our best guess at ownership, used when threat can't tell us.
local function Attribute(unit, school, amount, isCrit, now)
    local physical = school == SCHOOL_PHYSICAL
    -- damage without the crit bonus, for comparing with earlier hits
    local base = not IsSecret(amount) and amount > 0 and (isCrit and amount / 1.5 or amount) or nil

    -- 1. the spell we just cast (once per mob, matching school)
    if lastCast and now - lastCast.time <= CAST_WINDOW and not lastCast.credited[unit]
        and (lastCast.school == nil or lastCast.school == school) then
        lastCast.credited[unit] = true
        if not physical then schoolSpell[school] = lastCast.spellID end
        return GetIcon(lastCast.spellID), COLOR_SPELL, true, "cast " .. SpellName(lastCast.spellID)
    end

    -- 2. a spell we're channelling
    if channel and now <= channel.endTime + CHANNEL_GRACE and (channel.school == nil or channel.school == school) then
        return GetIcon(channel.spellID), COLOR_SPELL, true, "channel " .. SpellName(channel.spellID)
    end

    -- 3. a DoT tick or a weapon proc. If both fit, compare with the damage each
    -- did last time; amounts are only learned when there was no doubt.
    local dot = DotTicking(school, now)
    local proc = not physical and autoAttacking and weaponProcs[school]
    local learn = base and not (dot and proc)
    if dot and proc and Closer(base, procAmount[school], tickAmount[dot]) then
        dot = nil
    end
    if dot then
        if learn then tickAmount[dot] = base end
        return GetIcon(dot), COLOR_SPELL, true, "dot " .. SpellName(dot)
    end
    if proc then
        if learn then procAmount[school] = base end
        return proc, COLOR_SPELL, true, "weapon proc"
    end

    if physical then
        return GetIcon(AUTO_ATTACK_ID), COLOR_MELEE, FitsSwingTimer(now), "melee"
    end

    -- 4. magic damage nothing else explains: a damage shield, if one is up
    if shields[school] then
        -- a shield only fires when the mob hits us, so it's only clearly ours if
        -- the mob is attacking us (unknown counts as yes)
        local ok, onMe = pcall(UnitIsUnit, unit .. "target", "player")
        local mine = not ok or IsSecret(onMe) or onMe
        return shields[school], COLOR_SPELL, mine, "shield"
    end

    -- 5. unknown: guess the spell of ours that last hit with this school
    local spellID = schoolSpell[school]
    return GetIcon(spellID or AUTO_ATTACK_ID), COLOR_SPELL, false, "unknown, guessed " .. tostring(spellID)
end

---------------------------------------------------------------------------
-- Ownership by threat (target only)
--
-- Only our own damage raises our threat. Hits on our target wait a moment for
-- our threat to rise; hits that never raise it were someone else's.
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

local function Display(hit)
    if hit.shown then return end -- already shown in instant mode
    hit.shown = true
    if hit.anchor:IsShown() then
        ShowHit(hit.anchor, hit.amount, hit.icon, hit.color, hit.isCrit, hit.suffix)
    end
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

    -- Spend the rise on waiting hits, oldest first, letting hits that fit our
    -- own pattern (hit.mine) claim it before anyone else's. Melee hits are
    -- reported after their threat arrives, so leftover rise is kept for a moment.
    for _, pass in ipairs({ true, false }) do
        for _, hit in ipairs(threat.hits) do
            local secret = IsSecret(hit.amount)
            if not hit.done and (hit.mine or false) == pass and threat.credit > 0
                and (secret or threat.credit >= hit.amount * MIN_THREAT_PER_DAMAGE) then
                Debug("confirmed", hit.label, string.format("after %.2fs", now - hit.time))
                Display(hit)
                hit.done = true
                threat.credit = secret and 0 or math.max(0, threat.credit - hit.amount)
            end
        end
    end

    local waiting = {}
    for _, hit in ipairs(threat.hits) do
        if hit.done then
            -- shown above
        elseif now - hit.time > THREAT_WAIT then
            -- a dead mob's threat list is wiped, so a killing blow never shows a rise
            local dead = UnitIsDead("target")
            if hit.shown then
                Debug("shown instantly but threat didn't rise:", hit.label, "- probably someone else's")
            elseif hit.mine and not IsSecret(dead) and dead then
                Debug("shown", hit.label, "- killing blow, judged by timing")
                Display(hit)
            else
                Debug("dropped", hit.label, "- threat didn't rise")
            end
        else
            table.insert(waiting, hit)
        end
    end
    threat.hits = waiting

    if now - threat.creditTime > CREDIT_KEEP then threat.credit = 0 end
end

local threatFrame = CreateFrame("Frame")
threatFrame:SetScript("OnUpdate", function()
    ProcessThreat(GetTime())
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
    if IsSecret(flags) then flags = nil end
    if IsSecret(school) or not school then school = SCHOOL_PHYSICAL end
    local hostile = UnitCanAttack("player", unit)
    if not IsSecret(hostile) and not hostile then return end

    -- Every hit on our target fires twice: as "target" and as its nameplate.
    -- Use the "target" one, since that's the only unit we can read threat on.
    local anchor
    if unit == "target" then
        anchor = C_NamePlate.GetNamePlateForUnit("target") or TargetFrame
    else
        anchor = C_NamePlate.GetNamePlateForUnit(unit)
        if anchor and anchor == C_NamePlate.GetNamePlateForUnit("target") then
            return -- our target: handled by the "target" event
        end
    end
    if not anchor then return end

    local now = GetTime()
    local landed = action == "WOUND"
    local isCrit = landed and flags == "CRITICAL"
    local icon, color, mine, label = Attribute(unit, school, landed and amount or 0, isCrit, now)

    local hit = { anchor = anchor, icon = icon, color = color, time = now, mine = mine,
                  label = label .. " (" .. (landed and (IsSecret(amount) and "?" or amount) or action) .. ")" }
    if landed then
        hit.amount = amount
        hit.isCrit = isCrit
        for _, s in ipairs(HIT_SUFFIXES) do
            if flags and flags:find(s.flag, 1, true) then
                hit.suffix = s.text
                break
            end
        end
    else
        hit.amount = AVOID_TEXT[action]
    end

    if not db.onlyMine then
        Debug("shown", hit.label, "- filter off")
        Display(hit)
    elseif landed and unit == "target" and threat then
        if db.instant and mine then
            -- clearly ours: show now; it still goes through the threat check
            -- so its threat rise isn't credited to someone else's hit
            Debug("shown", hit.label, "- instant")
            Display(hit)
        end
        table.insert(threat.hits, hit)
        ProcessThreat(now) -- the threat may already have risen this frame
    elseif mine then
        -- misses cause no threat, and other mobs' threat can't be read: go by timing
        Debug("shown", hit.label, "- by timing")
        Display(hit)
    else
        Debug("dropped", hit.label, "- by timing")
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
    elseif event == "PLAYER_TARGET_CHANGED" then
        ResetThreat()
    elseif event == "PLAYER_ENTER_COMBAT" then
        autoAttacking = true
    elseif event == "PLAYER_LEAVE_COMBAT" then
        autoAttacking = false
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
    elseif cmd == "mine" then
        if val == "on" then
            db.onlyMine = true
        elseif val == "off" then
            db.onlyMine = false
        end
        print("BetterDamageText: " .. (db.onlyMine and "only showing your own hits" or "showing everyone's hits") ..
            ". Use /bdt mine on or /bdt mine off to change.")
    elseif cmd == "blizzard" then
        db.hideBlizzard = not db.hideBlizzard
        ApplyBlizzardSetting(true)
    elseif cmd == "debug" then
        debugMode = not debugMode
        UpdateDamageShields()
        UpdateWeaponProcs()
        print("BetterDamageText: debug " .. (debugMode and "on" or "off") ..
            ". Only your hits: " .. (db.onlyMine and "on" or "off") ..
            ". Damage shields (school): " .. Schools(shields) .. ". Weapon enchants (school): " .. Schools(weaponProcs))
    elseif cmd == "record" then
        recording = not recording
        if recording then
            BetterDamageTextLog = {}
            Debug("start: onlyMine", db.onlyMine, "shields", Schools(shields), "weapon procs", Schools(weaponProcs))
            print("BetterDamageText: recording. Fight for a bit, then type /bdt record again and /reload to save.")
        else
            print("BetterDamageText: stopped recording (" .. #BetterDamageTextLog .. " lines). /reload to save them to disk.")
        end
    elseif cmd == "test" then
        ns.Preview()
    else
        print("BetterDamageText commands:")
        print("  /bdt               - open the settings window")
        print("  /bdt test          - show some sample hits")
        print("  /bdt mine on|off   - hide other players' hits (now " .. (db.onlyMine and "on" or "off") .. ")")
        print("  /bdt blizzard      - toggle Blizzard's own damage numbers")
        print("  /bdt debug         - print every hit and why it was shown or hidden")
        print("  /bdt record        - start/stop saving that output to disk (read after /reload)")
    end
end
