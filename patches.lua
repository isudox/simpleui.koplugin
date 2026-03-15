-- patches.lua — Simple UI
-- All monkey-patches applied to KOReader on plugin load:
--   FileManager.setupLayout  (navbar injection + homescreen auto-open)
--   FileChooser.init         (corrected height)
--   BookList.new             (corrected height)
--   Menu.new + FMColl        (collections with corrected height)
--   SortWidget.new + PathChooser.new (fullscreen widgets)
--   UIManager.show           (universal navbar injection)
--   UIManager.close          (tab restore + homescreen on close)
--   Menu.init                (hide pagination bar)

local UIManager  = require("ui/uimanager")
local Screen     = require("device").screen
local logger     = require("logger")
local _          = require("gettext")

local Config    = require("config")
local UI        = require("ui")
local Bottombar = require("bottombar")

local M = {}

-- Reusable empty table for UIManager.show varargs when no extra args are passed (#9).
local _EMPTY = {}

-- ---------------------------------------------------------------------------
-- Shared helpers used across multiple patches
-- ---------------------------------------------------------------------------

-- Delegates to Bottombar to avoid duplicating the same function here (#3).
local function setActiveAndRefreshFM(plugin, action_id, tabs)
    return Bottombar.setActiveAndRefreshFM(plugin, action_id, tabs)
end

-- ---------------------------------------------------------------------------
-- _patchFileManagerClass
-- ---------------------------------------------------------------------------

function M.patchFileManagerClass(plugin)
    local FileManager      = require("apps/filemanager/filemanager")
    local orig_setupLayout = FileManager.setupLayout
    plugin._orig_fm_setup  = orig_setupLayout

    FileManager.setupLayout = function(fm_self)
        local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
        fm_self._navbar_height = Bottombar.TOTAL_H() + (topbar_on and require("topbar").TOTAL_TOP_H() or 0)

        -- Patch FileChooser.init once to correct its height.
        local FileChooser = require("ui/widget/filechooser")
        if not FileChooser._navbar_patched then
            local orig_fc_init   = FileChooser.init
            plugin._orig_fc_init = orig_fc_init
            FileChooser._navbar_patched = true
            FileChooser.init = function(fc_self)
                if fc_self.height == nil and fc_self.width == nil then
                    fc_self.height = UI.getContentHeight()
                    fc_self.y      = UI.getContentTop()
                end
                orig_fc_init(fc_self)
            end
        end

        orig_setupLayout(fm_self)

        -- Replace the right title bar button icon.
        local PLUS_ALT_ICON = Config.ICON.plus_alt
        local tb = fm_self.title_bar
        if tb and tb.right_button then
            local function setPlusAltIcon(btn)
                if btn.image then
                    btn.image.file = PLUS_ALT_ICON
                    btn.image:free(); btn.image:init()
                end
            end
            setPlusAltIcon(tb.right_button)
            local orig_setRightIcon = tb.setRightIcon
            tb.setRightIcon = function(tb_self, icon, ...)
                local result = orig_setRightIcon(tb_self, icon, ...)
                if icon == "plus" then
                    setPlusAltIcon(tb_self.right_button)
                    UIManager:setDirty(tb_self.show_parent, "ui", tb_self.dimen)
                end
                return result
            end
        end

        if tb and tb.left_button and tb.right_button then
            local rb = tb.right_button
            if rb.image then
                rb.image.file = Config.ICON.ko_menu
                rb.image:free(); rb.image:init()
            end
            rb.overlap_align  = nil
            rb.overlap_offset = { Screen:scaleBySize(18), 0 }
            rb.padding_left   = 0
            rb:update()
            tb.left_button.overlap_align  = nil
            tb.left_button.overlap_offset = { Screen:getWidth() + 100, 0 }
            tb.left_button.callback       = function() end
            tb.left_button.hold_callback  = function() end
        end
        if tb and tb.setTitle then tb:setTitle(_("Library")) end

        -- Store the inner widget reference for re-wrapping.
        local inner_widget
        if fm_self._navbar_inner then
            inner_widget = fm_self._navbar_inner
        else
            inner_widget          = fm_self[1]
            fm_self._navbar_inner = inner_widget
        end

        local tabs = Config.loadTabConfig()


        local navbar_container, wrapped, bar, topbar, bar_idx, topbar_on2, topbar_idx =
            UI.wrapWithNavbar(inner_widget, plugin.active_action, tabs)
        UI.applyNavbarState(fm_self, navbar_container, bar, topbar, bar_idx, topbar_on2, topbar_idx, tabs)
        fm_self[1] = wrapped

        pcall(function() plugin:_updateFMHomeIcon() end)

        -- Auto-open Homescreen on boot when "Start with Homescreen" is set.
        -- Unlike Continue (which is injected into the FM synchronously), Homescreen
        -- is a UIManager stack widget — it can only be shown after the FM is on
        -- the stack, so we defer to onShow via a flag.
        local _will_autoopen_homescreen = (
            G_reader_settings:readSetting("start_with", "filemanager") == "homescreen_simpleui"
            and Config.tabInTabs("homescreen", tabs)
        )
        if _will_autoopen_homescreen then
            plugin.active_action = "homescreen"
            fm_self._hs_autoopen_pending = true
        end

        -- onShow: fix the bar after FM is on the stack.
        local orig_onShow = fm_self.onShow
        fm_self.onShow = function(this)
            if orig_onShow then orig_onShow(this) end
            Bottombar.resizePaginationButtons(this.file_chooser or this, Bottombar.getPaginationIconSize())
            -- Note: orig_onShow already calls setDirty on the FM. We only need
            -- to dirty the navbar_container if we replace the bar below.

            -- Auto-open Homescreen: deferred from setupLayout because the FM
            -- must be on the UIManager stack before UIManager:show() can be called.
            if this._hs_autoopen_pending then
                this._hs_autoopen_pending = nil
                UIManager:scheduleIn(0, function()
                    local ok_hs, HS = pcall(require, "homescreen")
                    if ok_hs and HS then
                        local on_qa_tap = function(aid) plugin:_onTabTap(aid, this) end
                        if not plugin._goalTapCallback then plugin:addToMainMenu({}) end
                        HS.show(on_qa_tap, plugin._goalTapCallback)
                    end
                end)
                return
            end

            if this._navbar_container then
                local t = Config.loadTabConfig()
                plugin.active_action = "home"
                Bottombar.replaceBar(this, Bottombar.buildBarWidget("home", t), t)
                UIManager:setDirty(this, "ui")
            end
        end

        plugin:_registerTouchZones(fm_self)

        fm_self.onPathChanged = function(this, new_path)
            local t          = Config.loadTabConfig()
            local new_active = M._resolveTabForPath(new_path, t)
            plugin.active_action = new_active
            if this._navbar_container then
                Bottombar.replaceBar(this, Bottombar.buildBarWidget(new_active, t), t)
                UIManager:setDirty(this, "ui")
            end
            pcall(function() plugin:_updateFMHomeIcon() end)
        end
    end
end

-- Resolves the active tab from the current filesystem path.
function M._resolveTabForPath(path, tabs)
    if not path then return nil end
    path = path:gsub("/$", "")
    local home_dir = G_reader_settings:readSetting("home_dir")
    if home_dir then home_dir = home_dir:gsub("/$", "") end
    for _i, tab_id in ipairs(tabs) do
        if tab_id == "home" then
            if home_dir and path == home_dir then return "home" end
        elseif tab_id:match("^custom_qa_%d+$") then
            local cfg = Config.getCustomQAConfig(tab_id)
            if cfg.path then
                local cfg_path = cfg.path:gsub("/$", "")
                if path == cfg_path then return tab_id end
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- _patchStartWithMenu
-- ---------------------------------------------------------------------------

function M.patchStartWithMenu()
    local ok_fmm, FileManagerMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if not (ok_fmm and FileManagerMenu) then return end
    -- Guard: only patch once. Without this, every return from the reader
    -- wraps getStartWithMenuTable again, inserting duplicate entries
    -- each time the menu is opened.
    if FileManagerMenu._simpleui_startwith_patched then return end
    local orig_fn = FileManagerMenu.getStartWithMenuTable
    if not orig_fn then return end
    FileManagerMenu._simpleui_startwith_patched = true
    FileManagerMenu._simpleui_startwith_orig    = orig_fn
    FileManagerMenu.getStartWithMenuTable = function(fmm_self)
        local result = orig_fn(fmm_self)
        local sub = result.sub_item_table
        if type(sub) ~= "table" then return result end
        -- Guard: only patch once per open (defensive).
        -- Guard against entries already being present (belt-and-suspenders).
        local has_homescreen = false
        for _i, item in ipairs(sub) do
            if item.text == _("Home Screen") and item.radio then has_homescreen = true end
        end
        local insert_pos = math.max(1, #sub)
        if not has_homescreen then
            table.insert(sub, insert_pos, {
                text         = _("Home Screen"),
                checked_func = function()
                    return G_reader_settings:readSetting("start_with", "filemanager") == "homescreen_simpleui"
                end,
                callback = function()
                    G_reader_settings:saveSetting("start_with", "homescreen_simpleui")
                end,
                radio = true,
            })
        end
        local orig_text_func = result.text_func
        result.text_func = function()
            local sw = G_reader_settings:readSetting("start_with", "filemanager")
            if sw == "homescreen_simpleui" then return _("Start with") .. ": " .. _("Home Screen") end
            return orig_text_func and orig_text_func() or _("Start with")
        end
        return result
    end
end

-- ---------------------------------------------------------------------------
-- _patchBookList
-- ---------------------------------------------------------------------------

function M.patchBookList(plugin)
    local BookList    = require("ui/widget/booklist")
    local orig_bl_new = BookList.new
    plugin._orig_booklist_new = orig_bl_new
    BookList.new = function(class, attrs, ...)
        attrs = attrs or {}
        if not attrs.height and not attrs._navbar_height_reduced then
            attrs.height                 = UI.getContentHeight()
            attrs.y                      = UI.getContentTop()
            attrs._navbar_height_reduced = true
        end
        return orig_bl_new(class, attrs, ...)
    end
end

-- ---------------------------------------------------------------------------
-- _patchCollections
-- ---------------------------------------------------------------------------

function M.patchCollections(plugin)
    local ok, FMColl = pcall(require, "apps/filemanager/filemanagercollection")
    if not (ok and FMColl) then return end
    local Menu          = require("ui/widget/menu")
    local orig_menu_new = Menu.new
    plugin._orig_menu_new    = orig_menu_new
    plugin._orig_fmcoll_show = FMColl.onShowCollList
    local patch_depth = 0

    local orig_onShowCollList = FMColl.onShowCollList
    FMColl.onShowCollList = function(fmc_self, ...)
        patch_depth = patch_depth + 1
        local ok2, result = pcall(orig_onShowCollList, fmc_self, ...)
        patch_depth = patch_depth - 1
        if not ok2 then error(result) end
        return result
    end

    Menu.new = function(class, attrs, ...)
        attrs = attrs or {}
        if patch_depth > 0
                and attrs.covers_fullscreen and attrs.is_borderless
                and attrs.is_popout == false
                and not attrs.height and not attrs._navbar_height_reduced then
            attrs.height                 = UI.getContentHeight()
            attrs.y                      = UI.getContentTop()
            attrs._navbar_height_reduced = true
            attrs.name                   = attrs.name or "coll_list"
        end
        return orig_menu_new(class, attrs, ...)
    end

    -- Patch ReadCollection to keep the SimpleUI collections pool in sync when
    -- a collection is renamed or deleted from within KOReader.
    local ok_rc, RC = pcall(require, "readcollection")
    if ok_rc and RC then
        -- Removes a collection name from the SimpleUI selected list and
        -- cover-override table.
        local function _removeFromPool(name)
            local ok_cw, CW = pcall(require, "collectionswidget")
            if not (ok_cw and CW) then return end
            local selected = CW.getSelected()
            local changed  = false
            for i = #selected, 1, -1 do
                if selected[i] == name then
                    table.remove(selected, i)
                    changed = true
                end
            end
            if changed then CW.saveSelected(selected) end
            local overrides = CW.getCoverOverrides()
            if overrides[name] then
                overrides[name] = nil
                CW.saveCoverOverrides(overrides)
            end
        end

        -- Renames a collection entry in the SimpleUI selected list and
        -- cover-override table.
        local function _renameInPool(old_name, new_name)
            local ok_cw, CW = pcall(require, "collectionswidget")
            if not (ok_cw and CW) then return end
            local selected = CW.getSelected()
            local changed  = false
            for i, name in ipairs(selected) do
                if name == old_name then
                    selected[i] = new_name
                    changed = true
                end
            end
            if changed then CW.saveSelected(selected) end
            local overrides = CW.getCoverOverrides()
            if overrides[old_name] then
                overrides[new_name] = overrides[old_name]
                overrides[old_name] = nil
                CW.saveCoverOverrides(overrides)
            end
        end

        -- Patch removeCollection (called when the user deletes a collection).
        if type(RC.removeCollection) == "function" then
            local orig_remove = RC.removeCollection
            plugin._orig_rc_remove = orig_remove
            RC.removeCollection = function(rc_self, coll_name, ...)
                local result = orig_remove(rc_self, coll_name, ...)
                pcall(function()
                    _removeFromPool(coll_name)
                    -- Remove this collection from all custom QA configs.
                    Config.purgeQACollection(coll_name)
                    Config.invalidateTabsCache()
                    plugin:_scheduleRebuild()
                end)
                return result
            end
        end

        -- Patch renameCollection (called when the user renames a collection).
        if type(RC.renameCollection) == "function" then
            local orig_rename = RC.renameCollection
            plugin._orig_rc_rename = orig_rename
            RC.renameCollection = function(rc_self, old_name, new_name, ...)
                local result = orig_rename(rc_self, old_name, new_name, ...)
                pcall(function()
                    _renameInPool(old_name, new_name)
                    -- Update collection references in all custom QA configs.
                    Config.renameQACollection(old_name, new_name)
                    plugin:_scheduleRebuild()
                end)
                return result
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- _patchFullscreenWidgets
-- ---------------------------------------------------------------------------

function M.patchFullscreenWidgets(plugin)
    local ok_sw, SortWidget  = pcall(require, "ui/widget/sortwidget")
    local ok_pc, PathChooser = pcall(require, "ui/widget/pathchooser")

    if ok_sw and SortWidget then
        local ok_tb, TitleBar = pcall(require, "ui/widget/titlebar")
        local orig_sw_new     = SortWidget.new
        plugin._orig_sortwidget_new = orig_sw_new
        SortWidget.new = function(class, attrs, ...)
            attrs = attrs or {}
            if attrs.covers_fullscreen and not attrs._navbar_height_reduced then
                attrs.height                 = UI.getContentHeight()
                attrs.y                      = UI.getContentTop()
                attrs._navbar_height_reduced = true
            end
            local orig_tb_new
            if ok_tb and TitleBar and attrs.covers_fullscreen then
                orig_tb_new = TitleBar.new
                TitleBar.new = function(tb_class, tb_attrs, ...)
                    tb_attrs = tb_attrs or {}
                    tb_attrs.title_h_padding = Screen:scaleBySize(24)
                    return orig_tb_new(tb_class, tb_attrs, ...)
                end
            end
            -- L5: use pcall so TitleBar.new is restored even when orig_sw_new raises.
            local ok_sw2, sw_or_err = pcall(orig_sw_new, class, attrs, ...)
            if orig_tb_new then TitleBar.new = orig_tb_new end  -- always restored
            if not ok_sw2 then error(sw_or_err, 2) end
            local sw = sw_or_err
            if not attrs.covers_fullscreen then return sw end
            pcall(function()
                local vfooter = sw[1] and sw[1][1] and sw[1][1][2] and sw[1][1][2][1]
                if vfooter and vfooter[3] and vfooter[3].dimen then
                    vfooter[3].dimen.h = 0
                end
            end)
            pcall(function()
                local orig_populate = sw._populateItems
                if type(orig_populate) == "function" then
                    sw._populateItems = function(self_sw, ...)
                        local result = orig_populate(self_sw, ...)
                        UIManager:setDirty(nil, "ui")
                        return result
                    end
                end
            end)
            return sw
        end
    end

    if ok_pc and PathChooser then
        local orig_pc_new = PathChooser.new
        plugin._orig_pathchooser_new = orig_pc_new
        PathChooser.new = function(class, attrs, ...)
            attrs = attrs or {}
            if attrs.covers_fullscreen and not attrs._navbar_height_reduced then
                attrs.height                 = UI.getContentHeight()
                attrs.y                      = UI.getContentTop()
                attrs._navbar_height_reduced = true
            end
            return orig_pc_new(class, attrs, ...)
        end
    end
end

-- ---------------------------------------------------------------------------
-- _patchUIManagerShow
-- ---------------------------------------------------------------------------

function M.patchUIManagerShow(plugin)
    local orig_show = UIManager.show
    plugin._orig_uimanager_show = orig_show
    local _show_depth = 0

    local INJECT_NAMES = { collections = true, history = true, coll_list = true, homescreen = true }

    UIManager.show = function(um_self, widget, ...)
        -- B5: capture varargs NOW, before the pcall closure, because Lua does not
        -- propagate '...' into nested functions.
        -- #9: only allocate a new table when there are actual extra arguments;
        -- the vast majority of UIManager:show calls pass none, so we reuse _EMPTY.
        local n_extra    = select("#", ...)
        local extra_args = n_extra > 0 and { ... } or _EMPTY
        _show_depth = _show_depth + 1

        -- B5: wrap the entire body so _show_depth is ALWAYS decremented, even
        -- when orig_show or any injection step raises an error.
        local ok, result = pcall(function()

        local should_inject = _show_depth == 1
            and widget
            and not widget._navbar_injected
            and not widget._navbar_skip_inject
            and widget ~= plugin.ui
            and widget.covers_fullscreen
            and widget.title_bar ~= nil
            and (widget._navbar_height_reduced or (widget.name and INJECT_NAMES[widget.name]))

        if not should_inject then
            return orig_show(um_self, widget, table.unpack(extra_args))
        end

        widget._navbar_injected = true

        if not widget._navbar_height_reduced then
            local content_h   = UI.getContentHeight()
            local content_top = UI.getContentTop()
            if widget.dimen then
                widget.dimen.h = content_h
                widget.dimen.y = content_top
            end
            pcall(function()
                if widget[1] and widget[1].dimen then
                    widget[1].dimen.h = content_h
                    widget[1].dimen.y = content_top
                end
            end)
            widget._navbar_height_reduced = true
        end

        -- Adjust title bar buttons for injected widgets.
        pcall(function()
            local tb = widget.title_bar
            if not tb then return end
            if tb.left_button then
                tb.left_button.overlap_align  = nil
                tb.left_button.overlap_offset = { Screen:scaleBySize(13), 0 }
            end
        end)
        pcall(function()
            local rb = widget.title_bar and widget.title_bar.right_button
            if rb then
                rb.dimen         = require("ui/geometry"):new{ w = 0, h = 0 }
                rb.callback      = function() end
                rb.hold_callback = function() end
            end
        end)

        local tabs          = Config.loadTabConfig()
        local action_before = plugin.active_action
        local tabs_set      = {}
        for _i, id in ipairs(tabs) do tabs_set[id] = true end

        local effective_action = nil

        if widget.name == "collections" and Config.isFavoritesWidget(widget) and tabs_set["favorites"] then
            effective_action = setActiveAndRefreshFM(plugin, "favorites", tabs)
            pcall(function()
                local orig_onReturn = widget.onReturn
                if not orig_onReturn then return end
                widget.onReturn = function(w_self, ...)
                    plugin:_restoreTabInFM(w_self._navbar_tabs, action_before)
                    return orig_onReturn(w_self, ...)
                end
            end)
        elseif widget.name == "history" and tabs_set["history"] then
            effective_action = setActiveAndRefreshFM(plugin, "history", tabs)
        elseif widget.name == "homescreen" and tabs_set["homescreen"] then
            effective_action = setActiveAndRefreshFM(plugin, "homescreen", tabs)
        elseif widget.name == "coll_list"
               or (widget.name == "collections" and not Config.isFavoritesWidget(widget)) then
            if tabs_set["collections"] then
                effective_action = setActiveAndRefreshFM(plugin, "collections", tabs)
            end
        end

        local display_action = effective_action or action_before
        if not widget._navbar_inner then widget._navbar_inner = widget[1] end

        local navbar_container, wrapped, bar, topbar, bar_idx, topbar_on, topbar_idx =
            UI.wrapWithNavbar(widget._navbar_inner, display_action, tabs)
        UI.applyNavbarState(widget, navbar_container, bar, topbar, bar_idx, topbar_on, topbar_idx, tabs)
        widget._navbar_prev_action = action_before
        widget[1]                  = wrapped
        plugin:_registerTouchZones(widget)

        -- Register the same top-of-screen tap/swipe zones that the FileManager
        -- uses to open the KOReader main menu (FileManagerMenu:initGesListener).
        -- This makes the gesture work consistently on all injected fullscreen
        -- pages (Collections, History, Homescreen, etc.) without requiring each
        -- widget to implement it individually.
        pcall(function()
            if not widget.registerTouchZones then return end
            local DTAP_ZONE_MENU     = G_defaults:readSetting("DTAP_ZONE_MENU")
            local DTAP_ZONE_MENU_EXT = G_defaults:readSetting("DTAP_ZONE_MENU_EXT")
            if not DTAP_ZONE_MENU or not DTAP_ZONE_MENU_EXT then return end
            local fm = plugin.ui
            widget:registerTouchZones({
                {
                    id          = "simpleui_menu_tap",
                    ges         = "tap",
                    screen_zone = {
                        ratio_x = DTAP_ZONE_MENU.x, ratio_y = DTAP_ZONE_MENU.y,
                        ratio_w = DTAP_ZONE_MENU.w, ratio_h = DTAP_ZONE_MENU.h,
                    },
                    handler = function(ges)
                        if fm and fm.menu then return fm.menu:onTapShowMenu(ges) end
                    end,
                },
                {
                    id          = "simpleui_menu_ext_tap",
                    ges         = "tap",
                    screen_zone = {
                        ratio_x = DTAP_ZONE_MENU_EXT.x, ratio_y = DTAP_ZONE_MENU_EXT.y,
                        ratio_w = DTAP_ZONE_MENU_EXT.w, ratio_h = DTAP_ZONE_MENU_EXT.h,
                    },
                    overrides = { "simpleui_menu_tap" },
                    handler = function(ges)
                        if fm and fm.menu then return fm.menu:onTapShowMenu(ges) end
                    end,
                },
                {
                    id          = "simpleui_menu_swipe",
                    ges         = "swipe",
                    screen_zone = {
                        ratio_x = DTAP_ZONE_MENU.x, ratio_y = DTAP_ZONE_MENU.y,
                        ratio_w = DTAP_ZONE_MENU.w, ratio_h = DTAP_ZONE_MENU.h,
                    },
                    handler = function(ges)
                        if fm and fm.menu then return fm.menu:onSwipeShowMenu(ges) end
                    end,
                },
                {
                    id          = "simpleui_menu_ext_swipe",
                    ges         = "swipe",
                    screen_zone = {
                        ratio_x = DTAP_ZONE_MENU_EXT.x, ratio_y = DTAP_ZONE_MENU_EXT.y,
                        ratio_w = DTAP_ZONE_MENU_EXT.w, ratio_h = DTAP_ZONE_MENU_EXT.h,
                    },
                    overrides = { "simpleui_menu_swipe" },
                    handler = function(ges)
                        if fm and fm.menu then return fm.menu:onSwipeShowMenu(ges) end
                    end,
                },
            })
        end)

        pcall(function()
            local rb = widget.return_button
            if rb and rb[1] then rb[1].width = UI.SIDE_M() end
        end)

        Bottombar.resizePaginationButtons(widget, Bottombar.getPaginationIconSize())

        orig_show(um_self, widget, table.unpack(extra_args))
        UIManager:setDirty(widget[1], "ui")

        -- If a new fullscreen widget was just shown while Homescreen is open,
        -- close Homescreen now (it's covered, so no visual flash) to free memory.
        -- This must run for ALL covers_fullscreen widgets — including ReaderUI
        -- which has no title_bar and therefore does not pass should_inject,
        -- but still covers the homescreen completely.
        end) -- end pcall wrapper (B5)
        _show_depth = _show_depth - 1  -- always decremented
        if not ok then
            logger.warn("simpleui: UIManager.show patch error:", tostring(result))
        end
        if _show_depth == 0 and widget and widget.covers_fullscreen
                and widget.name ~= "homescreen" then
            local stack = UI.getWindowStack()
            for _i, entry in ipairs(stack) do
                local w = entry.widget
                if w and w.name == "homescreen" then
                    UIManager:close(w)
                    break
                end
            end
        end
        return result
    end
end

-- ---------------------------------------------------------------------------
-- _patchUIManagerClose
-- ---------------------------------------------------------------------------

function M.patchUIManagerClose(plugin)
    local orig_close = UIManager.close
    plugin._orig_uimanager_close = orig_close

    UIManager.close = function(um_self, widget, ...)
        -- Fast path: skip all SimpleUI logic for non-fullscreen widgets (InfoMessage,
        -- dialogs, menus, etc.) — the vast majority of close() calls.
        -- Tab-restore only applies to injected fullscreen widgets; the HS re-open
        -- logic only applies to fullscreen widgets too.  Neither block runs for
        -- anything else, so we can return immediately and avoid the readSetting call.
        if not (widget and widget.covers_fullscreen) then
            return orig_close(um_self, widget, ...)
        end

        if widget and widget._navbar_injected
                and not widget._navbar_closing_intentionally then
            do -- restore tab on close
                -- coll_list is opened on top of the collections widget, so
                -- restoreTabInFM's should_skip would fire (another _navbar_injected
                -- widget is still on the stack). Force a direct restore to home instead.
                if widget.name == "coll_list" then
                    local ok_fm2, FM2 = pcall(require, "apps/filemanager/filemanager")
                    local fm = ok_fm2 and FM2 and FM2.instance
                    if fm and fm._navbar_container then
                        local t = Config.loadTabConfig()
                        -- Prefer the prev_action saved on the collections widget
                        -- sitting beneath coll_list in the stack (that reflects
                        -- what was active before the user entered collections).
                        local restored = nil
                        pcall(function()
                            for _i, entry in ipairs(UI.getWindowStack()) do
                                local w = entry.widget
                                if w and w ~= widget and w._navbar_injected
                                        and (w.name == "collections" or w.name == "coll_list") then
                                    restored = w._navbar_prev_action
                                    break
                                end
                            end
                        end)
                        -- fallback: resolve from current FM path
                        if not restored then
                            restored = (fm.file_chooser
                                        and M._resolveTabForPath(fm.file_chooser.path, t))
                                    or t[1] or "home"
                        end
                        plugin.active_action = restored
                        Bottombar.replaceBar(fm, Bottombar.buildBarWidget(restored, t), t)
                        UIManager:setDirty(fm, "ui")
                    end
                else
                    plugin:_restoreTabInFM(widget._navbar_tabs, widget._navbar_prev_action)
                end
            end
        end

        -- Use package.loaded to avoid pcall overhead — this runs on every
        -- UIManager:close() call, including trivial ones (InfoMessage, etc.).
        -- ReaderUI is only loaded when the reader has been opened at least once;
        -- if not loaded, closing_reader is false and no work is done.
        local ReaderUI = package.loaded["apps/reader/readerui"]
        local closing_reader = ReaderUI and widget and widget == ReaderUI.instance

        local result = orig_close(um_self, widget, ...)

        if closing_reader then
            plugin:_scheduleTopbarRefresh(0)
        end

        local start_with = G_reader_settings:readSetting("start_with", "filemanager")
        if start_with == "homescreen_simpleui"
                and widget
                and widget.covers_fullscreen
                and widget.name ~= "filemanager"
                and widget.name ~= "homescreen"
                and widget.name ~= "coll_list"
                and not widget._navbar_closing_intentionally then
            -- Re-open Homescreen after any fullscreen widget closes.
            -- HS._instance is nil here because patchUIManagerShow closes the
            -- homescreen synchronously when any covers_fullscreen widget opens
            -- (including ReaderUI).
            -- Use package.loaded: FileManager is always loaded when the plugin is active.
            local FM2 = package.loaded["apps/filemanager/filemanager"]
            local fm  = FM2 and FM2.instance
            local other_open = false
            local has_modal  = false
            -- Single pass over the stack: detect both a blocking fullscreen widget
            -- AND any lingering modal (non-fullscreen) widget at once, instead of
            -- two separate loops over the same table.
            pcall(function()
                for _i, entry in ipairs(UI.getWindowStack()) do
                    local w = entry.widget
                    if w and w ~= fm and w ~= widget then
                        if w.covers_fullscreen then
                            other_open = true; return   -- no need to look further
                        else
                            has_modal = true
                            -- keep iterating: a fullscreen widget further down
                            -- would set other_open and abort the whole re-open.
                        end
                    end
                end
            end)
            if not other_open and fm then

                local function _doShowHS()
                    -- homescreen is always in package.loaded at this point (plugin active).
                    -- Avoid pcall+require overhead on every reader/fullscreen close.
                    local HS = package.loaded["homescreen"]
                    if not HS or HS._instance then return end
                    -- Close any non-fullscreen widgets that were open on top of
                    -- the reader (ConfigDialog, touch menus, etc.) and are now
                    -- orphaned. Without this they sit above the homescreen and
                    -- intercept taps without being dismissable.
                    pcall(function()
                        local stack = UI.getWindowStack()
                        local to_close = {}
                        for _i, entry in ipairs(stack) do
                            local w = entry.widget
                            if w and w ~= fm and not w.covers_fullscreen then
                                to_close[#to_close + 1] = w
                            end
                        end
                        for _, w in ipairs(to_close) do
                            UIManager:close(w)
                        end
                    end)
                    local tabs = Config.loadTabConfig()
                    setActiveAndRefreshFM(plugin, "homescreen", tabs)
                    if not plugin._goalTapCallback then plugin:addToMainMenu({}) end
                    HS.show(
                        function(aid) plugin:_onTabTap(aid, fm) end,
                        plugin._goalTapCallback
                    )
                end

                if has_modal then
                    -- Defer: let KOReader finish closing modal widgets first.
                    UIManager:scheduleIn(0, _doShowHS)
                else
                    _doShowHS()
                end
            end
        end

        return result
    end
end

-- ---------------------------------------------------------------------------
-- _patchMenuInitForPagination
-- ---------------------------------------------------------------------------

function M.patchMenuInitForPagination(plugin)
    local Menu = require("ui/widget/menu")
    local TARGET_NAMES = {
        filemanager = true, history = true, collections = true, coll_list = true,
    }
    local orig_menu_init = Menu.init
    plugin._orig_menu_init = orig_menu_init

    Menu.init = function(menu_self, ...)
        orig_menu_init(menu_self, ...)
        if G_reader_settings:nilOrTrue("navbar_pagination_visible") then return end
        if not TARGET_NAMES[menu_self.name]
           and not (menu_self.covers_fullscreen
                    and menu_self.is_borderless
                    and menu_self.title_bar_fm_style) then
            return
        end
        local content = menu_self[1] and menu_self[1][1]
        if content then
            for i = #content, 1, -1 do
                if content[i] ~= menu_self.content_group then
                    table.remove(content, i)
                end
            end
        end
        menu_self._recalculateDimen = function(self_inner, no_recalculate_dimen)
            local saved_arrow = self_inner.page_return_arrow
            local saved_text  = self_inner.page_info_text
            local saved_info  = self_inner.page_info
            self_inner.page_return_arrow = nil
            self_inner.page_info_text    = nil
            self_inner.page_info         = nil
            local instance_fn = self_inner._recalculateDimen
            self_inner._recalculateDimen = nil
            local ok, err = pcall(function()
                self_inner:_recalculateDimen(no_recalculate_dimen)
            end)
            self_inner._recalculateDimen = instance_fn
            self_inner.page_return_arrow = saved_arrow
            self_inner.page_info_text    = saved_text
            self_inner.page_info         = saved_info
            if not ok then error(err, 2) end
        end
        menu_self:_recalculateDimen()
    end
end

-- ---------------------------------------------------------------------------
-- installAll / teardownAll
-- ---------------------------------------------------------------------------

function M.installAll(plugin)
    M.patchFileManagerClass(plugin)
    M.patchStartWithMenu()
    M.patchBookList(plugin)
    M.patchCollections(plugin)
    M.patchFullscreenWidgets(plugin)
    M.patchUIManagerShow(plugin)
    M.patchUIManagerClose(plugin)
    M.patchMenuInitForPagination(plugin)
end

function M.teardownAll(plugin)
    if plugin._orig_uimanager_show then
        UIManager.show  = plugin._orig_uimanager_show
        plugin._orig_uimanager_show = nil
    end
    if plugin._orig_uimanager_close then
        UIManager.close = plugin._orig_uimanager_close
        plugin._orig_uimanager_close = nil
    end
    local ok_bl, BookList = pcall(require, "ui/widget/booklist")
    if ok_bl and BookList and plugin._orig_booklist_new then
        BookList.new = plugin._orig_booklist_new; plugin._orig_booklist_new = nil
    end
    local ok_m, Menu = pcall(require, "ui/widget/menu")
    if ok_m and Menu then
        if plugin._orig_menu_new  then Menu.new  = plugin._orig_menu_new;  plugin._orig_menu_new  = nil end
        if plugin._orig_menu_init then Menu.init = plugin._orig_menu_init; plugin._orig_menu_init = nil end
    end
    local ok_fc2, FMColl = pcall(require, "apps/filemanager/filemanagercollection")
    if ok_fc2 and FMColl and plugin._orig_fmcoll_show then
        FMColl.onShowCollList = plugin._orig_fmcoll_show; plugin._orig_fmcoll_show = nil
    end
    local ok_rc, RC = pcall(require, "readcollection")
    if ok_rc and RC then
        if plugin._orig_rc_remove then RC.removeCollection = plugin._orig_rc_remove; plugin._orig_rc_remove = nil end
        if plugin._orig_rc_rename then RC.renameCollection = plugin._orig_rc_rename; plugin._orig_rc_rename = nil end
    end
    -- B4: restore SortWidget.new and PathChooser.new (were missing before).
    local ok_sw, SortWidget = pcall(require, "ui/widget/sortwidget")
    if ok_sw and SortWidget and plugin._orig_sortwidget_new then
        SortWidget.new = plugin._orig_sortwidget_new
        plugin._orig_sortwidget_new = nil
    end
    local ok_pch, PathChooser = pcall(require, "ui/widget/pathchooser")
    if ok_pch and PathChooser and plugin._orig_pathchooser_new then
        PathChooser.new = plugin._orig_pathchooser_new
        plugin._orig_pathchooser_new = nil
    end
    local ok_fch, FileChooser = pcall(require, "ui/widget/filechooser")
    if ok_fch and FileChooser and plugin._orig_fc_init then
        FileChooser.init            = plugin._orig_fc_init
        FileChooser._navbar_patched = nil
        plugin._orig_fc_init        = nil
    end
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FileManager and plugin._orig_fm_setup then
        FileManager.setupLayout = plugin._orig_fm_setup; plugin._orig_fm_setup = nil
    end
    local ok_fmm, FileManagerMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if ok_fmm and FileManagerMenu and FileManagerMenu._simpleui_startwith_patched then
        FileManagerMenu.getStartWithMenuTable       = FileManagerMenu._simpleui_startwith_orig
        FileManagerMenu._simpleui_startwith_orig    = nil
        FileManagerMenu._simpleui_startwith_patched = nil
    end
    -- Reset all module-level mutable state so a re-enable starts clean (A2).
    Config.reset()
    -- Release all cached module references so a re-enable loads fresh copies.
    local ok_reg, Registry = pcall(require, "desktop_modules/moduleregistry")
    if ok_reg and Registry then Registry.invalidate() end
end

return M