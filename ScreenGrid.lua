-- ScreenGrid.lua
-- IPC from WoW → external Python tool via a grid of colored textures on
-- the top-left of the screen. The Python side (wcl_checker.exe) scans
-- this region, finds the 4-cell locator, reads the length + sequence, and
-- decodes the payload one byte per cell.
--
-- Protocol (little-endian byte-per-cell, RED channel):
--   Row 0 cells 0..3 = locator: RED, GREEN, BLUE, MAGENTA
--   Row 0 cell  4    = length high byte
--   Row 0 cell  5    = length low byte
--   Row 0 cell  6    = sequence id (increments on every payload change)
--   Rows 1..         = payload bytes (GRID_COLS per row)

WCLScreenGrid = WCLScreenGrid or {}
local SG = WCLScreenGrid

local GRID_COLS     = 32
-- Cell size in WoW pixels. 4 is usually the minimum reliable value given
-- UI scale + DWM pixel jitter; bump to 6-8 if the scanner misreads colours.
-- SG.SetCellSize(n) lets the addon tweak this at runtime.
local CELL_SIZE     = 4
local LOCATOR_COLORS = {
    {1, 0, 0},  -- red
    {0, 1, 0},  -- green
    {0, 0, 1},  -- blue
    {1, 0, 1},  -- magenta
}

local frame            -- parent frame anchored TOPLEFT UIParent
local texturePool = {}
local seq = 0
local lastPayload      -- cached so we skip redraws when nothing changed
local lastBytes = {}   -- RGB bytes per cell index; skip SetColorTexture when unchanged

local function ensureFrame()
    if frame then return frame end
    frame = CreateFrame("Frame", "WCLScreenGridFrame", UIParent)
    frame:SetFrameStrata("TOOLTIP")
    -- Centred on screen so the default UI's player/target/minimap frames
    -- don't cover it. User can drag with shift-click to reposition; the
    -- last position is stored in SavedVariablesPerCharacter (WCLHoverDB).
    WCLHoverDB = WCLHoverDB or {}
    local pos = WCLHoverDB.screenGridPos
    if pos then
        frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", pos.x, pos.y)
    else
        -- Default to the absolute top-left of the client area. Shift-click
        -- drag to move if the player frame / addon UI covers it.
        frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    end
    frame:SetSize(GRID_COLS * CELL_SIZE, CELL_SIZE)

    -- Thin tan border so the grid is locatable at a glance and obviously
    -- not a Blizzard UI element.
    local bd = frame:CreateTexture(nil, "BACKGROUND")
    bd:SetColorTexture(0.48, 0.42, 0.26, 1)
    bd:SetAllPoints(frame)
    frame.border = bd
    -- Inner black background so empty cells don't bleed the border colour.
    local bg = frame:CreateTexture(nil, "BORDER")
    bg:SetColorTexture(0, 0, 0, 1)
    bg:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    bg:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    frame.bg = bg

    -- Shift-click drag to move. Position persists across sessions.
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if IsShiftKeyDown() then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        WCLHoverDB = WCLHoverDB or {}
        WCLHoverDB.screenGridPos = { x = self:GetLeft(),
                                     y = self:GetTop() - UIParent:GetHeight() }
    end)
    frame:Hide()
    return frame
end

local function getTexture(i)
    local t = texturePool[i]
    if t then return t end
    t = frame:CreateTexture(nil, "OVERLAY")
    t:SetSize(CELL_SIZE, CELL_SIZE)
    texturePool[i] = t
    return t
end

