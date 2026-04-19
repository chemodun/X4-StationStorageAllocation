-- Station Storage Allocation
-- Adds a "Storage Allocation" tab to the map info panel for player-owned stations.
-- Shows per-type capacity and usage; each type is expandable to reveal per-ware
-- allocation rows.  In edit mode percentage sliders let the player adjust the
-- per-ware storage limits.
--
-- Storage type header rows  → click row to expand / collapse.
-- Per-ware rows (expanded)  → stock / limit / allocation % / auto-managed indicator.
-- Edit mode (checkbox)       → percentage slider per ware (or "Set %" button when the
--                              slider-cell limit of 50 would be exceeded).
-- Bottom buttons (edit mode) → Save (applies draftLimits) / Reset All (clears overrides).
--
-- FFI types and functions used are declared in the ffi.cdef block below.
-- Re-declaring the same typedef / function signatures as ego_detailmonitor or
-- ego_detailmonitorhelper is harmless.

local ffi = require("ffi")
local C   = ffi.C

ffi.cdef [[
  typedef uint64_t UniverseID;

  typedef struct {
    const char* name;
    const char* transport;
    uint32_t    spaceused;
    uint32_t    capacity;
  } StorageInfo;

  typedef struct {
    const char* ware;
    const char* macro;
    int         amount;
  } UIWareInfo;

  typedef struct {
    int major;
    int minor;
  } GameVersion;

  uint32_t    GetCargoTransportTypes(StorageInfo* result, uint32_t resultlen, UniverseID containerid, bool merge, bool aftertradeorders);
  const char* GetComponentName(UniverseID componentid);
  GameVersion GetGameVersion(void);
  uint32_t    GetContainerStockLimitOverrides(UIWareInfo* result, uint32_t resultlen, UniverseID containerid);
  uint32_t    GetNumCargoTransportTypes(UniverseID containerid, bool merge);
  uint32_t    GetNumContainerStockLimitOverrides(UniverseID containerid);
  const char* GetObjectIDCode(UniverseID objectid);
  UniverseID  GetPlayerContainerID(void);
  UniverseID  GetPlayerID(void);
  UniverseID  GetPlayerOccupiedShipID(void);
  bool        IsComponentClass(UniverseID componentid, const char* classname);
  void        SetFocusMapComponent(UniverseID holomapid, UniverseID componentid, bool resetplayerpan);
]]

-- Unique mode key for the info-panel tab strip (must not clash with other mods).
local SSA_CATEGORY = "chem_station_storage_alloc"
-- Text page ID for this mod (see t/0001-l044.xml).
local SSA_PAGE     = 1972092419
-- Hard limit on slider-cell widgets from widget_fullscreen.lua:
--   config.slidercell.maxElements = 50
local SLIDER_MAX   = 50

-- Resolved in init()
local menu   = nil
local config = nil

-- Module state (persists across panel refreshes within the same session).
local ssa = {
  isV9             = C.GetGameVersion().major >= 9,
  expandedType     = nil,    -- transport-type ID string currently expanded, or nil
  editEnabled      = false,  -- whether edit mode is active
  draftLimits      = {},     -- [ware_id] = new limit in units (pending, applied on Save)
  activeSliderWare = nil,    -- ware that gets a slider when budget would be exceeded
}

-- ─── helpers ─────────────────────────────────────────────────────────────────

local function fmt(n)
  return ConvertIntegerString(Helper.round(n), true, 0, true, false)
end

-- Resolve menu.infoSubmenuObject from selected components or the player ship.
local function resolveInfoSubmenuObject()
  if (not menu.infoSubmenuObject) or (menu.infoSubmenuObject == 0) then
    for id in pairs(menu.selectedcomponents) do
      menu.infoSubmenuObject = ConvertStringTo64Bit(tostring(id)); break
    end
    if (not menu.infoSubmenuObject) or (menu.infoSubmenuObject == 0) then
      menu.infoSubmenuObject = ConvertStringTo64Bit(tostring(C.GetPlayerOccupiedShipID()))
      if (not menu.infoSubmenuObject) or (menu.infoSubmenuObject == 0) then
        menu.infoSubmenuObject = ConvertStringTo64Bit(tostring(C.GetPlayerContainerID()))
      end
    end
  end
