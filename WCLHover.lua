-- WCLHover: shows a copyable Warcraft Logs character URL for the player you
-- hover in the group finder.
--
-- Flow:
--   1. Hover an LFG player.
--   2. Hold CTRL → a popup opens with the URL pre-selected.
--   3. Press C (while still holding Ctrl) → OS-native Ctrl+C copies the URL.
--   4. Popup auto-dismisses; wcl_checker.py overlay fires from the clipboard.

local DEFAULT_ZONE = 47  -- current M+ season zone id on warcraftlogs.com

BINDING_HEADER_WCLHOVER = "WCL Hover"
_G["BINDING_NAME_WCLHOVER_SHOW"]   = "Copy WCL URL for hovered LFG player"
_G["BINDING_NAME_WCLHOVER_TARGET"] = "Copy WCL URL for current target"

local REGION_MAP = { [1] = "us", [2] = "kr", [3] = "eu", [4] = "tw", [5] = "cn" }

local function currentRegion()
    return REGION_MAP[GetCurrentRegion and GetCurrentRegion()] or "us"
end

-- WCL realm slugs drop spaces/apostrophes/hyphens (e.g. "Twisting Nether"
-- -> "twistingnether", "Kil'jaeden" -> "kiljaeden").
local function realmSlug(realm)
    if not realm or realm == "" then
        realm = GetNormalizedRealmName() or GetRealmName() or ""
    end
    return (realm:lower():gsub("[^a-z0-9]", ""))
end

local function buildUrl(name, realm, region)
    if not name or name == "" then return nil end
    region = region or currentRegion()
    return string.format(
        "https://www.warcraftlogs.com/character/%s/%s/%s?zone=%d",
        region, realmSlug(realm), name:lower(), DEFAULT_ZONE
    )
end

local function splitName(full)
    if not full or full == "" then return nil end
    local name, realm = full:match("^([^%-]+)%-?(.*)$")
    if not name or name == "" then return nil end
    if realm == "" then realm = nil end
    return name, realm
end