-- Place one cell at (col, row) with RGB in 0..255 units.
-- Skips SetColorTexture + ClearAllPoints when the cell already has these
-- values from the previous render (major stutter reduction: most cells in
-- the payload don't change between updates).
local function placeCell(i, col, row, r, g, b)
    local prev = lastBytes[i]
    if prev and prev.c == col and prev.r == row
       and prev.R == r and prev.G == g and prev.B == b then
        local t = texturePool[i]
        if t and t:IsShown() then return end
    end
    local t = getTexture(i)
    if not prev or prev.c ~= col or prev.r ~= row then
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", frame, "TOPLEFT", col * CELL_SIZE, -row * CELL_SIZE)
    end
    if not prev or prev.R ~= r or prev.G ~= g or prev.B ~= b then
        t:SetColorTexture(r / 255, g / 255, b / 255, 1)
    end
    t:Show()
    lastBytes[i] = { c = col, r = row, R = r, G = g, B = b }
end

-- Public: render the given string as a grid. Hides existing cells past the
-- new end so a shrinking payload doesn't leave stale bytes visible.
function SG.Render(payload)
    ensureFrame()
    if type(payload) ~= "string" or payload == "" then
        SG.Hide()
        lastPayload = nil
        return
    end
    -- Short-circuit when nothing changed. The 1 Hz ticker otherwise rebuilt
    -- every cell every second — huge source of stutter + visual churn.
    if payload == lastPayload and frame:IsShown() then
        return
    end
    lastPayload = payload
    frame:Show()

    seq = (seq + 1) % 256
    local len = #payload
    local i = 0

    -- Row 0 cells 0..3: locator.
    for k, c in ipairs(LOCATOR_COLORS) do
        i = i + 1
        placeCell(i, k - 1, 0, c[1] * 255, c[2] * 255, c[3] * 255)
    end

    -- Length high/low, sequence (all in R channel).
    local hi = math.floor(len / 256)
    local lo = len % 256
    i = i + 1; placeCell(i, 4, 0, hi,  0, 0)
    i = i + 1; placeCell(i, 5, 0, lo,  0, 0)
    i = i + 1; placeCell(i, 6, 0, seq, 0, 0)

    -- Data cells: rows 1+, 3 bytes per pixel (R,G,B). Cuts the grid down
    -- to a third of the old 1-byte-per-pixel footprint.
    local pixels = math.ceil(len / 3)
    for p = 0, pixels - 1 do
        i = i + 1
        local base = p * 3
        local b1 = string.byte(payload, base + 1) or 0
        local b2 = string.byte(payload, base + 2) or 0
        local b3 = string.byte(payload, base + 3) or 0
        local col = p % GRID_COLS
        local row = 1 + math.floor(p / GRID_COLS)
        placeCell(i, col, row, b1, b2, b3)
    end

    -- Grow frame to fit the rendered rows.
    local rows = 1 + math.ceil(pixels / GRID_COLS)
    frame:SetSize(GRID_COLS * CELL_SIZE, rows * CELL_SIZE)

    -- Hide surplus textures from a previous larger payload.
    while texturePool[i + 1] do
        i = i + 1
        texturePool[i]:Hide()
        lastBytes[i] = nil
    end
end

function SG.Hide()
    if frame then frame:Hide() end
    for _, t in pairs(texturePool) do t:Hide() end
    lastPayload = nil
    -- Force next render to redraw everything (textures are hidden, not
    -- torn down — but on re-show the first pass should place them fresh).
    lastBytes = {}
end

-- Runtime cell-size tuning via `/wcl grid size N`.
-- Drops the entire texture pool and lets the next Render rebuild it
-- from scratch — earlier we just resized the existing textures in
-- place, but on at least some clients that left them rendering at the
-- old size even after SetSize / SetPoint, so resizes appeared to do
-- nothing visually. Tearing them down avoids any stale state.
function SG.SetCellSize(n)
    n = tonumber(n)
    if not n or n < 2 or n > 16 then return false end
    CELL_SIZE = math.floor(n)
    for _, t in pairs(texturePool) do
        t:Hide()
        t:ClearAllPoints()
        t:SetTexture(nil)
    end
    texturePool = {}
    if frame then
        frame:SetSize(GRID_COLS * CELL_SIZE, CELL_SIZE)
    end
    lastPayload = nil
    lastBytes = {}
    return true
end

-- Read accessor for the current cell size, used by the /wcl size
-- diagnostic so we can verify what the addon actually has loaded
-- without having to dump random tables to chat.
function SG.GetCellSize()
    return CELL_SIZE
end