end

-- ─── data collection ─────────────────────────────────────────────────────────

-- Collect per-type storage information from a station.
-- Returns an array of type records:
--   { id, name, spaceused, capacity, wares = { { id, name, icon, transport,
--     volume, stock, limit, isAuto, allocPct, displayLimit } } }
-- Wares are sorted alphabetically; types are sorted alphabetically.
local function collectStorageData(station)
  -- 1. Get transport types.
  local ntypes = tonumber(C.GetNumCargoTransportTypes(station, true))
  local typeMap = {}  -- [transportId] → type record

  if ntypes and ntypes > 0 then
    local buf = ffi.new("StorageInfo[?]", ntypes)
    ntypes = tonumber(C.GetCargoTransportTypes(buf, ntypes, station, true, false))
    for i = 0, ntypes - 1 do
      local tid = ffi.string(buf[i].transport)
      typeMap[tid] = {
        id        = tid,
        name      = ffi.string(buf[i].name),
        spaceused = tonumber(buf[i].spaceused),
        capacity  = tonumber(buf[i].capacity),
        wares     = {},
      }
    end
  end

  if not next(typeMap) then return {} end

  -- 2. Collect unique ware IDs from all relevant sources.
  local wareSet = {}

  -- Current cargo contents.
  local cargo = GetComponentData(station, "cargo") or {}
  for ware in pairs(cargo) do wareSet[ware] = true end

  -- Production lists (products, pure resources, intermediates).
  local products, pureresources, intermediatewares =
    GetComponentData(station, "availableproducts", "pureresources", "intermediatewares")
  for _, ware in ipairs(products        or {}) do wareSet[ware] = true end
  for _, ware in ipairs(pureresources   or {}) do wareSet[ware] = true end
  for _, ware in ipairs(intermediatewares or {}) do wareSet[ware] = true end

  -- Wares with explicit stock-limit overrides (includes trade wares).
  local nover = tonumber(C.GetNumContainerStockLimitOverrides(station))
  if nover and nover > 0 then
    local obuf = ffi.new("UIWareInfo[?]", nover)
    nover = tonumber(C.GetContainerStockLimitOverrides(obuf, nover, station))
    for i = 0, nover - 1 do
      wareSet[ffi.string(obuf[i].ware)] = true
    end
  end

  -- 3. For each ware, get ware data and assign to the correct type.
  for ware in pairs(wareSet) do
    local wareName, transport, volume, icon =
      GetWareData(ware, "name", "transport", "volume", "icon")
    if transport and typeMap[transport] then
      local vol          = volume or 1
      local limit        = GetWareProductionLimit(station, ware) or 0
      local stock        = cargo[ware] or 0
      local isAuto       = not HasContainerStockLimitOverride(station, ware)
      local cap          = typeMap[transport].capacity
      -- Use draft limit if the player has already moved the slider this session.
      local displayLimit = ssa.draftLimits[ware] or limit
      local allocPct     = (cap > 0 and displayLimit > 0)
          and math.min(100, displayLimit * vol / cap * 100)
          or  0

      table.insert(typeMap[transport].wares, {
        id           = ware,
        name         = wareName or ware,
        icon         = (icon and icon ~= "") and icon or "solid",
        transport    = transport,
        volume       = vol,
        stock        = stock,
        limit        = limit,
        isAuto       = isAuto,
        allocPct     = allocPct,
        displayLimit = displayLimit,
      })
    end
  end

  -- 4. Sort wares alphabetically within each type; sort types alphabetically.
  local typesArray = {}
  for _, tdata in pairs(typeMap) do
    table.sort(tdata.wares, function(a, b) return a.name < b.name end)
    table.insert(typesArray, tdata)
  end
  table.sort(typesArray, function(a, b) return a.name < b.name end)

  return typesArray
end

-- ─── table builder ───────────────────────────────────────────────────────────