local function chatPrint(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff40C4FF[WCL]|r " .. tostring(msg))
end

-- Static popup --------------------------------------------------------------

-- Popup stays open while Ctrl is held. On Ctrl release (handled below) or
-- Ctrl+C we dismiss it. Esc also closes via hideOnEscape.
StaticPopupDialogs["WCL_HOVER_COPY_URL"] = {
    text = "Ctrl+C  —  %s",
    button1 = CLOSE,
    hasEditBox = true,
    editBoxWidth = 480,
    OnShow = function(self, data)
        local url = (type(data) == "table" and data.url) or ""
        local editBox = self.editBox or _G[self:GetName() .. "EditBox"]
        if editBox then
            editBox:SetText(url)
            editBox:HighlightText()
            editBox:SetFocus()
            editBox:SetScript("OnKeyDown", function(box, key)
                if key == "C" and IsControlKeyDown() then
                    C_Timer.After(0.02, function()
                        local parent = box:GetParent()
                        if parent then parent:Hide() end
                    end)
                end
            end)
        end
    end,
    OnHide = function(self)
        local editBox = self.editBox or _G[self:GetName() .. "EditBox"]
        if editBox then editBox:SetScript("OnKeyDown", nil) end
    end,
    EditBoxOnEnterPressed  = function(self) self:GetParent():Hide() end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    OnAccept = function() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local POPUP_KEY = "WCL_HOVER_COPY_URL"

local function showPopup(name, realm, region)
    local url = buildUrl(name, realm, region)
    if not url then
        chatPrint("No name to build URL from (try /wcl status).")
        return
    end
    local label = name .. (realm and ("-" .. realm) or "")
    StaticPopup_Hide(POPUP_KEY)
    StaticPopup_Show(POPUP_KEY, label, nil, { url = url })
end

local function hidePopup()
    StaticPopup_Hide(POPUP_KEY)
end

-- Hover state ---------------------------------------------------------------

local lastHovered  -- { name, realm, region, key, source } — survives mouseoff for /wcl
local hoveringLFG = false  -- true only while GameTooltip currently targets an LFG frame
local activePopupKey  -- debounce: only re-open popup once per distinct hover

local function setHovered(name, realm, ctxKey, source)
    if not name or name == "" then return end
    lastHovered = {
        name   = name,
        realm  = realm,
        region = currentRegion(),
        key    = ctxKey,
        source = source,
    }
end

-- Walk up the tooltip owner's parent chain looking for an LFG result or
-- applicant member frame.
local function detectLFGOwner(owner)
    if not owner then return end
    local f = owner
    for _ = 1, 10 do
        if not f then return end
        if f.resultID then
            local info = C_LFGList.GetSearchResultInfo(f.resultID)
            if type(info) == "table" and info.leaderName then
                local n, r = splitName(info.leaderName)
                return n, r, "R:" .. tostring(f.resultID), "search-result"
            end
        end
        if f.memberIdx then
            local parent = f:GetParent()
            if parent and parent.applicantID then
                local full = C_LFGList.GetApplicantMemberInfo(parent.applicantID, f.memberIdx)
                if full and full ~= "" then
                    local n, r = splitName(full)
                    return n, r, "A:" .. parent.applicantID .. ":" .. f.memberIdx, "applicant-member"
                end
            end
        end
        if f.applicantID and f.Members then
            local full = C_LFGList.GetApplicantMemberInfo(f.applicantID, 1)
            if full and full ~= "" then
                local n, r = splitName(full)
                return n, r, "A:" .. f.applicantID .. ":1", "applicant-row"
            end
        end
        f = f:GetParent()
    end
end

-- Search panel — fires when you hover a group row in the browser.
if LFGListUtil_SetSearchEntryTooltip then
    hooksecurefunc("LFGListUtil_SetSearchEntryTooltip", function(tooltip, resultID)
        if not resultID then return end
        local info = C_LFGList.GetSearchResultInfo(resultID)
        if type(info) == "table" and info.leaderName then
            local n, r = splitName(info.leaderName)
            setHovered(n, r, "R:" .. tostring(resultID), "search-entry-hook")
            hoveringLFG = true
        end
    end)
end

-- Generic fallback via GameTooltip OnShow — covers applicant-viewer members
-- and anything else parented to an LFG frame. On non-LFG tooltips we clear
-- `hoveringLFG` so Ctrl doesn't trigger a stale popup.
GameTooltip:HookScript("OnShow", function(self)
    local n, r, key, src = detectLFGOwner(self:GetOwner())
    if n then
        setHovered(n, r, key, src)
        hoveringLFG = true
    else
        hoveringLFG = false
    end
end)

GameTooltip:HookScript("OnHide", function()
    -- Close popup when tooltip goes away. lastHovered is preserved so /wcl
    -- and the binding still work after you move the mouse away.
    hoveringLFG = false
    activePopupKey = nil
    hidePopup()
end)

-- Ctrl-triggered popup ------------------------------------------------------

local function tryOpenForCtrl()
    -- Only fire while actively hovering an LFG row; lastHovered alone would
    -- let Ctrl pop up stale data while you're over a different frame.
    if not hoveringLFG then return end
    if not lastHovered then return end
    if activePopupKey == lastHovered.key then return end
    activePopupKey = lastHovered.key
    showPopup(lastHovered.name, lastHovered.realm, lastHovered.region)
end

local triggerFrame = CreateFrame("Frame")
triggerFrame:RegisterEvent("MODIFIER_STATE_CHANGED")
triggerFrame:SetScript("OnEvent", function(_, event, key, state)
    if event ~= "MODIFIER_STATE_CHANGED" then return end
    if key ~= "LCTRL" and key ~= "RCTRL" then return end
    if state == 1 then
        tryOpenForCtrl()
    else
        -- Ctrl released → close popup and allow re-open next time Ctrl is
        -- held on the same hover.
        if not (IsControlKeyDown and IsControlKeyDown()) then
            activePopupKey = nil
            hidePopup()
        end
    end
end)

-- Also catch the case where Ctrl is already held when the tooltip first shows.
GameTooltip:HookScript("OnShow", function()
    if IsControlKeyDown and IsControlKeyDown() then tryOpenForCtrl() end
end)

-- Binding entry points ------------------------------------------------------

function WCLHover_ShowHovered()
    if not lastHovered then
        chatPrint("Hover an LFG player first (or /wcl <Name-Realm>).")
        return
    end
    showPopup(lastHovered.name, lastHovered.realm, lastHovered.region)
end

function WCLHover_ShowTarget()
    local n, r = UnitName("target")
    if not n or n == UNKNOWNOBJECT then
        chatPrint("No target.")
        return
    end
    showPopup(n, r)
end

-- Screen-grid roster broadcast ---------------------------------------------
--
-- Builds a "WCL:" payload containing every applicant + every search-result
-- leader and renders it with WCLScreenGrid, which draws a block of colored
-- cells at TOPLEFT UIParent. The external Python tool reads those cells and
-- fetches parses for each name.
--
-- Grid auto-shows whenever the Group Finder UI is open and auto-hides
-- otherwise — no manual toggle needed.


-- Some Blizzard builds return GetSearchResults as (number, table); others
-- return just the array. Normalise.
local function getSearchResultIDs()
    if not (C_LFGList and C_LFGList.GetSearchResults) then return {} end
    local a, b = C_LFGList.GetSearchResults()
    if type(a) == "table" then return a end
    if type(b) == "table" then return b end
    return {}
end

local function getApplicantIDs()
    if not (C_LFGList and C_LFGList.GetApplicants) then return {} end
    local a = C_LFGList.GetApplicants()
    return type(a) == "table" and a or {}
end

-- Entry format:
--   region|name|realm|CLASS|APPLICANTID|DUNGEONSCORE|TARGETKEY|ROLE|ILVL
-- Role is "TANK" / "HEALER" / "DAMAGER" (Blizzard's tokens) — used by the
-- overlay to draw a small coloured role glyph next to the name.
local function makeEntry(region, name, realm, classFile, applicantID,
                         score, targetKey, role, itemLevel)
    if not realm or realm == "" then
        realm = GetNormalizedRealmName() or GetRealmName() or ""
    end
    realm = realm:gsub("[%s%-']", "")
    return region .. "|" .. name .. "|" .. realm
        .. "|" .. (classFile or "")
        .. "|" .. (applicantID and tostring(applicantID) or "")
        .. "|" .. (score and tostring(math.floor(score)) or "")
        .. "|" .. (targetKey and tostring(targetKey) or "")
        .. "|" .. (role or "")
        .. "|" .. (itemLevel and tostring(math.floor(itemLevel)) or "")
end

-- Detect the target keystone level for colouring the overlay's +N cells.
-- Blizzard compresses "+13" in listing names/comments into an opaque
-- |Kc…|k escape (the chat client renders it back to [+13] at display
-- time, but the Lua string bytes are just the escape), so regexing the
-- title never works. The reliable path is the player's owned keystone
-- level, which is what people normally list for.
local function detectListingTargetKey()
    if C_MythicPlus and C_MythicPlus.GetOwnedKeystoneLevel then
        local n = C_MythicPlus.GetOwnedKeystoneLevel()
        if type(n) == "number" and n > 0 then return n end
    end
    return nil
end

-- Player's selected role for the active LFG queue: "TANK" / "HEALER" /
-- "DAMAGER" / "NONE". Lets the overlay pre-fill the leader's slot in
-- the M+ composition strip without making them click it manually.
local function playerLfgRole()
    local r = UnitGroupRolesAssigned and UnitGroupRolesAssigned("player")
    if r == "TANK" or r == "HEALER" or r == "DAMAGER" then return r end
    return nil
end

-- Comma-joined roles of every current party member, pulled directly
-- from WoW's API. Used to drive the overlay's title-bar slot
-- indicators so the M+ composition strip reflects WoW reality instead
-- of stale accept-click bookkeeping. Returns nil when the player is
-- not in a group (overlay clears synthesized party entries on its own
-- in that case).
local function partyRolesString()
    if not IsInGroup or not IsInGroup() then return nil end
    local roles = {}
    local pr = UnitGroupRolesAssigned and UnitGroupRolesAssigned("player")
    if pr == "TANK" or pr == "HEALER" or pr == "DAMAGER" then
        roles[#roles + 1] = pr
    end
    local total = (GetNumGroupMembers and GetNumGroupMembers()) or 0
    for i = 1, math.max(0, total - 1) do
        local unit = "party" .. i
        if UnitExists and UnitExists(unit) then
            local r = UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit)
            if r == "TANK" or r == "HEALER" or r == "DAMAGER" then
                roles[#roles + 1] = r
            end
        end
    end
    return table.concat(roles, ",")
end

-- Whether the player is the group leader (or solo). Only leaders can
-- act on LFG applicants, so the overlay greys out the ✓/✕ buttons when
-- this is false.
local function playerIsLeader()
    if not IsInGroup or not IsInGroup() then return true end
    return UnitIsGroupLeader and UnitIsGroupLeader("player") or false
end

-- True iff a given LFG activityID belongs to the M+ or current-raid
-- categories. We use the activity info's `isMythicPlusActivity` and
-- `isCurrentRaidActivity` flags so we don't have to hard-code category
-- IDs (Blizzard reshuffles those across patches).
local function isPvEActivity(activityID)
    if not (C_LFGList and C_LFGList.GetActivityInfoTable) then return false end
    local info = C_LFGList.GetActivityInfoTable(activityID)
    if type(info) ~= "table" then return false end
    if info.isMythicPlusActivity then return true end
    if info.isCurrentRaidActivity then return true end
    -- Fallback: categoryID 3 has been the raid category for years.
    -- Keeps us correct on older / pre-tier raids that don't get the
    -- isCurrentRaidActivity flag.
    if info.categoryID == 3 then return true end
    return false
end

-- True iff the player's active LFG entry (their own listing) is a M+
-- key or a raid. Returns false for PvP entries, custom listings, etc.
-- The grid only emits in this case — when the user is browsing or
-- applying to *other* groups, we stay hidden.
local function activeEntryIsPvE()
    if not (C_LFGList and C_LFGList.GetActiveEntryInfo) then return false end
    local entry = C_LFGList.GetActiveEntryInfo()
    if type(entry) ~= "table" then return false end
    if entry.activityID and isPvEActivity(entry.activityID) then
        return true
    end
    -- Some client paths return activityIDs (array) instead of a single
    -- activityID. If any selected activity is PvE we treat the entry
    -- as PvE.
    if type(entry.activityIDs) == "table" then
        for _, aid in ipairs(entry.activityIDs) do
            if isPvEActivity(aid) then return true end
        end
    end
    return false
end

local function buildRosterPayload()
    -- Gate: emit the grid only when the user is leading their own
    -- PvE listing (M+ key or raid). Browsing the group finder /
    -- applying to other groups is intentionally excluded — the
    -- overlay is for evaluating *your* applicants, not for shopping
    -- around as one yourself.
    if not activeEntryIsPvE() then
        return nil
    end
    local applicants = getApplicantIDs()

    local region = currentRegion()
    local lines = {}
    local target = detectListingTargetKey()

    -- "LEADER|<ROLE>" sentinel entry, prepended so the overlay parser
    -- (which keys per-entry by parts[0] == region) treats it as a
    -- non-applicant directive. A 3+-field entry would be misread as a
    -- character row; the 2-field LEADER row is silently ignored by
    -- older overlays that don't know to look for it.
    local mine = playerLfgRole()
    if mine then
        lines[#lines + 1] = "LEADER|" .. mine
    end

    -- LEADER_STATUS sentinel: whether the user is the group leader.
    -- Overlay disables invite/decline buttons when this is "false".
    lines[#lines + 1] = "LEADER_STATUS|"
        .. (playerIsLeader() and "true" or "false")

    -- PARTY sentinel: real party composition from UnitGroupRolesAssigned.
    -- Source of truth for the M+ slot strip — replaces the older
    -- "infer from accept-clicks" heuristic that drifted out of sync.
    local partyRoles = partyRolesString()
    if partyRoles then
        lines[#lines + 1] = "PARTY|" .. partyRoles
    end

    -- Filter out applicants Blizzard keeps in GetApplicants() after they
    -- cancelled, were declined, or timed out — those IDs hang around
    -- until the listing closes, but their rows shouldn't stay in the
    -- overlay. We require BOTH applicationStatus and
    -- pendingApplicationStatus to be in an "active" state — when a
    -- player cancels, Blizzard sometimes flips the pending field first
    -- and the live one only catches up on the next refresh.
    -- Keep the native API order: C_LFGList.GetApplicants returns IDs
    -- in the order Blizzard's Applicant Viewer displays them.
    local function isActiveStatus(s)
        return s == nil or s == "" or s == "none"
            or s == "applied" or s == "invited"
    end
    for _, applicantID in ipairs(applicants) do
        local info = C_LFGList.GetApplicantInfo(applicantID)
        local active = info
            and isActiveStatus(info.applicationStatus)
            and isActiveStatus(info.pendingApplicationStatus)
        if active then
            local members = (info and info.numMembers) or 0
            for m = 1, members do
                -- Positional return: name, classFile, localizedClass, level,
                -- itemLevel, honorLevel, tank, healer, damage, assignedRole,
                -- relationship, dungeonScore (= in-game M+ rating).
                local full, classFile, _lcl, _lvl, itemLevel, _hlvl,
                      _tank, _healer, _dps, role, _rel, dungeonScore =
                      C_LFGList.GetApplicantMemberInfo(applicantID, m)
                if type(full) == "string" and full ~= "" then
                    local n, r = splitName(full)
                    if n then
                        lines[#lines + 1] = makeEntry(
                            region, n, r, classFile, applicantID,
                            dungeonScore, target, role, itemLevel
                        )
                    end
                end
            end
        end
    end

    -- Note: previously this block also emitted search-result leaders
    -- (so the overlay showed parses for the groups you were browsing).
    -- That fired even when the user was applying out, which lit up the
    -- companion at the wrong time. The grid is now scoped to the
    -- user's own M+ / raid listing only.

    if #lines == 0 then return nil end

    local seen, unique = {}, {}
    for _, l in ipairs(lines) do
        if not seen[l] then
            seen[l] = true
            unique[#unique + 1] = l
        end
    end
    return "WCL:" .. table.concat(unique, ";")
end

-- Kept for /wcl status only.
local function isLFGUIShown()
    return (PVEFrame and PVEFrame:IsShown())
        or (LFGListFrame and LFGListFrame:IsShown())
        or (GroupFinderFrame and GroupFinderFrame:IsShown())
        or (C_LFGList and C_LFGList.HasActiveEntry and C_LFGList.HasActiveEntry())
        or false
end

-- Cached so the 1 Hz ticker only calls into WCLScreenGrid when the payload
-- actually changes. WCLScreenGrid.Render has its own cache too — this layer
-- short-circuits before the Lua string compare inside SG.
local lastBuiltPayload

local function refreshScreenGrid()
    if not WCLScreenGrid then return end
    -- pcall the entire build+render path. A Lua error inside the
    -- ticker callback used to silently kill subsequent ticks (the
    -- ticker itself stays alive, but `lastBuiltPayload` could get
    -- stuck on stale data and the grid would never recover until the
    -- user /reload'd). Failing the current refresh is fine — the next
    -- one runs with cleared state.
    local ok, payload = pcall(buildRosterPayload)
    if not ok then
        lastBuiltPayload = nil
        return
    end
    if payload == lastBuiltPayload then return end
    lastBuiltPayload = payload
    if payload then
        pcall(WCLScreenGrid.Render, payload)
    else
        pcall(WCLScreenGrid.Hide)
    end
end

-- Force the next refresh to re-emit even if the payload string is
-- identical. Used by /wcl reset and by event handlers after group
-- transitions where the API briefly returns stale data and we want
-- the next poll to act on whatever the API reports without skipping.
local function forceNextRefresh()
    lastBuiltPayload = nil
end

-- Polling every 1 s as a safety net — catches anything the events
-- below miss across client versions / weird transitions.
C_Timer.NewTicker(1.0, function()
    refreshScreenGrid()
end)

-- Event-driven refresh: triggers an immediate rebuild whenever LFG or
-- group state changes. Joining a group, becoming a leader, the search
-- results landing, applicants arriving — all of these used to wait up
-- to 1 s for the next poll, and if a transient API state lined up
-- with that poll the grid could stay stuck on the previous payload.
-- Events fire ahead of the poll so the user-visible delay is gone,
-- and the cache is invalidated so the next refresh can't short-circuit.
local lfgEvents = CreateFrame("Frame")
local watchedEvents = {
    "LFG_LIST_ACTIVE_ENTRY_UPDATE",
    "LFG_LIST_APPLICANT_LIST_UPDATED",
    "LFG_LIST_APPLICANT_UPDATED",
    "LFG_LIST_SEARCH_RESULTS_RECEIVED",
    "LFG_LIST_SEARCH_RESULT_UPDATED",
    "LFG_LIST_AVAILABILITY_UPDATE",
    "LFG_LIST_ROLE_UPDATE",
    "GROUP_ROSTER_UPDATE",
    "PARTY_LEADER_CHANGED",
    "PLAYER_ROLES_ASSIGNED",
    "PLAYER_ENTERING_WORLD",
}
for _, ev in ipairs(watchedEvents) do
    lfgEvents:RegisterEvent(ev)
end
lfgEvents:SetScript("OnEvent", function(_, event)
    -- PLAYER_ENTERING_WORLD also doubles as our "all files loaded"
    -- hook for applying companion-written overrides — LocalConfig.lua
    -- is loaded by the .toc but globals declared there aren't usable
    -- until the addon's main chunks have all run.
    if event == "PLAYER_ENTERING_WORLD" then
        if WCLHoverLocalConfig and WCLHoverLocalConfig.cellSize
           and WCLScreenGrid and WCLScreenGrid.SetCellSize then
            local applied = WCLScreenGrid.SetCellSize(
                WCLHoverLocalConfig.cellSize
            )
            -- One-shot status print so the user can confirm the
            -- companion-written value reached the addon. Without
            -- this a missing LocalConfig.lua / wrong addon dir
            -- looked identical to "size unchanged" in-game.
            chatPrint(("grid cell size = %s (LocalConfig)%s"):format(
                tostring(WCLHoverLocalConfig.cellSize),
                applied and "" or " — REJECTED"
            ))
        else
            chatPrint("grid cell size = 4 (default — no LocalConfig)")
        end
    end
    forceNextRefresh()
    refreshScreenGrid()
end)

-- Slash command -------------------------------------------------------------

SLASH_WCLHOVER1 = "/wcl"
SlashCmdList["WCLHOVER"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")

    if msg == "status" then
        if not lastHovered then
            chatPrint("lastHovered = nil (hover an LFG player first).")
        else
            chatPrint(("lastHovered: name=%s realm=%s region=%s source=%s"):format(
                tostring(lastHovered.name),
                tostring(lastHovered.realm),
                tostring(lastHovered.region),
                tostring(lastHovered.source)
            ))
            chatPrint("URL: " .. (buildUrl(lastHovered.name, lastHovered.realm, lastHovered.region) or "<nil>"))
        end
        chatPrint("LFG UI open = " .. tostring(isLFGUIShown()))
        return
    end

    -- /wcl accept <id>  — invoked by the overlay; calls the same API as the
    -- in-game accept button, so group applicants work correctly.
    local acceptID = msg:match("^accept%s+(%d+)$")
    if acceptID then
        local id = tonumber(acceptID)
        if id and C_LFGList and C_LFGList.InviteApplicant then
            C_LFGList.InviteApplicant(id)
        else
            chatPrint("C_LFGList.InviteApplicant unavailable.")
        end
        return
    end

    -- /wcl decline <id>  or  /wcl decline all
    local declineArg = msg:match("^decline%s+(%S+)$")
    if declineArg then
        if not (C_LFGList and C_LFGList.DeclineApplicant) then
            chatPrint("C_LFGList.DeclineApplicant unavailable.")
            return
        end
        if declineArg == "all" then
            -- DeclineApplicant is protected on retail: only the first call
            -- per user-input event lands. The overlay drives this instead
            -- by sending one "/wcl decline <id>" slash per applicant, each
            -- a fresh keystroke event. This branch is a no-op.
            chatPrint("Use overlay ✕ — one /wcl decline per applicant.")
        else
            local id = tonumber(declineArg)
            if id and C_LFGList.DeclineApplicant then
                C_LFGList.DeclineApplicant(id)
            end
        end
        return
    end

    local cellSz = msg:match("^grid size%s+(%d+)$")
    if cellSz then
        if WCLScreenGrid and WCLScreenGrid.SetCellSize
           and WCLScreenGrid.SetCellSize(cellSz) then
            chatPrint("Grid cell size = " .. cellSz .. " px.")
        else
            chatPrint("Invalid size (accepted range 2–16).")
        end
        return
    end

    if msg == "target" then
        local entry = C_LFGList and C_LFGList.GetActiveEntryInfo
                      and C_LFGList.GetActiveEntryInfo() or nil
        if type(entry) ~= "table" then
            chatPrint("No active entry.")
            return
        end
        -- activityIDs table — each entry represents a selectable M+ level.
        local ids = entry.activityIDs or entry.activityID
        if type(ids) ~= "table" then ids = { ids } end
        for i, aid in ipairs(ids) do
            if C_LFGList.GetActivityInfoTable then
                local info = C_LFGList.GetActivityInfoTable(aid)
                if type(info) == "table" then
                    chatPrint(("activityID[%d]=%s  shortName=%s  fullName=%s  minLvl=%s  maxLvl=%s"):format(
                        i, tostring(aid),
                        tostring(info.shortName),
                        tostring(info.fullName),
                        tostring(info.minLevel),
                        tostring(info.maxLevel)
                    ))
                else
                    chatPrint(("activityID[%d]=%s  (no info)"):format(i, tostring(aid)))
                end
            end
        end
        -- Keystone in the player's bag, which is normally what they list.
        if C_MythicPlus and C_MythicPlus.GetOwnedKeystoneLevel then
            chatPrint("owned keystone level = " ..
                tostring(C_MythicPlus.GetOwnedKeystoneLevel()))
        end
        local detected = detectListingTargetKey()
        chatPrint("detected target = " .. tostring(detected))
        return
    end

    if msg == "grid reset" then
        WCLHoverDB = WCLHoverDB or {}
        WCLHoverDB.screenGridPos = nil
        chatPrint("Grid position reset. /reload to re-anchor top-left.")
        return
    end

    if msg == "reset" then
        -- Hard-reset for the case where the addon's emission loop has
        -- got stuck on stale state. Clears the payload cache + tells
        -- the screen grid to drop its cached bytes; the next poll will
        -- rebuild from scratch and re-render whatever the API reports.
        forceNextRefresh()
        if WCLScreenGrid and WCLScreenGrid.Hide then WCLScreenGrid.Hide() end
        refreshScreenGrid()
        chatPrint("Reset — grid re-evaluated against current API state.")
        return
    end

    if msg == "grid dump" or msg == "grid now" then
        local applicants = getApplicantIDs()
        local results    = getSearchResultIDs()
        local payload    = buildRosterPayload()
        local hasEntry   = C_LFGList and C_LFGList.HasActiveEntry
                           and C_LFGList.HasActiveEntry() or false
        local listShown  = LFGListFrame and LFGListFrame:IsShown() or false
        chatPrint(("applicants=%d results=%d  HasActiveEntry=%s  LFGListFrame=%s"):format(
            #applicants, #results,
            tostring(hasEntry), tostring(listShown)
        ))
        -- Per-applicant details so we can see what GetApplicantMemberInfo
        -- is actually returning for each one (name / class / realm).
        for _, applicantID in ipairs(applicants) do
            local info = C_LFGList.GetApplicantInfo(applicantID)
            local members = (info and info.numMembers) or 0
            for m = 1, members do
                local full, cls = C_LFGList.GetApplicantMemberInfo(applicantID, m)
                chatPrint(("  applicant[%d:%d] full=%s class=%s"):format(
                    applicantID, m, tostring(full), tostring(cls)
                ))
            end
        end
        chatPrint("payload: " .. (payload or "<nil>"))
        if msg == "grid now" and payload and WCLScreenGrid then
            WCLScreenGrid.Render(payload)
        end
        return
    end

    if msg == "grid test" then
        if not WCLScreenGrid then
            chatPrint("WCLScreenGrid not loaded (is ScreenGrid.lua in the TOC?).")
            return
        end
        WCLScreenGrid.Render("WCL:eu|tjruid|twistingnether|DRUID;eu|hipposlack|ysondre|WARLOCK")
        local f = _G.WCLScreenGridFrame
        if f then
            chatPrint(("grid: shown=%s size=%dx%d at (%d, %d)"):format(
                tostring(f:IsShown()),
                math.floor(f:GetWidth() or 0),
                math.floor(f:GetHeight() or 0),
                math.floor(f:GetLeft() or -1),
                math.floor(f:GetTop() or -1)
            ))
        else
            chatPrint("grid frame doesn't exist after Render().")
        end
        return
    end

    if msg == "" then
        WCLHover_ShowHovered()
        return
    end

    local n, r = splitName(msg)
    if not n then
        chatPrint("Usage: /wcl <Name>[-Realm]  |  /wcl  (last hover)  |  /wcl status")
        return
    end
    showPopup(n, r)
end
