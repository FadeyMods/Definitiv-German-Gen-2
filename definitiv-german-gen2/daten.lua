-- Namen und Daten aus der DE-ROM:
--   * Importdaten des Ports (R.paths): Pokemon-, Attacken-, Item-, Trainer-, Orts-, Typnamen, Prof.-Eich-Rede ...
--   * Pokedex (Kategorie, Beschreibung, Groesse/Gewicht metrisch)
--   * Ereignistabellen (Stockwerke, Tausch-Spitznamen/OT, Buena-Passwort), Radiosender, Telefon
--   * Skript-Menues (Automaten, Preis-Theken ...), Dekorationen, Diplom-Kachelkarte
--   * Felder in Port-Modulen, die der Port englisch fest hat (Fang-Tutorial KUMPEL, Geschenk-Pottrott)
return function(W)
  local mod, R, T, rom, log, ver, apply = W.mod, W.R, W.T, W.rom, W.log, W.ver, W.apply
  local byte, concat = string.byte, table.concat

  -- Radiosender und Telefon-Nicht-Trainer (Registries radio_channels / phone_contacts): nur der Name
  local ER = R.ereignis or {}
  apply("radio", ER.radio, function(st, parts) mod.content.radio_channels:patch(st, { name = T(parts) }) end)
  apply("telefon", ER.phone, function(id, parts) mod.content.phone_contacts:patch(id, { name = T(parts) }) end)

  -- Felder in Port-Modulen (Modul, Feld, Rezept)
  apply("modulfelder", R.modulFelder, function(_, f)
    local M = require(f[1])
    assert(type(M) == "table" and type(M[f[2]]) == "string", "Feld fehlt: " .. f[1] .. "." .. f[2])
    M[f[2]] = T(f[3])
  end)

  -- Dekorationen: Namen wie GetDecoName der DE-ROM (Farbe/Name + " BETT", Pokemon + ".POSTER",
  -- "RIESIGES " + Pokemon) aus der DE-DecorationNames-Liste; Kategorien des Deko-Menues aus der DE-ROM.
  -- Der Port hat beides englisch im Code.
  local deco = R.deco
  if deco then
    pcall(function()
      local D = require("src.core.gen2.Decorations")
      local N = {}
      for en, parts in pairs(deco.names) do N[en] = T(parts) end
      local function de(en) return W.nachText(N, en) or en end
      -- Namensteile ueber ihre Pruefsumme (englische Port-Texte stehen nicht im Mod)
      local function teil(h) return N[h] end
      local function monDE(base, monName)
        if monName then return monName(base) end
        local G = rawget(_G, "Game")
        local p = G and G.data and G.data.pokemon and G.data.pokemon[base]
        return (p and p.name) or base
      end
      -- Typnummern wie in Decorations.lua (PLANT, BED, CARPET, POSTER, DOLL, BIGDOLL = 1..6)
      D._deutschName = D._deutschName or D.name
      D.name = function(decoId, monName)
        local attr = D.attributes(decoId)
        if not attr then return D._deutschName(decoId, monName) end
        local base, t = attr.name, attr.type
        -- " BED", " CARPET", " POSTER", " DOLL", "BIG " (Port: Decorations.name)
        local bett, teppich, poster, puppe, gross = teil("~983569060004"), teil("~57f4960c0007"),
          teil("~7c09af4a0007"), teil("~c69a7a3a0005"), teil("~cd76bafb0004")
        if t == 2 and bett then return de(base) .. bett end
        if t == 3 and teppich then return de(base) .. teppich end
        if t == 4 and poster then return monDE(base, monName) .. poster end
        if t == 5 and puppe then return monDE(base, monName) .. puppe end
        if t == 6 and gross then return gross .. monDE(base, monName) end
        if t >= 2 and t <= 6 then return D._deutschName(decoId, monName) end
        return de(base)
      end
      -- Kategorien: Reihenfolge von Decorations.CATEGORIES (BED, CARPET, PLANT, POSTER, GAME CONSOLE,
      -- ORNAMENT, BIG DOLL) = Reihenfolge der DE-Strings; danach EXIT
      local KAT = { ["~9563634c0003"] = 1, ["~69efe6120006"] = 2, ["~8bb69c320005"] = 3, ["~5e81c5dc0006"] = 4,
        ["~f490d6aa000c"] = 5, ["~c65c7ad50008"] = 6, ["~f6da27760008"] = 7 }   -- Pruefsummen der Kategorien
      local DM = require("src.ui.gen2.DecorationMenu")
      local Strings = require("src.core.Strings")
      DM._deutschKategorien = DM._deutschKategorien or DM.drawPanel
      DM.drawPanel = function(self, ...)
        if self.mode ~= "category" then return DM._deutschKategorien(self, ...) end
        local Chrome = require("src.ui.gen2.Chrome")
        local p, exit = Chrome.print, Strings("EXIT")
        Chrome.print = function(text, x, y, ...)
          local i = type(text) == "string" and KAT[W.pruefsumme(text)]
          if i and deco.cats[i] then text = T(deco.cats[i])
          elseif text == exit and deco.cats[8] then text = T(deco.cats[8]) end
          return p(text, x, y, ...)
        end
        local ok, e = pcall(DM._deutschKategorien, self, ...)
        Chrome.print = p
        if not ok then error(e, 0) end
        return e
      end
    end)
  end

  -- ------------------------------------------------------------ Importdaten (nach dem Zusammenfuehren)
  mod.events:on("mods.loaded", function(ev)
    local data = ev and ev.data
    if not data then return end
    local game = mod.game
    apply("pfade", R.paths, function(_, p)
      local key = p[1]
      local node = (key == "@oakSpeechData") and (game and game.oakSpeechData) or data[key]
      assert(node, "fehlt: " .. tostring(key))
      for i = 2, #p - 2 do
        node = node[p[i]]
        assert(node ~= nil, "Pfad " .. tostring(key) .. "." .. tostring(p[i]))
      end
      node[p[#p - 1]] = T(p[#p])
    end)
    -- Skript-Menues (Automaten, Preis-Theken, Tafel, Drachenschrein, ...): Box und Eintraege wie in der
    -- DE-ROM.  Der Port liest beide beim Import aus der EN-ROM und zeichnet die Eintraege ohne Strings().
    if R.scriptMenus then
      local n = 0
      for _, tab in ipairs({ data.gen2Scripts, data.gen2StdScripts }) do
        for _, cmds in pairs(tab or {}) do
          if type(cmds) == "table" then
            for _, cmd in ipairs(cmds) do
              local m = type(cmd) == "table" and cmd.menu
              local d = m and R.scriptMenus[m.key]
              if d then
                m.top, m.left, m.bottom, m.right = d.top, d.left, d.bottom, d.right
                if d.items and m.items and #d.items == #m.items then
                  for i, p in ipairs(d.items) do m.items[i] = T(p) end
                end
                if d.gridItems and m.gridItems and #d.gridItems == #m.gridItems then
                  for i, p in ipairs(d.gridItems) do m.gridItems[i] = T(p) end
                  if m.grid and d.spacing then m.grid.spacing = d.spacing end
                end
                n = n + 1
              end
            end
          end
        end
      end
      log:info("Deutsch Gen 2: Skript-Menues: %d angepasst", n)
    end
    -- getstring (Telefon-Ortsnamen, Wochentage, Modulnamen ...): der Port legt cmd.string beim Import aus der
    -- EN-ROM ab und gibt ihn ohne Strings() aus (Vm.lua getstring).  Wo die DE-ROM stattdessen den Ortsnamen
    -- aus der Ortstabelle holt (Gold/Silber-DE: Zusatzbefehl $A3 <Ort>), wird daraus der Port-Befehl
    -- getlandmarkname mit derselben Ortsnummer -- wie im deutschen Original.
    if R.getstring then
      local n = 0
      for _, tab in ipairs({ data.gen2Scripts, data.gen2StdScripts }) do
        for key, cmds in pairs(tab or {}) do
          if type(cmds) == "table" then
            for i, cmd in ipairs(cmds) do
              local g = type(cmd) == "table" and cmd.op == "getstring" and R.getstring[key .. "#" .. i]
              if g then
                if g.ort then
                  cmd.op, cmd.landmark, cmd.string = "getlandmarkname", g.ort, nil
                else
                  cmd.string = T(g)
                end
                n = n + 1
              end
            end
          end
        end
      end
      log:info("Deutsch Gen 2: getstring: %d angepasst", n)
    end
    -- Ereignistabellen (der Port liest sie beim Import aus der EN-ROM): Stockwerke, Tausch-Spitzname/OT,
    -- Buena-Woerter/-Breite/-Sendername -- Werte aus der DE-ROM (R.ereignis)
    local E, et = R.ereignis, data.gen2EventTables
    if E and type(et) == "table" then
      local n = 0
      if E.floors and type(et.floorNames) == "table" then
        for i, p in ipairs(E.floors) do et.floorNames[i] = T(p); n = n + 1 end
      end
      for i, t in ipairs(E.trades or {}) do
        local row = et.trades and et.trades[i]
        if type(row) == "table" then row.nickname, row.otName = T(t.nick), T(t.ot); n = n + 1 end
      end
      local bp = et.buenaPassword
      if E.buena and type(bp) == "table" then
        if E.buena.station then bp.stationName = T(E.buena.station) end
        for i, k in ipairs(E.buena.cats or {}) do
          local cat = bp.categories and bp.categories[i]
          if type(cat) == "table" then
            cat.width = k.width
            if k.words and cat.kind == "string" then
              for j, p in ipairs(k.words) do cat.words[j] = T(p) end
            end
            n = n + 1
          end
        end
      end
      log:info("Deutsch Gen 2: Ereignistabellen: %d angepasst", n)
    end
    -- Kristall-Intro, Icognito-Szene: Kachel- und Attributkarte der DE-ROM (lz3, 1024 Byte wie CrystalMovie readMap)
    local IC = R.introIcognito
    local akt = IC and data.gen2Intro and data.gen2Intro.acts and data.gen2Intro.acts.crystalUnowns
    if type(akt) == "table" then
      local Rom = require("src.import.Rom")
      for _, feld in ipairs({ "tilemap", "attrmap" }) do
        local t = Rom.decompressLz3(rom:sub(IC[feld] + 1, IC[feld] + 0x4000))
        while #t > 1024 do table.remove(t) end
        while #t < 1024 do t[#t + 1] = 0 end
        akt[feld] = t
      end
      log:info("Deutsch Gen 2: Kristall-Intro Icognito-Szene angepasst")
    end
    -- Kartenbloecke, die in der DE-ROM anders sind (Kristall: Wortkammer HO-OH): DE-Bloecke an derselben Stelle
    if R.kartenBloecke and type(data.gen2Maps) == "table" then
      local n = 0
      for mid, b in pairs(R.kartenBloecke) do
        local m = data.gen2Maps[mid]
        if type(m) == "table" and type(m.blocks) == "table" and #m.blocks == b[2] then
          m.blocks = { byte(rom, b[1] + 1, b[1] + b[2]) }
          n = n + 1
        end
      end
      log:info("Deutsch Gen 2: Kartenbloecke: %d angepasst", n)
    end
    -- Icognito-Waende (Kristall): Kachelnummern und Rahmen der DE-ROM (UnownWalls / MenuHeaders_UnownWalls);
    -- der Port zeichnet wall.chars im Rahmen x1..y2 (src/world/gen2/UnownWords.lua)
    local UW = R.unownWalls
    local walls = type(et) == "table" and et.unownWalls
    if UW and type(walls) == "table" then
      local n = 0
      for i, w in ipairs(UW.woerter) do
        local row = walls[i]
        if type(row) == "table" then
          local chars = { byte(rom, w[1] + 1, w[1] + w[2]) }
          local k = UW.koepfe + (i - 1) * 5
          row.chars = chars
          row.flags, row.y1, row.x1, row.y2, row.x2 = byte(rom, k + 1, k + 5)
          n = n + 1
        end
      end
      log:info("Deutsch Gen 2: Icognito-Waende: %d angepasst", n)
    end
    -- Diplom: deutsche Kachelkarte (DiplomaPage1Tilemap der DE-ROM, vom Grafik-Extraktor)
    local gfxData = W.gfxData
    if gfxData.diploma and gfxData.diploma.page1 and data.gen2Diploma then
      data.gen2Diploma.page1 = gfxData.diploma.page1
    end
    local dex = data.gen2Pokedex and data.gen2Pokedex.entries
    apply("dex", R.dex, function(sp, d)
      local e = assert(dex and dex[sp], "Eintrag fehlt")
      e.kind, e.text, e.text2 = T(d.kind), T(d.text), T(d.text2)
      -- DE-Pokedex zeigt metrisch: Groesse in dm (1 Byte), Gewicht in hg (2 Bytes)
      local s = d.size + 1
      e.heightM = byte(rom, s) / 10
      e.weightKg = (byte(rom, s + 1) + byte(rom, s + 2) * 256) / 10
    end)
    -- Bericht (alle Abschnitte aller Bausteine)
    local bad = {}
    for sec, f in pairs(W.failed) do
      if f > 0 then bad[#bad + 1] = sec .. "=" .. f .. " (" .. tostring(W.firstErr[sec]) .. ")" end
    end
    if #bad > 0 then log:warn("Deutsch Gen 2: Fehler: %s", concat(bad, "; ")) end
    local c = W.counts
    log:info("Deutsch Gen 2 (%s): text %d, rom_text %d, strings %d, pfade %d, dex %d, gfx %d", ver,
      c.text or 0, c.rom_text or 0, c.strings or 0, c.pfade or 0, c.dex or 0, c.gfx or 0)
  end)
end