-- Create and configure the standard 6-column info table.
-- Columns: 1=+/- button(fixed), 2=name(min 30%), 3=stock/used(12%),
--          4=limit/cap(12%), 5=%(11%), 6=indicator/slider(23%)
local function addInfoTable(inputframe, infoBorder)
  local tableInfo = inputframe:addTable(7, ssa.isV9 and {
    tabOrder          = 1,
    x                 = Helper.standardContainerOffset,
    width             = inputframe.properties.width - 2 * Helper.standardContainerOffset,
    backgroundID      = "solid",
    backgroundColor   = Color["container_subsection_background"] or nil,
    backgroundPadding = 0,
    frameborder       = infoBorder and infoBorder.id or nil,
  } or {
    tabOrder = 1,
  })
  tableInfo:setColWidth(1, config.mapRowHeight)  -- +/- expand/collapse button
  tableInfo:setColWidthMinPercent(2, 18)         -- ware / type name (variable)
  tableInfo:setColWidthPercent(3, 14)            -- stock m³
  tableInfo:setColWidthPercent(4, 8)             -- stock %
  tableInfo:setColWidthPercent(5, 14)            -- limit m³
  tableInfo:setColWidthPercent(6, 8)             -- limit %
  tableInfo:setColWidthPercent(7, 7)             -- auto checkbox
  tableInfo:setDefaultBackgroundColSpan(1, 7)
  tableInfo:setDefaultCellProperties("text",   { minRowHeight = config.mapRowHeight, fontsize = config.mapFontSize })
  tableInfo:setDefaultCellProperties("button", { height = config.mapRowHeight })
  return tableInfo
end

-- Restore previously saved selected / top row for infotable<instance>.
local function restoreTableSelection(tableInfo, instance)
  if menu.selectedRows["infotable" .. instance] then
    tableInfo:setSelectedRow(menu.selectedRows["infotable" .. instance])
    menu.selectedRows["infotable" .. instance] = nil
    if menu.topRows["infotable" .. instance] then
      tableInfo:setTopRow(menu.topRows["infotable" .. instance])
      menu.topRows["infotable" .. instance] = nil
    end
    if menu.selectedCols["infotable" .. instance] then
      tableInfo:setSelectedCol(menu.selectedCols["infotable" .. instance])
      menu.selectedCols["infotable" .. instance] = nil
    end
  end
  menu.setrow    = nil
  menu.settoprow = nil
  menu.setcol    = nil
end

-- ─── row rendering ───────────────────────────────────────────────────────────

