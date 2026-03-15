-- module_recent.lua — Simple UI
-- Módulo: Recent Books.
-- Substitui a parte "recent" de recentbookswidget.lua.

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local Screen          = Device.screen
local _               = require("gettext")

local logger  = require("logger")
local _SH = nil
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "desktop_modules/module_books_shared")
        if ok and m then _SH = m
        else logger.warn("simpleui: module_recent: cannot load module_books_shared: " .. tostring(m)) end
    end
    return _SH
end

local UI      = require("ui")
local PAD     = UI.PAD
local PAD2    = UI.PAD2
local MOD_GAP = UI.MOD_GAP
local LABEL_H = UI.LABEL_H

local RB_PCT_FONT_SIZE = Screen:scaleBySize(10)  -- "XX% Read" label font size

local _CLR_TEXT_DARK = Blitbuffer.gray(0.20)

local M = {}

M.id          = "recent"
M.name        = _("Recent Books")
M.label       = _("Recent Books")
M.enabled_key = "recent"
M.default_on  = true

function M.build(w, ctx)
    if not ctx.recent_fps or #ctx.recent_fps == 0 then return nil end

    local SH      = getSH()
    local cols    = math.min(#ctx.recent_fps, 5)
    local cw      = SH.RECENT_W
    local ch      = SH.RECENT_H
    local inner_w = w - PAD * 2
    -- Gap between columns: distribute leftover space across (cols-1) gaps.
    -- Previously always divided by 4 regardless of how many books exist,
    -- which gave wrong spacing when fewer than 5 books are present.
    local gap     = cols > 1 and math.floor((inner_w - cols * cw) / (cols - 1)) or 0

    local row = HorizontalGroup:new{ align = "top" }
    for i = 1, cols do
        local fp    = ctx.recent_fps[i]
        local bd    = SH.getBookData(fp, ctx.prefetched and ctx.prefetched[fp], ctx.db_conn)
        local cover = SH.getBookCover(fp, cw, ch) or SH.coverPlaceholder(bd.title, cw, ch)

        local cell = VerticalGroup:new{
            align = "left",
            cover,
            SH.vspan(SH.RB_GAP1, ctx.vspan_pool),
            SH.progressBar(cw, bd.percent, SH.RB_BAR_H),
            SH.vspan(SH.RB_GAP2, ctx.vspan_pool),
            TextWidget:new{
                text    = string.format("%d%% Read", math.floor((bd.percent or 0) * 100)),
                face    = Font:getFace("smallinfofont", RB_PCT_FONT_SIZE),
                bold    = true,
                fgcolor = _CLR_TEXT_DARK,
                width   = cw,
            },
        }

        local tappable = InputContainer:new{
            dimen    = Geom:new{ w = cw, h = SH.RECENT_CELL_H },
            [1]      = cell,
            _fp      = fp,
            _open_fn = ctx.open_fn,
        }
        tappable.ges_events = {
            TapBook = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return tappable.dimen end,
                },
            },
        }
        function tappable:onTapBook()
            if self._open_fn then self._open_fn(self._fp) end
            return true
        end

        row[#row + 1] = FrameContainer:new{
            bordersize   = 0, padding = 0,
            padding_left = (i > 1) and gap or 0,
            tappable,
        }
    end

    return FrameContainer:new{
        bordersize = 0, padding = PAD, padding_top = 0, padding_bottom = 0,
        row,
    }
end

function M.getHeight(_ctx)
    return LABEL_H + getSH().RECENT_CELL_H
end

M.getMenuItems = nil

return M
