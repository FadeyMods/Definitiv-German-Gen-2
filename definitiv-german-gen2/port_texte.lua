-- Feste Texte des Ports, mit der deutschen Fassung aus der DE-ROM:
--   * Uebersetzungs-Katalog des Ports (mod.content.strings: Schluessel = englischer Text im Port-Code)
--   * Menues, die der Port ohne Katalog beschriftet (Haupt-/Startmenue, Mamas Bank, Fahrstuhl,
--     Namenswahl, Icognito-Drucker, Bills PC "Verschieben", Ruhmeshalle), Pokedex-Dezimalpunkt
return function(W)
  local mod, R, T, umgelegt, K = W.mod, W.R, W.T, W.umgelegt, W.K

  W.apply("strings", R.strings, function(k, parts) mod.content.strings:override(k, T(parts)) end)

  -- Menues (Eintrag nach value).  Hauptmenue: DE-ROM "OPTIONEN"; Startmenue: Port-QUIT -> "BEENDEN"
  for hook, map in pairs(R.menus or {}) do
    local m = {}
    for k, v in pairs(map) do m[k] = T(v) end
    pcall(function()
      mod.hooks:wrap(hook, function(nxt, game, items)
        local out = nxt(game, items)
        for _, it in ipairs(out or {}) do
          if it.value ~= nil and m[it.value] then it.label = m[it.value] end
        end
        return out
      end)
    end)
  end

  -- Skript-Menues, die der Port selbst fest englisch anlegt (Mamas Bank: GET/SAVE/CHANGE/CANCEL ->
  -- DE-ROM BankOfMom_MenuHeader ABHEBEN/SPAREN/AENDERN/ZURUECK): nur beim Zeichnen ersetzt -- die
  -- Antwort des Menues ist die Nummer des Eintrags, nicht sein Text
  if R.skriptLabels then
    local m = {}
    for en, parts in pairs(R.skriptLabels) do m[en] = T(parts) end
    pcall(function()
      local SM = require("src.ui.gen2.ScriptMenu")
      SM._deutschLabels = SM._deutschLabels or SM.drawPanel
      SM.drawPanel = function(self, ...)
        local Chrome = require("src.ui.gen2.Chrome")
        local p = Chrome.print
        Chrome.print = function(text, ...)
          if type(text) == "string" and m[text] then text = m[text] end
          return p(text, ...)
        end
        local ok, e = pcall(SM._deutschLabels, self, ...)
        Chrome.print = p
        if not ok then error(e, 0) end
        return e
      end
    end)
  end

  -- Fahrstuhl: der Port druckt "Now on:" (Elevator_CurrentFloorText) ohne Strings(); die DE-ROM hat dort
  -- "Im" (Kristall) / "im" (Gold/Silber) an derselben Stelle (1,2) -- Text aus R.strings
  pcall(function()
    local EM = require("src.ui.gen2.ElevatorMenu")
    local Strings = require("src.core.Strings")
    EM._deutschDrawPanel = EM._deutschDrawPanel or EM.drawPanel
    EM.drawPanel = function(self, ...)
      local Chrome = require("src.ui.gen2.Chrome")
      local p = Chrome.print
      Chrome.print = function(text, x, y, ...)
        if text == "Now on:" then text = Strings(text) end
        return p(text, x, y, ...)
      end
      local ok, e = pcall(EM._deutschDrawPanel, self, ...)
      Chrome.print = p
      if not ok then error(e, 0) end
      return e
    end
  end)

  -- Namenswahl: Vorschlaege der DE-ROM (Gold "Gold/DANIEL/FRITZ/KARL", Kristall "CHRIS/ARNOLD/GERT/JON"
  -- bzw. "KRISTA/SINA/MANDY/TABITHA") in die Vorschlagslisten des Moduls; Titel nur dort, wo die DE-ROM
  -- ihn anders setzt als die EN-ROM (Gold/Silber: Einzug 1, " NAME ")
  if R.namePick then
    pcall(function()
      local NP = require("src.ui.gen2.NamePick")
      local ver2 = require("src.core.GameVersion").get()
      for key, tab in pairs({ male = NP.PRESETS and NP.PRESETS[ver2],
                              female = NP.PRESETS_FEMALE and NP.PRESETS_FEMALE[ver2] }) do
        local de = R.namePick[key]
        if de and type(tab) == "table" then
          for i, p in ipairs(de) do tab[i] = T(p) end
        end
      end
      local ti = R.namePick.title
      if ti then
        local Strings = require("src.core.Strings")
        local titel = T(ti.text)
        NP._deutschTitel = NP._deutschTitel or NP.drawPanel
        NP.drawPanel = function(self, ...)
          return umgelegt({
            text = function(t, x, y)
              if x == 2 and y == 0 and t == Strings("NAME") then return titel end
              return t
            end,
            druck = function(x, y) if x == 2 and y == 0 then return ti.indent, y end return x end,
          }, NP._deutschTitel, self, ...)
        end
      end
    end)
  end

  -- Icognito-Drucker: Menuezeilen wie UnownDexMenuString der DE-ROM (der Port setzt "A▶PRINT" usw. aus
  -- allgemeinen Woertern zusammen -> "L▶ZURUECK"; DE: "L▶VORHER", "R▶NAECHST").  ♂/♀ sind im Original
  -- fette A/B-Kacheln; der Port schreibt dafuer A/B, das bleibt so.
  if R.unownMenu then
    pcall(function()
      local UP = require("src.ui.gen2.UnownPrinter")
      local zeilen = {}
      for i, parts in ipairs(R.unownMenu) do
        zeilen[i] = (T(parts):gsub("^♂", "A"):gsub("^♀", "B"))
      end
      UP._deutschMenue = UP._deutschMenue or UP.drawPanel
      UP.drawPanel = function(self, ...)
        local Chrome = require("src.ui.gen2.Chrome")
        local p = Chrome.print
        Chrome.print = function(text, x, y, ...)
          if x == 10 and y >= 6 and y <= 9 and zeilen[y - 5] then text = zeilen[y - 5] end
          return p(text, x, y, ...)
        end
        local ok, e = pcall(UP._deutschMenue, self, ...)
        Chrome.print = p
        if not ok then error(e, 0) end
        return e
      end
    end)
  end

  -- Pokedex-Eintrag: Groesse/Gewicht (DisplayDexEntry, DE: PrintNum lb bc 1,$23 bei (13,7) und lb bc 2,$34
  -- bei (12,9)) -- PrintNum setzt seinen Dezimalpunkt '.', der Port schreibt "0,7".  Nur das Zeichen.
  pcall(function()
    local PD = require("src.ui.gen2.PokedexMenu")
    local function punkt(t)
      if type(t) == "string" then
        local a, b = t:match("^(%s*%d+),(%d)$")
        if a then return a .. "." .. b end
      end
      return t
    end
    PD._deutschEntryBody = PD._deutschEntryBody or PD.drawEntryBody
    PD.drawEntryBody = function(self, ...)
      local alt = PD.text
      PD.text = function(s, t, ...) return alt(s, punkt(t), ...) end
      local ok, e = pcall(PD._deutschEntryBody, self, ...)
      PD.text = alt
      if not ok then error(e, 0) end
      return e
    end
  end)

  -- Ruhmeshalle-PC: Nummer (_HallOfFamePC.print_num_hof) und "PLAY TIME" (fest im Code, ohne Strings() --
  -- DE-ROM HOF_AnimatePlayerPic.PlayTime: "SPIELZEIT")
  pcall(function()
    local HF = require("src.ui.gen2.HallOfFame")
    local Strings = require("src.core.Strings")
    local nx, ny = K("_HallOfFamePC.print_num_hof", 2, 2)
    if nx and HF.headerPlacements then
      HF._deutschHeader = HF._deutschHeader or HF.headerPlacements
      HF.headerPlacements = function(...)
        local out = HF._deutschHeader(...)
        for _, e in ipairs(out or {}) do
          if e.x == 2 and e.y == 2 and tostring(e.text):match("^%s*%d+$") then e.x, e.y = nx, ny end
        end
        return out
      end
    end
    if HF.playerPlacements then
      HF._deutschPlayer = HF._deutschPlayer or HF.playerPlacements
      HF.playerPlacements = function(...)
        local out = HF._deutschPlayer(...)
        for _, e in ipairs(out or {}) do
          if e.text == "PLAY TIME" then e.text = Strings("PLAY TIME") end
        end
        return out
      end
    end
  end)

  -- Bills PC, Verschieben-Untermenue: erster Eintrag heisst in der DE-ROM anders als MOVE sonst (DE
  -- "Wechseln"; Team-Untermenue/Statusseite: "ATTACKE").  Nur beim Zeichnen ersetzt -- der Port waehlt
  -- die Aktion ueber den Eintrag selbst (chooseSubmenu: row == "MOVE").
  if R.boxMoveLabel then
    pcall(function()
      local BM = require("src.ui.gen2.BoxMenu")
      local Strings = require("src.core.Strings")
      local label = T(R.boxMoveLabel)
      BM._deutschMoveLabel = BM._deutschMoveLabel or BM.drawPanel
      BM.drawPanel = function(self, ...)
        if self.mode ~= "move" or self.phase ~= "submenu" then return BM._deutschMoveLabel(self, ...) end
        local Chrome = require("src.ui.gen2.Chrome")
        local p, ziel = Chrome.print, Strings("MOVE")
        Chrome.print = function(text, x, y, ...)
          if text == ziel then text = label end
          return p(text, x, y, ...)
        end
        local ok, e = pcall(BM._deutschMoveLabel, self, ...)
        Chrome.print = p
        if not ok then error(e, 0) end
        return e
      end
    end)
  end
end