-- Render all storage-type header rows (and expanded ware rows) into tableInfo.
local function setupStorageSubmenuRows(tableInfo, station)
  -- ── station title + focus button ──
  local isStation = station and (tonumber(station) ~= 0)
      and C.IsComponentClass(station, "station")

  local stationName = isStation
      and ffi.string(C.GetComponentName(station))
      or  ReadText(SSA_PAGE, 1)

  local titleColor = ssa.isV9
      and (isStation and menu.getObjectColor(station) or Color["text_normal"])
      or  menu.holomapcolor.playercolor

  local row = tableInfo:addRow("info_focus", {
    fixed   = true,
    bgColor = not ssa.isV9 and Color["row_title_background"] or nil,
  })
  if ssa.isV9 then
    row[2]:setColSpan(6):createText(stationName,
      { fontsize = Helper.headerRow1FontSize, color = titleColor })
  else
    row[2]:setColSpan(6):createText(stationName, Helper.headerRow1Properties)
    row[2].properties.color = titleColor
  end

  if not isStation then
    row = tableInfo:addRow(true, {})
    row[1]:setColSpan(7):createText(ReadText(SSA_PAGE, 1001), { halign = "center", wordwrap = true })
    return
  end

  -- ── column headers ──
  row = tableInfo:addRow(false, { fixed = true })
  -- col 1 (button column) intentionally left empty
  row[2]:createText(ReadText(SSA_PAGE, 110), Helper.headerRowCenteredProperties)  -- Ware
  row[3]:createText(ReadText(SSA_PAGE, 111), Helper.headerRowCenteredProperties)  -- Stock m³
  row[4]:createText(ReadText(SSA_PAGE, 116), Helper.headerRowCenteredProperties)  -- Stock %
  row[5]:createText(ReadText(SSA_PAGE, 112), Helper.headerRowCenteredProperties)  -- Limit m³
  row[6]:createText(ReadText(SSA_PAGE, 113), Helper.headerRowCenteredProperties)  -- Limit %
  row[7]:createText(ReadText(SSA_PAGE, 114), Helper.headerRowCenteredProperties)  -- Auto

  -- ── collect storage data ──
  local typesArray = collectStorageData(station)

  if #typesArray == 0 then
    row = tableInfo:addRow(true, {})
    row[1]:setColSpan(7):createText(ReadText(SSA_PAGE, 1002), { halign = "center", wordwrap = true })
    return
  end

  -- Slider budget: one readOnly capacity-bar slider per type is reserved;
  -- the remainder is available for editable ware-allocation sliders.
  local wareSliderBudget = SLIDER_MAX - #typesArray

  -- ── render each storage type ──
  for _, tdata in ipairs(typesArray) do
    local isExpanded = (ssa.expandedType == tdata.id)

    -- Type header row: small +/- button in col 1, vanilla-style read-only slider
    -- (with type name as text overlay) spanning cols 2-6.
    local typeRow = tableInfo:addRow("type_" .. tdata.id, {
      fixed   = false,
      bgColor = Color["row_title_background"],
    })
    -- Col 1: expand / collapse button.
    typeRow[1]:createButton({
      width       = config.mapRowHeight,
      height      = config.mapRowHeight,
      cellBGColor = Color["row_background"],
    }):setText(isExpanded and "-" or "+", { halign = "center" })
    typeRow[1].handlers.onClick = function()
      if isExpanded then
        ssa.expandedType = nil
      else
        ssa.expandedType = tdata.id
      end
      ssa.activeSliderWare = nil
      menu.refreshInfoFrame()
    end
    -- Cols 2-7: read-only capacity bar with type name label (vanilla storage style).
    typeRow[2]:setColSpan(6):createSliderCell({
      height   = config.mapRowHeight,
      start    = tdata.spaceused,
      max      = math.max(1, tdata.capacity),
      readOnly = true,
      suffix   = ReadText(1001, 110),
    }):setText(tdata.name, { fontsize = config.mapFontSize })

    -- ── ware rows (only when this type is expanded) ──
    if isExpanded then
      local sliderCount = 0  -- tracks how many editable sliders have been placed

      -- Total free space in this storage type (fixed physical fact, unaffected by limit edits).
      local freeM3 = math.max(0, tdata.capacity - tdata.spaceused)

      for _, wareData in ipairs(tdata.wares) do
        -- Pre-compute m³ values.
        local stockM3 = wareData.stock * wareData.volume
        local limitM3 = wareData.displayLimit * wareData.volume
        local dimColor = ColorText["text_inactive"] or ""
        local m3Suffix = " " .. ReadText(1001, 110)  -- vanilla m³ text

        if ssa.editEnabled then
          -- ── Edit mode ──
          -- Row 1: shows GAME (saved) limit/%, not draft — draft is only in the slider row.
          local gameLimitM3 = wareData.limit * wareData.volume
          local gamePct     = (tdata.capacity > 0 and gameLimitM3 > 0)
              and math.min(100, gameLimitM3 / tdata.capacity * 100)
              or  0
          local gameStockPct = (gameLimitM3 > 0)
              and math.min(100, stockM3 / gameLimitM3 * 100)
              or  0
          local wareRow = tableInfo:addRow(true, {})
          wareRow[2]:createText(
            "\027[" .. wareData.icon .. "] " .. wareData.name,
            { halign = "left", fontsize = config.mapFontSize }
          )
          wareRow[3]:createText(fmt(stockM3) .. m3Suffix,          { halign = "right" })
          wareRow[4]:createText(string.format("%.2f%%", gameStockPct), { halign = "right" })
          wareRow[5]:createText(fmt(gameLimitM3) .. m3Suffix,      { halign = "right" })
          wareRow[6]:createText(string.format("%.2f%%", gamePct),  { halign = "right" })
          wareRow[7]:createCheckBox(wareData.isAuto, { active = false,
            height = config.mapRowHeight, width = config.mapRowHeight })

          -- Determine whether this ware can get an editable slider.
          local useSlider = (sliderCount < wareSliderBudget)
              or (ssa.activeSliderWare == wareData.id)

          -- min = ware's current stock m³ (can't set limit below what's already stored)
          -- max = ware's stock m³ + total free space in this storage type
          local currentLimitM3 = math.floor(limitM3)
          local minSelectM3    = math.floor(stockM3)
          local maxSelectM3    = math.floor(stockM3 + freeM3)

          local sliderRow = tableInfo:addRow(false, {})

          if useSlider then
            sliderCount = sliderCount + 1

            local capturedWare = wareData
            local capturedType = tdata
            sliderRow[2]:setColSpan(4):createSliderCell({
              height      = config.mapRowHeight,
              min         = minSelectM3,
              max         = maxSelectM3,
              maxSelect   = maxSelectM3,
              start       = currentLimitM3,
              suffix      = m3Suffix,
              readOnly    = false,
              forceArrows = true,
            })
            sliderRow[2].handlers.onSliderCellActivated   = function() menu.noupdate = true end
            sliderRow[2].handlers.onSliderCellDeactivated = function()
              menu.noupdate = false
              -- Rebalance: ensure sum of all draft limits (in m³) stays ≤ capacity.
              local cap = capturedType.capacity
              -- Calculate current total draft m³ across all wares in this type.
              local totalM3 = 0
              for _, w in ipairs(capturedType.wares) do
                local wLimit = ssa.draftLimits[w.id] or w.limit
                totalM3 = totalM3 + wLimit * w.volume
              end
              local overflow = totalM3 - cap
              if overflow > 0 then
                -- Build list of candidates: other wares that have slack above their stock.
                local candidates = {}
                local totalSlack = 0
                for _, w in ipairs(capturedType.wares) do
                  if w.id ~= capturedWare.id then
                    local wLimit   = ssa.draftLimits[w.id] or w.limit
                    local wLimitM3 = wLimit * w.volume
                    local wStockM3 = w.stock * w.volume
                    local slack    = math.max(0, wLimitM3 - wStockM3)
                    if slack > 0 then
                      table.insert(candidates, { ware = w, limitM3 = wLimitM3, stockM3 = wStockM3, slack = slack })
                      totalSlack = totalSlack + slack
                    end
                  end
                end
                if totalSlack >= overflow then
                  -- Enough slack: reduce each candidate proportionally.
                  for _, c in ipairs(candidates) do
                    local reduce   = overflow * (c.slack / totalSlack)
                    local newLimitM3 = math.max(c.stockM3, c.limitM3 - reduce)
                    local vol = c.ware.volume
                    ssa.draftLimits[c.ware.id] = (vol > 0) and math.floor(newLimitM3 / vol + 0.5) or 0
                  end
                else
                  -- Not enough slack in others: floor all candidates to their stock,
                  -- then cap the changed ware for the remaining overflow.
                  for _, c in ipairs(candidates) do
                    local vol = c.ware.volume
                    ssa.draftLimits[c.ware.id] = (vol > 0) and math.ceil(c.stockM3 / vol) or 0
                  end
                  local remaining = overflow - totalSlack
                  local vol = capturedWare.volume
                  local myLimitM3 = (ssa.draftLimits[capturedWare.id] or capturedWare.limit) * vol
                  ssa.draftLimits[capturedWare.id] = (vol > 0)
                      and math.max(0, math.floor((myLimitM3 - remaining) / vol + 0.5))
                      or 0
                end
              end
              menu.refreshInfoFrame()
            end
            sliderRow[2].handlers.onSliderCellChanged = function(_, val)
              local vol = capturedWare.volume
              ssa.draftLimits[capturedWare.id] = (vol > 0) and math.floor(val / vol + 0.5) or 0
            end
            -- Col 5: allocation % derived from current draft limit, coloured by change direction.
            local cap = capturedType.capacity
            local draftPct = (cap > 0 and currentLimitM3 > 0)
                and math.min(100, currentLimitM3 / cap * 100)
                or 0
            local draftPctStr = string.format("%.2f%%", draftPct)
            local pctColor = ""
            if currentLimitM3 > gameLimitM3 then
              pctColor = ColorText["text_positive"] or ""
            elseif currentLimitM3 < gameLimitM3 then
              pctColor = ColorText["text_negative"] or ""
            end
            local pctText = (pctColor ~= "") and (pctColor .. draftPctStr .. "\027X") or draftPctStr
            sliderRow[6]:createText(pctText,
              { halign = "right", fontsize = config.mapFontSize })
          else
            -- Over slider budget: button to force-assign a slider to this ware.
            local capturedWare = wareData
            sliderRow[2]:setColSpan(4):createButton({ height = config.mapRowHeight })
                :setText(ReadText(SSA_PAGE, 1010), { halign = "center" })
            sliderRow[2].handlers.onClick = function()
              ssa.activeSliderWare = capturedWare.id
              menu.refreshInfoFrame()
            end
          end

        else
          -- ── View mode ──
          -- Row 1: icon+name | stock m³ | stock% | limit m³ | limit% | auto checkbox
          local stockPct = (limitM3 > 0)
              and math.min(100, stockM3 / limitM3 * 100)
              or  0
          local wareRow = tableInfo:addRow(true, {})
          wareRow[2]:createText(
            "\027[" .. wareData.icon .. "] " .. wareData.name,
            { halign = "left", fontsize = config.mapFontSize }
          )
          wareRow[3]:createText(fmt(stockM3) .. m3Suffix,           { halign = "right" })
          wareRow[4]:createText(string.format("%.2f%%", stockPct),  { halign = "right" })
          wareRow[5]:createText(fmt(limitM3) .. m3Suffix,           { halign = "right" })
          wareRow[6]:createText(string.format("%.2f%%", wareData.allocPct), { halign = "right" })
          wareRow[7]:createCheckBox(wareData.isAuto, { active = false,
            height = config.mapRowHeight, width = config.mapRowHeight })

          -- Row 2 (sub-row): dimmed item counts for stock and limit.
          local subRow = tableInfo:addRow(false, {})
          subRow[3]:createText(dimColor .. fmt(wareData.stock) .. "\027X",
            { halign = "right", fontsize = config.mapFontSize })
          subRow[5]:createText(dimColor .. fmt(wareData.limit) .. "\027X",
            { halign = "right", fontsize = config.mapFontSize })
        end
      end  -- for each ware
    end  -- if isExpanded
  end  -- for each type
