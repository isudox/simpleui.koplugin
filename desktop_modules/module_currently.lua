-- module_currently.lua — Simple UI
-- Currently Reading module: cover + title + author + progress bar + percentage.

local Device  = require("device")
local Screen  = Device.screen
local _       = require("gettext")
local logger  = require("logger")

local Blitbuffer      = require("ffi/blitbuffer")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")

local UI      = require("ui")
local PAD     = UI.PAD
local LABEL_H = UI.LABEL_H

-- Shared helpers — lazy-loaded.
local _SH = nil
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "desktop_modules/module_books_shared")
        if ok and m then _SH = m
        else logger.warn("simpleui: module_currently: cannot load module_books_shared: " .. tostring(m)) end
    end
    return _SH
end

-- Internal spacing — scaleBySize runs once at load time.
local COVER_GAP  = Screen:scaleBySize(12)  -- horizontal gap between cover and text column
local TITLE_GAP  = Screen:scaleBySize(4)   -- below title
local AUTHOR_GAP = Screen:scaleBySize(8)   -- below author
local BAR_H      = Screen:scaleBySize(6)   -- progress bar height
local BAR_GAP    = Screen:scaleBySize(6)   -- below progress bar
local PCT_GAP    = Screen:scaleBySize(3)   -- below percentage, before time-left

local _CLR_DARK = Blitbuffer.gray(0.20)
local _CLR_MID  = Blitbuffer.gray(0.45)

local M = {}

M.id          = "currently"
M.name        = _("Currently Reading")
M.label       = _("Currently Reading")
M.enabled_key = "currently"
M.default_on  = true

function M.build(w, ctx)
    if not ctx.current_fp then return nil end

    local SH = getSH()
    if not SH then return nil end

    local bd    = SH.getBookData(ctx.current_fp, ctx.prefetched and ctx.prefetched[ctx.current_fp], ctx.db_conn)
    local cover = SH.getBookCover(ctx.current_fp, SH.COVER_W, SH.COVER_H)
                  or SH.coverPlaceholder(bd.title, SH.COVER_W, SH.COVER_H)

    -- Text column width: total minus both side PADs, cover width, and cover gap.
    local tw = w - PAD - SH.COVER_W - COVER_GAP - PAD

    local meta = VerticalGroup:new{ align = "left" }

    meta[#meta+1] = TextWidget:new{
        text  = bd.title or "?",
        face  = Font:getFace("smallinfofont", Screen:scaleBySize(12)),
        bold  = true,
        width = tw,
    }
    meta[#meta+1] = VerticalSpan:new{ width = TITLE_GAP }

    if bd.authors and bd.authors ~= "" then
        meta[#meta+1] = TextWidget:new{
            text    = bd.authors,
            face    = Font:getFace("smallinfofont", Screen:scaleBySize(11)),
            fgcolor = _CLR_MID,
            width   = tw,
        }
        meta[#meta+1] = VerticalSpan:new{ width = AUTHOR_GAP }
    end

    meta[#meta+1] = SH.progressBar(tw, bd.percent, BAR_H)
    meta[#meta+1] = VerticalSpan:new{ width = BAR_GAP }

    meta[#meta+1] = TextWidget:new{
        text    = string.format("%d%% Read", math.floor((bd.percent or 0) * 100)),
        face    = Font:getFace("smallinfofont", Screen:scaleBySize(11)),
        bold    = true,
        fgcolor = _CLR_DARK,
        width   = tw,
    }

    local tl = SH.formatTimeLeft(bd.percent, bd.pages, bd.avg_time)
    if tl then
        meta[#meta+1] = VerticalSpan:new{ width = PCT_GAP }
        meta[#meta+1] = TextWidget:new{
            text    = tl:upper() .. " TO GO",
            face    = Font:getFace("smallinfofont", Screen:scaleBySize(9)),
            fgcolor = _CLR_MID,
            width   = tw,
        }
    end

    -- HorizontalGroup centres the meta column vertically against the cover.
    local row = HorizontalGroup:new{
        align = "center",
        FrameContainer:new{
            bordersize    = 0, padding = 0,
            padding_right = COVER_GAP,
            cover,
        },
        meta,
    }

    -- Outer container: horizontal padding only, no vertical padding.
    -- Height is pinned to exactly COVER_H so getHeight() is deterministic.
    local tappable = InputContainer:new{
        dimen    = Geom:new{ w = w, h = SH.COVER_H },
        _fp      = ctx.current_fp,
        _open_fn = ctx.open_fn,
        [1] = FrameContainer:new{
            bordersize    = 0,
            padding       = 0,
            padding_left  = PAD,
            padding_right = PAD,
            dimen         = Geom:new{ w = w, h = SH.COVER_H },
            row,
        },
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

    return tappable
end

function M.getHeight(_ctx)
    local SH = getSH()
    if not SH then return LABEL_H end
    -- LABEL_H: the section label above, injected by _buildContent.
    -- COVER_H: the widget itself — no vertical padding anywhere.
    return LABEL_H + SH.COVER_H
end

M.getMenuItems = nil

return M