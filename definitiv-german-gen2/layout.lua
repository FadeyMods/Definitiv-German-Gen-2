-- Kaesten und Positionen wie in der DE-ROM (mit den Texten, die nur in diesen Kaesten stehen:
-- Pokedex-Modi, Optionen, Wettbewerb, Kartenflip, Uhr, Diplom, Fotostudio, PC ...).
return function(W)
  local mod, R, rom, T, apply, log, ver = W.mod, W.R, W.rom, W.T, W.apply, W.log, W.ver
  local Assets, CM, info, gfxData = W.Assets, W.CM, W.info, W.gfxData
  local counts, failed, firstErr = W.counts, W.failed, W.firstErr
  local L, umgelegt, K = W.L, W.umgelegt, W.K
  local byte, concat, floor = string.byte, table.concat, math.floor
  -- ------------------------------------------------------------ Ja/Nein-Box (DE-_YesNoBox)
  -- Die Engine zeichnet die Box fest 6 Kacheln breit (fuer YES/NO).  Die DE-ROM macht sie 7 breit
  -- und rueckt eine Box an Spalte 14 auf Spalte 13 (sonst wuerde sie rechts aus dem Bild ragen).
  -- Erkannt wird eine Ja/Nein-Box daran, dass JA und NEIN in ihr stehen; ab dann wird sie (und ihr
  -- Inhalt) nach der DE-Regel gezeichnet.
  if R.yesNo then
    local okC, Chrome = pcall(require, "src.ui.gen2.Chrome")
    if okC and Chrome and not Chrome._deutschYesNo then
      Chrome._deutschYesNo = true
      local YN = R.yesNo
      local flagged = { [YN.from .. ":7"] = true }   -- Standardlage (14,7) aus YesNoBox
      local recent = {}
      local depth = 0
      -- "YES"/"NO" des Ports ueber ihre Pruefsumme im Katalog-Rezept
      local JA = R.strings and R.strings["~9355e4f00003"] and T(R.strings["~9355e4f00003"])
      local NEIN = R.strings and R.strings["~41e68bba0002"] and T(R.strings["~41e68bba0002"])
      local function yesText(t) return t == JA end
      local function noText(t) return t == NEIN end
      local function boxAt(tx, ty)
        local key = tx .. ":" .. ty
        return flagged[key] and key
      end
      local origBox = Chrome.paletteBox
      Chrome.paletteBox = function(tx, ty, tw, th, palette)
        if tw == 6 and th == 5 then
          recent[#recent + 1] = { tx, ty }
          if #recent > 8 then table.remove(recent, 1) end
          if boxAt(tx, ty) then
            return origBox(tx == YN.from and YN.to or tx, ty, YN.w, th, palette)
          end
        end
        return origBox(tx, ty, tw, th, palette)
      end
      -- Text/Cursor in einer markierten Box an Spalte 14 eine Kachel nach links -- NUR die Woerter
      -- JA/NEIN selbst und der Cursor, der unmittelbar danach in dieser Box gezeichnet wird (sonst
      -- traefe es jeden Text bei Spalte 16 in Zeile 8/10, z. B. den Doppelpunkt der Spielzeit)
      local cursorFolgt = 0
      local function shiftX(tx, ty, text)
        if cursorFolgt > 0 then cursorFolgt = cursorFolgt - 1 end
        if not (yesText(text) or noText(text)) then return tx end
        for _, dy in ipairs({ 1, 3 }) do
          if flagged[(tx - 2) .. ":" .. (ty - dy)] and tx - 2 == YN.from then
            cursorFolgt = 3
            return tx - 1
          end
        end
        return tx
      end
      local function learn(text, tx, ty)
        if yesText(text) or noText(text) then
          local dy = yesText(text) and 1 or 3
          for _, b in ipairs(recent) do
            if b[1] == tx - 2 and b[2] == ty - dy then flagged[b[1] .. ":" .. b[2]] = true end
          end
        end
      end
      local function wrapPrint(name)
        local orig = Chrome[name]
        Chrome[name] = function(text, tx, ty, ...)
          if depth > 0 then return orig(text, tx, ty, ...) end
          depth = depth + 1
          learn(text, tx, ty)
          local ok, r = pcall(orig, text, shiftX(tx, ty, text), ty, ...)
          depth = depth - 1
          if not ok then error(r, 0) end
          return r
        end
      end
      local function wrapCursor(name)
        local orig = Chrome[name]
        Chrome[name] = function(tx, ty, ...)
          if depth > 0 then return orig(tx, ty, ...) end
          depth = depth + 1
          local nx = tx
          if cursorFolgt > 0 then
            for _, dy in ipairs({ 1, 3 }) do
              if flagged[(tx - 1) .. ":" .. (ty - dy)] and tx - 1 == YN.from then nx = tx - 1 end
            end
          end
          local ok, r = pcall(orig, nx, ty, ...)
          depth = depth - 1
          if not ok then error(r, 0) end
          return r
        end
      end
      wrapPrint("print"); wrapPrint("printThrough")
      wrapCursor("cursor"); wrapCursor("cursorThrough")
    end
  end

  -- ------------------------------------------------------------ Pokedex: OPTION-/SUCHE-Bildschirm
  -- DE-ROM: "db $3b, " OPTIONEN ", $3c" -- die Endkappe steht hinter dem (laengeren) Titel;
  -- Beschreibung der Sortierart je Modus aus Pokedex_DisplayModeDescription.
  pcall(function()
    local PM = require("src.ui.gen2.PokedexMenu")
    if R.dexModes and PM.OPTION_MODES then
      for i, pair in ipairs(R.dexModes) do
        local m = PM.OPTION_MODES[i]
        if m then m.lines = { T(pair[1]), T(pair[2]) } end
      end
    end
    if not PM._deutschCap then
      PM._deutschCap = true
      local Font = require("src.render.Font")
      local origText, origTile = PM.text, PM.tile
      PM.text = function(self, str, tx, ty, ...)
        if tx == 1 and ty == 1 and type(str) == "string" then
          local ok, spans = pcall(Font.split, str)
          self._deutschTitleLen = ok and #spans or #str
        end
        return origText(self, str, tx, ty, ...)
      end
      PM.tile = function(self, id, tx, ty, ...)
        if id == 0x3c and tx == 9 and ty == 1 and self._deutschTitleLen then
          tx = 1 + self._deutschTitleLen
        end
        return origTile(self, id, tx, ty, ...)
      end
    end
  end)

  -- ------------------------------------------------------------ Optionsmenue (DE-Spalten)
  -- DE-ROM StringOptions: Wertzeile "     :" -> ":" an Spalte 7, Wert ab 8 (US: 10 / 11).
  -- Gruppe SPEED heisst hier TEMPO (das Wort SPEED ist sonst der Statuswert INIT).
  pcall(function()
    local OM = require("src.ui.gen2.OptionsMenu")
    local Chrome = require("src.ui.gen2.Chrome")
    local Marquee = require("src.ui.Marquee")
    local colon = R.optionsColon or 10
    local INIT = R.strings and R.strings["~5e35d5e00005"] and T(R.strings["~5e35d5e00005"])   -- "SPEED"
    local TEMPO = R.optionsSpeedGroup and T(R.optionsSpeedGroup) or "TEMPO"
    if OM._deutschCols or colon == 10 then return end
    OM._deutschCols = true
    local origDraw = OM.drawPanel
    OM.drawPanel = function(self, ...)
      local p, cs, cc = Chrome.print, Marquee.scroll, Marquee.clip
      local shift = 10 - colon
      Marquee.scroll = function(text, room, key) return cs(text, room == 8 and room + shift or room, key) end
      Marquee.clip = function(text, room) return cc(text, room == 8 and room + shift or room) end
      Chrome.print = function(text, tx, ty, ...)
        if tx == 2 and text == INIT then text = TEMPO end
        if tx == 10 or tx == 11 then tx = tx - shift
        elseif tx == 16 then tx = tx - shift end
        return p(text, tx, ty, ...)
      end
      local ok, err = pcall(origDraw, self, ...)
      Chrome.print, Marquee.scroll, Marquee.clip = p, cs, cc
      if not ok then error(err, 0) end
    end
  end)

  -- ------------------------------------------------------------ Anordnung wie in der DE-ROM
  -- Die Engine hat Boxlage und Spalten der EN-Menues fest im Code.  R.layout (aus der DE-ROM,
  -- nur Zahlen) sagt, wo die DE-Fassung sie hat.  umgelegt() setzt Chrome-Aufrufe NUR waehrend
  -- eines Zeichenaufrufs um und stellt danach alles wieder her; Aufrufe, die nicht genau die
  -- EN-Werte treffen, laufen unveraendert durch.

  -- Kampfmenue / Wettbewerbs-Kampfmenue: DE-Box weiter links, anderer Spaltenabstand
  -- (BattleMenuHeader, ContestBattleMenuHeader; 2x2-Raster, Text 2 Spalten hinter dem Rand)
  if L.BattleMenuHeader or L.ContestBattleMenuHeader then
    pcall(function()
      local BS = require("src.ui.gen2.BattleState")
      BS._deutschDrawBottom = BS._deutschDrawBottom or BS.drawBottom
      BS.drawBottom = function(self, ox, ...)
        local v = self.phase == "menu" and L[self.contest and "ContestBattleMenuHeader" or "BattleMenuHeader"]
        if not v then return BS._deutschDrawBottom(self, ox, ...) end
        local o = ox or 0
        local en, de = v.en, v.de
        return umgelegt({
          box = function(x, y, w, h)
            if x == en.x1 + o and y == en.y1 then return de.x1 + o, y, w + en.x1 - de.x1, h end
            return x, y, w, h
          end,
          spalte = function(x, y)
            if y >= en.y1 + 2 and y <= en.y2 - 1 then
              if x == en.x1 + 2 + o then return de.x1 + 2 + o end
              if x == en.x1 + 2 + en.abstand + o then return de.x1 + 2 + de.abstand + o end
            end
            return x
          end,
        }, BS._deutschDrawBottom, self, ox, ...)
      end
    end)
  end

  -- Tasche: Untermenue (BENUTZEN/GEBEN/...) -- Gold/Silber DE rechts (MenuHeader_*Item: x 13)
  if L.MenuHeader_UsableItem then
    pcall(function()
      local PM = require("src.ui.gen2.PackMenu")
      local en, de = L.MenuHeader_UsableItem.en, L.MenuHeader_UsableItem.de
      PM._deutschSubmenuColumn = PM._deutschSubmenuColumn or PM.submenuColumn
      PM.submenuColumn = function(self, ...)
        local x = PM._deutschSubmenuColumn(self, ...)
        if x == en.x1 then return de.x1 end
        return x
      end
    end)
  end

  -- Weiter-/Speicher-Infokasten: DE-Kasten ab Spalte 2 (statt 4), 2 breiter, Etiketten ab 3;
  -- Zahlenspalten bleiben (DisplaySaveInfoOnContinue/-OnSave, Continue_DisplayBadgesDex)
  local SI = R.saveInfo
  if SI and SI.en.x ~= SI.de.x then
    pcall(function()
      local SM = require("src.ui.gen2.SaveMenu")
      local P = SM.PANEL
      local dx = SI.en.x - SI.de.x
      if P and P.x == SI.en.x then
        P.x, P.w, P.labelX = SI.de.x, P.w + dx, P.labelX - dx
      end
      SM._deutschDrawPanel = SM._deutschDrawPanel or SM.drawPanel
      SM.drawPanel = function(self, ...)
        local ex = SI.en.xSpeichern
        return umgelegt({
          box = function(x, y, w, h)
            if x == ex and y == 0 then return SI.de.xSpeichern, y, w + ex - SI.de.xSpeichern, h end
            return x, y, w, h
          end,
          druck = function(x, y)
            if x == ex + 1 and y >= 2 and y <= 8 then return SI.de.xSpeichern + 1 end
            return x
          end,
        }, SM._deutschDrawPanel, self, ...)
      end
    end)
  end

  -- Bills PC: Untermenue ABLEGEN/MITNEHMEN/VERSCHIEBEN -- DE-Kasten weiter links
  -- (BillsPCDepositMenuHeader, BillsPC_Withdraw, _MovePKMNWithoutMail: x 9 -> 6 bzw. 7).
  -- Umgelegt wird erst ab dem Untermenue-Kasten; die Namensliste darunter bleibt.
  local bpc = L.BillsPCDepositMenuHeader
  if bpc then
    pcall(function()
      local BM = require("src.ui.gen2.BoxMenu")
      local en, de = bpc.en, bpc.de
      BM._deutschDrawPanel = BM._deutschDrawPanel or BM.drawPanel
      BM.drawPanel = function(self, ...)
        if self.phase ~= "submenu" then return BM._deutschDrawPanel(self, ...) end
        local aktiv = false
        local function im(y) return aktiv and y > en.y1 and y < en.y2 end
        return umgelegt({
          box = function(x, y, w, h)
            if x == en.x1 and y == en.y1 and w == en.x2 - en.x1 + 1 then
              aktiv = true
              return de.x1, y, de.x2 - de.x1 + 1, h
            end
            return x, y, w, h
          end,
          zeiger = function(x, y) if im(y) and x == en.x1 + 1 then return de.x1 + 1 end return x end,
          druck = function(x, y) if im(y) and x == en.x1 + 2 then return de.x1 + 2 end return x end,
        }, BM._deutschDrawPanel, self, ...)
      end
    end)
  end

  -- Trainerpass: DE ohne "NAME/" -- Name bei Spalte 2 (statt 7); "ORDEN" bei 13 (statt 12)
  -- (TrainerCard_PrintTopHalfOfCard, TrainerCard_Page1_PrintDexCaught_GameTime.Badges)
  local TCW = R.trainerCard
  if TCW and (TCW.en.nameX ~= TCW.de.nameX or TCW.en.ordenX ~= TCW.de.ordenX) then
    pcall(function()
      local TC = require("src.ui.gen2.TrainerCard")
      local Strings = require("src.core.Strings")
      local en, de = TCW.en, TCW.de
      local function neu(text, tx, ty)
        if ty == 2 and tx == 2 and en.etikett and not de.etikett and text == Strings("NAME/") then
          return nil                                   -- DE hat keine Beschriftung
        end
        if ty == 2 and tx == en.nameX then return de.nameX end
        if ty == 15 and tx == en.ordenX and text == Strings("BADGES") then return de.ordenX end
        return tx
      end
      TC._deutschPrint = TC._deutschPrint or TC.print
      TC.print = function(self, text, tx, ty, ...)
        local nx = neu(text, tx, ty)
        if nx == nil then return end
        return TC._deutschPrint(self, text, nx, ty, ...)
      end
      if TC.drawPlain then
        local Chrome = require("src.ui.gen2.Chrome")
        TC._deutschDrawPlain = TC._deutschDrawPlain or TC.drawPlain
        TC.drawPlain = function(self, ...)
          local p = Chrome.printThrough
          Chrome.printThrough = function(text, tx, ty, ...)
            local nx = neu(text, tx, ty)
            if nx == nil then return end
            return p(text, nx, ty, ...)
          end
          local ok, e = pcall(TC._deutschDrawPlain, self, ...)
          Chrome.printThrough = p
          if not ok then error(e, 0) end
          return e
        end
      end
    end)
  end

  -- Team: Pokemon-Untermenue (MonSubmenu x 6 -> 5) und Kampf-Untermenue (BattleMonMenu x 11 -> 9)
  local ms, bms = L["MonSubmenu.MenuHeader"], L["BattleMonMenu.MenuHeader"]
  if ms or bms then
    pcall(function()
      local PM = require("src.ui.gen2.PartyMenu")
      if ms then
        local dx = ms.de.x1 - ms.en.x1
        PM._deutschLabelCoord = PM._deutschLabelCoord or PM.submenuLabelCoord
        PM.submenuLabelCoord = function(...)
          local x, y = PM._deutschLabelCoord(...)
          if x == ms.en.x1 + 2 then x = x + dx end
          return x, y
        end
      end
      PM._deutschDrawSubmenu = PM._deutschDrawSubmenu or PM.drawSubmenu
      PM.drawSubmenu = function(self, ...)
        local menu = self.submenu
        local v = menu and (menu.battle and bms or (not menu.battle and ms))
        if not v then return PM._deutschDrawSubmenu(self, ...) end
        local en, de = v.en, v.de
        local regeln = {
          box = function(x, y, w, h)
            if x == en.x1 and x + w - 1 == en.x2 then return de.x1, y, de.x2 - de.x1 + 1, h end
            return x, y, w, h
          end,
        }
        if menu.battle then                         -- Etiketten fest im Code: mitverschieben
          regeln.zeiger = function(x) if x == en.x1 + 1 then return de.x1 + 1 end return x end
          regeln.druck = function(x) if x == en.x1 + 2 then return de.x1 + 2 end return x end
        end
        return umgelegt(regeln, PM._deutschDrawSubmenu, self, ...)
      end
    end)
  end

  -- Briefkasten-PC: Untermenue-Kasten breiter (MailboxPC.SubMenuHeader 0..13 -> 0..16)
  local mb = L["MailboxPC.SubMenuHeader"]
  if mb then
    pcall(function()
      local MM = require("src.ui.gen2.MailboxMenu")
      MM._deutschDrawSubmenu = MM._deutschDrawSubmenu or MM.drawSubmenu
      MM.drawSubmenu = function(self, ...)
        return umgelegt({
          box = function(x, y, w, h)
            if x == mb.en.x1 and y == mb.en.y1 and x + w - 1 == mb.en.x2 then
              return mb.de.x1, y, mb.de.x2 - mb.de.x1 + 1, h
            end
            return x, y, w, h
          end,
        }, MM._deutschDrawSubmenu, self, ...)
      end
    end)
  end

  -- Dekoration: Kategorienliste (x 5 -> 6) und Seitenwahl LINKS/RECHTS (schmaler)
  local dk, ds = L["_PlayerDecorationMenu.MenuHeader"], L.DecoSideMenuHeader
  if dk or ds then
    pcall(function()
      local DM = require("src.ui.gen2.DecorationMenu")
      DM._deutschDrawList = DM._deutschDrawList or DM.drawList
      DM.drawList = function(self, x, y, w, h, ...)
        if dk and x == dk.en.x1 and y == dk.en.y1 and x + w - 1 == dk.en.x2 then
          x, w = dk.de.x1, dk.de.x2 - dk.de.x1 + 1
        elseif ds and self.mode == "side" and x == ds.en.x1 and y == ds.en.y1 then
          w = ds.de.x2 - ds.de.x1 + 1
        end
        return DM._deutschDrawList(self, x, y, w, h, ...)
      end
    end)
  end

  -- Brief am Pokemon: LESEN/NEHMEN/ZURUECK (MonMailAction.MenuHeader x 9 -> 10)
  local mma = L["MonMailAction.MenuHeader"]
  if mma then
    pcall(function()
      local ML = require("src.ui.gen2.MailMenu")
      ML._deutschDrawPanel = ML._deutschDrawPanel or ML.drawPanel
      ML.drawPanel = function(self, ...)
        local aktiv = false
        local ex = 9                                       -- Engine-Spalte (Gold-EN-Wert)
        local function im(y) return aktiv and y > mma.de.y1 and y < mma.de.y2 end
        return umgelegt({
          box = function(x, y, w, h)
            if x == ex and y == mma.de.y1 and x + w - 1 == mma.de.x2 then
              aktiv = true
              return mma.de.x1, y, mma.de.x2 - mma.de.x1 + 1, h
            end
            return x, y, w, h
          end,
          zeiger = function(x, y) if im(y) and x == ex + 1 then return mma.de.x1 + 1 end return x end,
          druck = function(x, y) if im(y) and x == ex + 2 then return mma.de.x1 + 2 end return x end,
        }, ML._deutschDrawPanel, self, ...)
      end
    end)
  end

  -- Spielautomat: Einsatz-Menue (nur Kristall DE: Slots_AskBet (15,6)-(19,13) statt (14,10)-(19,17))
  local sab = L["Slots_AskBet.MenuHeader"]
  if sab then
    pcall(function()
      local SL = require("src.ui.gen2.SlotMachine")
      local en, de = sab.en, sab.de
      local dy = de.y1 - en.y1
      SL._deutschDrawPanel = SL._deutschDrawPanel or SL.drawPanel
      SL.drawPanel = function(self, ...)
        local aktiv = false
        local function im(y) return aktiv and y > en.y1 and y < en.y2 end
        return umgelegt({
          textbox = function(x, y, w, h)
            if x == en.x1 and y == en.y1 and x + w + 1 == en.x2 then
              aktiv = true
              return de.x1, de.y1, de.x2 - de.x1 - 1, h
            end
            return x, y, w, h
          end,
          zeiger = function(x, y) if im(y) and x == en.x1 + 1 then return de.x1 + 1, y + dy end return x end,
          -- EN-Eintraege " 3" ab x1+2, DE "3" ab x1+2 (Slots_AskBet.MenuData ohne Leerzeichen)
          text = function(t, x, y) if im(y) and x == en.x1 + 2 then return (tostring(t):gsub("^ ", "")) end return t end,
          druck = function(x, y) if im(y) and x == en.x1 + 2 then return de.x1 + 2, y + dy end return x end,
        }, SL._deutschDrawPanel, self, ...)
      end
    end)
  end

  -- Junge oder Maedchen? (nur Kristall DE: InitGender (5,4)-(14,9) statt (6,4)-(12,9))
  local ig = L["InitGender.MenuHeader"]
  if ig then
    pcall(function()
      local GS = require("src.ui.gen2.GenderSelect")
      local en, de = ig.en, ig.de
      GS._deutschDrawPanel = GS._deutschDrawPanel or GS.drawPanel
      GS.drawPanel = function(self, ...)
        return umgelegt({
          palbox = function(x, y, w, h)
            if x == en.x1 and y == en.y1 and x + w - 1 == en.x2 then return de.x1, y, de.x2 - de.x1 + 1, h end
            return x, y, w, h
          end,
          spalte = function(x, y)
            if y > en.y1 and y < en.y2 and x == en.x1 + 2 then return de.x1 + 2 end
            return x
          end,
        }, GS._deutschDrawPanel, self, ...)
      end
    end)
  end

  -- Wochentag einstellen (SetDayOfWeek): DE-Kasten (8,3) innen 10, Pfeile Spalte 13, Tag bei (9,5)
  local dp = R.dayPicker
  if dp and dp.en and dp.de then
    pcall(function()
      local IC = require("src.ui.gen2.InitClock")
      IC._deutschPickerBox = IC._deutschPickerBox or IC.pickerBox
      IC.pickerBox = function(self, ...)
        local r = { IC._deutschPickerBox(self, ...) }
        if self.phase == "day" and #r == 7 then
          local gleich = true
          for i = 1, 7 do if r[i] ~= dp.en[i] then gleich = false end end
          if gleich then return (table.unpack or unpack)(dp.de) end
        end
        return (table.unpack or unpack)(r)
      end
    end)
  end

  -- Bills PC: Boxname (BillsPC_BoxName.print) -- in allen Phasen
  if K("BillsPC_BoxName.print", 10, 1) then
    pcall(function()
      local BM = require("src.ui.gen2.BoxMenu")
      local nx, ny = K("BillsPC_BoxName.print", 10, 1)
      BM._deutschTitelPanel = BM._deutschTitelPanel or BM.drawPanel
      BM.drawPanel = function(self, ...)
        return umgelegt({
          druck = function(x, y) if x == 10 and y == 1 then return nx, ny end return x end,
        }, BM._deutschTitelPanel, self, ...)
      end
    end)
  end

  -- Pokedex-Gebiet: "…S NEST"-Ueberschrift (Pokedex_GetArea.PlaceString_MonsNest)
  if K("Pokedex_GetArea.PlaceString_MonsNest", 2, 0) then
    pcall(function()
      local PD = require("src.ui.gen2.PokedexMenu")
      local nx, ny = K("Pokedex_GetArea.PlaceString_MonsNest", 2, 0)
      PD._deutschAreaHeader = PD._deutschAreaHeader or PD.drawAreaHeader
      PD.drawAreaHeader = function(self, ...)
        return umgelegt({
          spalte = function(x, y) if x == 2 and y == 0 then return nx, ny end return x end,
        }, PD._deutschAreaHeader, self, ...)
      end
    end)
  end

  -- PokeCom-Uhr (InitPokegearTilemap.Clock): DE-Wechseltext (" WEITER") an der DE-Stelle und die
  -- Rahmenkacheln, die die DE-ROM nach der Kachelkarte setzt (Kasten eine Spalte breiter).
  local cs = R.clockSwitch
  if cs then
    pcall(function()
      local PG = require("src.ui.gen2.Pokegear")
      local Strings = require("src.core.Strings")
      local label = T(cs.text)
      PG._deutschDrawClock = PG._deutschDrawClock or PG.drawClock
      PG.drawClock = function(self, ...)
        local altT, altK = PG.text, PG.drawTilemap
        local en = " " .. Strings("SWITCH")
        PG.text = function(s, str, x, y, ...)
          if str == en and x == 12 and y == 1 then return altT(s, label, cs.x, cs.y, ...) end
          return altT(s, str, x, y, ...)
        end
        PG.drawTilemap = function(s, cells, ...)
          if cells then
            local neu = setmetatable({}, { __index = cells })
            for _, k in ipairs(cs.tiles) do neu[k[2] * 20 + k[1] + 1] = k[3] end
            cells = neu
          end
          return altK(s, cells, ...)
        end
        local ok, e = pcall(PG._deutschDrawClock, self, ...)
        PG.text, PG.drawTilemap = altT, altK
        if not ok then error(e, 0) end
        return e
      end
    end)
  end


  -- Spielautomat, Einsatz-Frage: Slots_AskBet gibt den Text mit PrintText aus -> normaler
  -- Textkasten (0,12) innen 18x4 (EN wie DE); der Port zeichnet ihn innen 12 breit, der DE-Text
  -- ("Wie viel setzen?") laeuft dann ueber den Rahmen.  Der Einsatzkasten liegt danach darueber.
  pcall(function()
    local SL = require("src.ui.gen2.SlotMachine")
    SL._deutschBetText = SL._deutschBetText or SL.drawPanel
    SL.drawPanel = function(self, ...)
      if self.phase ~= "bet" then return SL._deutschBetText(self, ...) end
      return umgelegt({
        textbox = function(x, y, w, h)
          if x == 0 and y == 12 and w == 12 and h == 4 then return x, y, 18, h end
          return x, y, w, h
        end,
      }, SL._deutschBetText, self, ...)
    end
  end)

  -- Spieler-PC (PlayersPCMenuData): DE-Kasten breiter (x2 aus der DE-ROM); der Port hat
  -- Chrome.box(0, 0, 16, h) fest im Code (EN menu_coords 0,0,15,12)
  local ppc = R.playersPc
  if ppc and ppc.de ~= ppc.en then
    pcall(function()
      local IP = require("src.ui.gen2.ItemPcMenu")
      local w = ppc.en + 1
      IP._deutschDrawPanel = IP._deutschDrawPanel or IP.drawPanel
      IP.drawPanel = function(self, ...)
        return umgelegt({
          box = function(x, y, bw, h)
            if x == 0 and y == 0 and bw == w then return x, y, ppc.de + 1, h end
            return x, y, bw, h
          end,
        }, IP._deutschDrawPanel, self, ...)
      end
    end)
  end

  -- Fotostudio-Karte (PrintPartyMonPage1): DE "ATTACKE/" eine Zeile hoeher als EN "MOVE"
  local pmv = R.photoMove
  if pmv then
    pcall(function()
      local PS = require("src.ui.gen2.PhotoStudio")
      local Strings = require("src.core.Strings")
      local label = T(pmv.text)
      PS._deutschDrawPanel = PS._deutschDrawPanel or PS.drawPanel
      PS.drawPanel = function(self, ...)
        local Chrome = require("src.ui.gen2.Chrome")
        local p, ziel = Chrome.print, Strings("MOVE")
        Chrome.print = function(text, x, y, ...)
          if text == ziel and x == pmv.en[1] and y == pmv.en[2] then return p(label, pmv.de[1], pmv.de[2], ...) end
          return p(text, x, y, ...)
        end
        local ok, e = pcall(PS._deutschDrawPanel, self, ...)
        Chrome.print = p
        if not ok then error(e, 0) end
        return e
      end
    end)
  end


  -- Statusseite gruen: Itemname (LoadGreenPage.got_item_name; Gold/Silber DE Spalte 8 statt 6)
  if K("LoadGreenPage.got_item_name", 6, 8) then
    pcall(function()
      local SU = require("src.ui.gen2.SummaryMenu")
      local nx, ny = K("LoadGreenPage.got_item_name", 6, 8)
      SU._deutschGreen = SU._deutschGreen or SU.greenPlacements
      SU.greenPlacements = function(self, ...)
        local out = SU._deutschGreen(self, ...)
        for _, e in ipairs(out or {}) do
          if e.x == 6 and e.y == 8 then e.x, e.y = nx, ny end
        end
        return out
      end
    end)
  end

  -- Kaeferwettbewerb: Vergleich gefangen/bisher (DisplayCaughtContestMonStats; DE eine Spalte links)
  if (R.coords or {}).DisplayCaughtContestMonStats then
    pcall(function()
      local CM = require("src.ui.gen2.ContestMenu")
      CM._deutschMonBox = CM._deutschMonBox or CM.drawMonBox
      -- DE .Health ist "  GESU" (mit Leerzeichen, ab (4,4)); der gemeinsame Schluessel "HEALTH"
      -- (auch Vitamin-Texte, dort "GESU") bleibt, hier wird der DE-Wortlaut eingesetzt
      local gesu = R.contestHealth and T(R.contestHealth)
      CM.drawMonBox = function(self, ...)
        return umgelegt({
          text = function(t, x, y)
            if gesu and x == 5 and (y == 4 or y == 10) then return gesu end
            return t
          end,
          druck = function(x, y)
            local nx, ny = K("DisplayCaughtContestMonStats", x, y)
            if nx then return nx, ny end
            return x
          end,
        }, CM._deutschMonBox, self, ...)
      end
    end)
  end

  -- Karten-Flip: Muenzkasten (CardFlip_PrintCoinBalance) -- DE "MUENZEN": Kasten und Etikett
  -- um dieselbe Spaltenzahl nach links, Kasten entsprechend breiter; der Wert bleibt bei 15
  -- Textkasten: Karte und Port zeichnen ihn verschieden -- der Port 8 innen breit, die DE-ROM (und
  -- EN-ROM) CardFlip_UpdateCoinBalanceDisplay innen 18 (R.cardFlipText); der DE-Text braucht die Breite.
  local cft = R.cardFlipText
  if K("CardFlip_PrintCoinBalance", 10, 16) or cft then
    pcall(function()
      local CF = require("src.ui.gen2.CardFlip")
      local lx = K("CardFlip_PrintCoinBalance", 10, 16) or 10
      local dx = 10 - lx
      CF._deutschDrawPanel = CF._deutschDrawPanel or CF.drawPanel
      CF.drawPanel = function(self, ...)
        return umgelegt({
          textbox = function(x, y, w, h)
            if x == 9 and y == 15 and w == 9 and h == 1 then return x - dx, y, w + dx, h end
            if cft and x == cft.x and y == cft.y and h == cft.h and w == 8 then return x, y, cft.w, h end
            return x, y, w, h
          end,
          druck = function(x, y) if x == 10 and y == 16 then return lx end return x end,
        }, CF._deutschDrawPanel, self, ...)
      end
    end)
  end

  -- Startmenue im Kaeferwettbewerb: Statuskasten (StartMenu_DrawBugContestStatusBox; Kristall DE
  -- innen 18 statt 17 breit).  Die Wertspalte rueckt der Port selbst hinter das (DE-)Etikett.
  local bcs = ((R.coords or {}).StartMenu_DrawBugContestStatusBox or {})[1]
  if bcs and bcs.eg and bcs.dg and bcs.eg.c and bcs.dg.c and bcs.eg.c ~= bcs.dg.c then
    pcall(function()
      local ST = require("src.ui.gen2.StartMenu")
      ST._deutschContest = ST._deutschContest or ST.drawContestStatus
      ST.drawContestStatus = function(self, ...)
        return umgelegt({
          textbox = function(x, y, w, h)
            if x == 0 and y == 0 and w == bcs.eg.c then return x, y, bcs.dg.c, h end
            return x, y, w, h
          end,
        }, ST._deutschContest, self, ...)
      end
    end)
  end

  -- Diplom: DE-Beschriftung "TRAINER" (statt der allgemeinen PLAYER-Uebersetzung), Name direkt
  -- dahinter (PlaceDiplomaOnScreen: Name an PlaceStrings Endposition + 1)
  local dpl = R.diplomaPlayer
  if dpl then
    pcall(function()
      local DP = require("src.ui.gen2.Diploma")
      local Strings = require("src.core.Strings")
      local label = T(dpl.label)
      DP._deutschDrawPanel = DP._deutschDrawPanel or DP.drawPanel
      DP.drawPanel = function(self, ...)
        local Chrome = require("src.ui.gen2.Chrome")
        local p = Chrome.printThrough
        Chrome.printThrough = function(text, x, y, ...)
          if y == 5 and x == 2 and text == Strings("PLAYER") then return p(label, x, y, ...) end
          if y == 5 and x == 9 and dpl.nameAfter and text == self.playerName then
            return p(text, 2 + #label + 1, y, ...)
          end
          return p(text, x, y, ...)
        end
        local ok, e = pcall(DP._deutschDrawPanel, self, ...)
        Chrome.printThrough = p
        if not ok then error(e, 0) end
        return e
      end
    end)
  end


  -- Kontrolle: welche Anordnungs-Anpassungen sind eingehaengt (pcall verschluckt sonst Fehler)
  pcall(function()
    local liste, an = {
      { "src.ui.gen2.BattleState", "_deutschDrawBottom", "Kampfmenue" },
      { "src.ui.gen2.PackMenu", "_deutschSubmenuColumn", "Tasche" },
      { "src.ui.gen2.SaveMenu", "_deutschDrawPanel", "Infokasten" },
      { "src.ui.gen2.BoxMenu", "_deutschDrawPanel", "BillsPC" },
      { "src.ui.gen2.TrainerCard", "_deutschPrint", "Trainerpass" },
      { "src.ui.gen2.PartyMenu", "_deutschDrawSubmenu", "Team" },
      { "src.ui.gen2.MailboxMenu", "_deutschDrawSubmenu", "Briefkasten" },
      { "src.ui.gen2.DecorationMenu", "_deutschDrawList", "Dekoration" },
      { "src.ui.gen2.MailMenu", "_deutschDrawPanel", "Briefansicht" },
      { "src.ui.gen2.SlotMachine", "_deutschDrawPanel", "Automat" },
      { "src.ui.gen2.GenderSelect", "_deutschDrawPanel", "Geschlecht" },
      { "src.ui.gen2.InitClock", "_deutschPickerBox", "Wochentag" },
      { "src.ui.gen2.BoxMenu", "_deutschTitelPanel", "Boxname" },
      { "src.ui.gen2.PokedexMenu", "_deutschAreaHeader", "Nest" },
      { "src.ui.gen2.PokedexMenu", "_deutschEntryBody", "DexDezimalpunkt" },
      { "src.ui.gen2.Pokegear", "_deutschDrawClock", "PokeComUhr" },
      { "src.ui.gen2.PhotoStudio", "_deutschDrawPanel", "Fotostudio" },
      { "src.ui.gen2.ItemPcMenu", "_deutschDrawPanel", "SpielerPC" },
      { "src.ui.gen2.SlotMachine", "_deutschBetText", "AutomatText" },
      { "src.core.gen2.Decorations", "_deutschName", "DekoNamen" },
      { "src.ui.gen2.DecorationMenu", "_deutschKategorien", "DekoKategorien" },
      { "src.ui.gen2.UnownPrinter", "_deutschMenue", "IcognitoDrucker" },
      { "src.ui.gen2.ElevatorMenu", "_deutschDrawPanel", "Fahrstuhl" },
      { "src.ui.gen2.NamePick", "_deutschTitel", "NamensTitel" },
      { "src.ui.gen2.HallOfFame", "_deutschPlayer", "Ruhmeshalle" },
      { "src.ui.gen2.SummaryMenu", "_deutschGreen", "Statusseite" },
      { "src.ui.gen2.ContestMenu", "_deutschMonBox", "Wettbewerb" },
      { "src.ui.gen2.CardFlip", "_deutschDrawPanel", "KartenFlip" },
      { "src.ui.gen2.StartMenu", "_deutschContest", "Wettbewerbsstatus" },
      { "src.ui.gen2.Diploma", "_deutschDrawPanel", "Diplom" },
    }, {}
    for _, e in ipairs(liste) do
      local okM, M = pcall(require, e[1])
      if okM and type(M) == "table" and M[e[2]] then an[#an + 1] = e[3] end
    end
    log:info("Deutsch Gen 2: Anordnung aktiv: %s", concat(an, ", "))
  end)

end