end

-- Bottom button bar.
-- Edit mode:  [Cancel] [gap] [Reset All] [gap] [Save]  — equal-width buttons, half-width gaps.
-- View mode:  [                          ] [gap] [Edit] — Edit disabled if nothing is expanded.
local function addBottomButtons(tableButton, station)
  local row = tableButton:addRow("info_button_bottom", { fixed = true })

  if ssa.editEnabled then
    -- Cancel: exit edit mode, discard drafts.
    row[1]:createButton({ y = Helper.borderSize })
        :setText(ReadText(SSA_PAGE, 1006), { halign = "center" })
    row[1].handlers.onClick = function()
      ssa.editEnabled      = false
      ssa.draftLimits      = {}
      ssa.activeSliderWare = nil
      menu.refreshInfoFrame()
    end

    -- Reset All: clear every stock-limit override on this station.
    row[3]:createButton({ y = Helper.borderSize })
        :setText(ReadText(SSA_PAGE, 1004), { halign = "center" })
    row[3].handlers.onClick = function()
      local nover = tonumber(C.GetNumContainerStockLimitOverrides(station))
      if nover and nover > 0 then
        local obuf = ffi.new("UIWareInfo[?]", nover)
        nover = tonumber(C.GetContainerStockLimitOverrides(obuf, nover, station))
        for i = 0, nover - 1 do
          ClearContainerStockLimitOverride(station, ffi.string(obuf[i].ware))
        end
      end
      ssa.draftLimits      = {}
      ssa.activeSliderWare = nil
      menu.refreshInfoFrame()
    end

    -- Save: apply draft limits, exit edit mode.
    row[5]:createButton({ y = Helper.borderSize })
        :setText(ReadText(SSA_PAGE, 1003), { halign = "center" })
    row[5].handlers.onClick = function()
      for ware, newLimit in pairs(ssa.draftLimits) do
        if newLimit > 0 then
          SetContainerStockLimitOverride(station, ware, newLimit)
        else
          ClearContainerStockLimitOverride(station, ware)
        end
      end
      ssa.editEnabled      = false
      ssa.draftLimits      = {}
      ssa.activeSliderWare = nil
      menu.refreshInfoFrame()
    end
  else
    -- Edit: enter edit mode, aligned at the Save (col 5) position.
    -- Disabled unless a storage type is currently expanded.
    local canEdit = (ssa.expandedType ~= nil)
    row[5]:createButton({ y = Helper.borderSize, active = canEdit })
        :setText(ReadText(SSA_PAGE, 1005), { halign = "center" })
    if canEdit then
      row[5].handlers.onClick = function()
        ssa.editEnabled = true
        Pause()
        menu.refreshInfoFrame()
      end
    end
  end
end

-- ─── submenu builder ─────────────────────────────────────────────────────────

local function createStorageSubmenu(inputframe, instance)
  -- Temporary fix: the right-side panel uses infoFrame2.
  if instance == "right" then
    inputframe = menu.infoFrame2
  end

  local frameHeight = inputframe.properties.height
  resolveInfoSubmenuObject()

  -- Frame border (V9 only).
  local infoBorder = nil
  if ssa.isV9 then
    infoBorder = inputframe:addFrameBorder("ssa_storagealloc", {
      offsetBottom = Helper.standardContainerOffset,
      active       = menu.panelState[instance .. "menu"],
      color        = Helper.getFrameBorderColor(menu, menu.panelState[instance .. "menu"],
                       menu.panelPins[instance .. "menu"]),
      linewidth    = Helper.getFrameBorderLineWidth(menu, menu.panelState[instance .. "menu"]),
    })
    Helper.setFrameBorderIcon(menu, infoBorder, instance, menu.sideBarWidth / 2)
  end

  local tableInfo = addInfoTable(inputframe, infoBorder)

  -- Pre-V9: show the tab title as a header row inside the table.
  if not ssa.isV9 then
    local row = tableInfo:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
    row[1]:setColSpan(6):createText(ReadText(SSA_PAGE, 1), Helper.headerRowCenteredProperties)
  end

  setupStorageSubmenuRows(tableInfo, menu.infoSubmenuObject)

  restoreTableSelection(tableInfo, instance)

  -- Header strip (orders menu header).
  local tableHeader = ssa.isV9
      and menu.createOrdersMenuHeader(inputframe, infoBorder, instance)
      or  menu.createOrdersMenuHeader(inputframe, instance)
  tableInfo.properties.y = tableHeader.properties.y + tableHeader:getFullHeight() + Helper.borderSize

  local isLeft    = instance == "left"
  local isStation = menu.infoSubmenuObject and (tonumber(menu.infoSubmenuObject) ~= 0)
      and C.IsComponentClass(menu.infoSubmenuObject, "station")

  -- Bottom buttons table (always shown for valid stations).
  if isStation then
    local tableButton = inputframe:addTable(5, ssa.isV9 and {
      tabOrder          = 2,
      backgroundID      = "solid",
      backgroundColor   = Color["container_subsection_background"] or nil,
      backgroundPadding = 0,
      frameborder       = infoBorder and infoBorder.id or nil,
    } or {
      tabOrder = 2,
    })
    -- 3 equal-width buttons (25% each) with half-width gaps (12%) between.
    tableButton:setColWidthPercent(1, 25)
    tableButton:setColWidthPercent(2, 12)
    tableButton:setColWidthPercent(3, 26)
    tableButton:setColWidthPercent(4, 12)
    -- col 5 fills the remainder (~25%)

    addBottomButtons(tableButton, menu.infoSubmenuObject)

    local infoH   = tableInfo:getFullHeight()
    local buttonH = tableButton:getFullHeight()
    if tableInfo.properties.y + infoH + buttonH + Helper.borderSize + Helper.frameBorder < frameHeight then
      tableButton.properties.y = tableInfo.properties.y + infoH + Helper.borderSize
    else
      tableButton.properties.y                = frameHeight - Helper.frameBorder - buttonH
      tableInfo.properties.maxVisibleHeight   = tableButton.properties.y - Helper.borderSize - tableInfo.properties.y
    end

    if isLeft then menu.playerinfotable:addConnection(1, 2, true) end
    tableHeader:addConnection(isLeft and 2 or 1, isLeft and 2 or 3, true)
    tableInfo:addConnection(isLeft and 3 or 2, isLeft and 2 or 3)
    tableButton:addConnection(isLeft and 4 or 3, isLeft and 2 or 3)
  else
    tableInfo.properties.maxVisibleHeight = frameHeight - tableInfo.properties.y - Helper.frameBorder

    if isLeft then menu.playerinfotable:addConnection(1, 2, true) end
    tableHeader:addConnection(isLeft and 2 or 1, isLeft and 2 or 3, true)
    tableInfo:addConnection(isLeft and 3 or 2, isLeft and 2 or 3)
  end
end

-- ─── kuertee callbacks ────────────────────────────────────────────────────────

-- Called by kuertee UI Extensions for any unknown infoMode — guard with mode check.
function ssa.onInfoSubMenuCreate(infoFrame, instance)
  local activeMode = (instance == "right") and menu.infoMode.right or menu.infoMode.left
  if activeMode ~= SSA_CATEGORY then return end
  createStorageSubmenu(infoFrame, instance)
end

-- Allow the tab only for player-owned stations.
function ssa.onInfoSubMenuIsValidFor(object, mode)
  if mode ~= SSA_CATEGORY then return false end
  if not object or object == 0 then return false end
  local classId, isPlayerOwned = GetComponentData(object, "realclassid", "isplayerowned")
  return classId ~= nil and Helper.isComponentClass(classId, "station") and isPlayerOwned
end

function ssa.onInfoSubMenuToShow(object, mode)
  if mode ~= SSA_CATEGORY then return nil end
  return ssa.onInfoSubMenuIsValidFor(object, mode)
end

-- ─── init ────────────────────────────────────────────────────────────────────

local function init()
  menu = Helper.getMenu("MapMenu")
  if not menu then
    DebugError("station_storage_allocation: MapMenu not found – is kuertee_ui_extensions loaded?")
    return
  end

  config = type(menu.uix_getConfig) == "function" and menu.uix_getConfig() or {}

  -- Insert the tab into config.infoCategories after "objectinfo".
  if config.infoCategories then
    local objectInfoIdx = nil
    local ssaTabFound   = false
    for i, entry in ipairs(config.infoCategories) do
      if entry.category == "objectinfo"  then objectInfoIdx = i end
      if entry.category == SSA_CATEGORY  then ssaTabFound   = true end
    end
    if not ssaTabFound and objectInfoIdx then
      table.insert(config.infoCategories, objectInfoIdx + 1, {
        category        = SSA_CATEGORY,
        name            = ReadText(SSA_PAGE, 1),
        icon            = "stationbuildst_lsov",
        helpOverlayID   = "chem_station_storage_alloc",
        helpOverlayText = ReadText(SSA_PAGE, 2),
      })
    end
  end

  menu.registerCallback("info_sub_menu_to_show",     ssa.onInfoSubMenuToShow)
  menu.registerCallback("info_sub_menu_is_valid_for", ssa.onInfoSubMenuIsValidFor)
  menu.registerCallback("info_sub_menu_create",       ssa.onInfoSubMenuCreate)
end

Register_OnLoad_Init(init)
