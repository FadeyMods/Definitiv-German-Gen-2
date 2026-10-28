-- Definitiv German Gen 2 – Kern
--
-- 1. Extraktion: Das Rezept der Edition nennt die Port-Symbole mit ihren Adressen in der DEUTSCHEN ROM; der
--    unveränderte Gen-2-Extraktor des Ports (RomExtractorGen2) läuft damit über die deutsche ROM des Spielers.
--    Dazu liest der Kern einige Stellen direkt (Menüköpfe, Koordinaten im DE-Code, Tastaturen, Kachelbilder).
--    Das Ergebnis liegt im Mod-Cache, solange ROM, Mod und Port gleich bleiben.
-- 2. Übernehmen: nur Anzeigeinhalte (Texte, Namen, Beschreibungen, Pokédex, Orts- und Stockwerksnamen, Schrift,
--    Bilder mit Schrift); Spieldaten bleiben, wie sie sind.  Skripttexte (Data.gen2Text) heißen im Port nach ihrer
--    Adresse in der EN-ROM („bank:addr“); das Rezept ordnet jedem EN-Schlüssel die DE-Adresse zu (g2t, g2s).
-- 3. Haken: wo der Port Lage, Breite oder Wortlaut fest nach der EN-ROM setzt, wird die Zeichen- bzw.
--    Aufbaufunktion umhüllt und auf die Werte der DE-ROM umgesetzt.  Jeder Haken prüft, ob die Port-Funktion
--    noch da ist; schlägt einer fehl, steht das im Log (K.start: haken).
return function(mod, MODVERSION)
  local GameVersion = require("src.core.GameVersion")
  local RomExtractorGen2 = require("src.import.RomExtractorGen2")
  local Version = require("src.core.Version")
  local Opcodes = require("src.script.gen2.Opcodes")

  local G = assert(load(mod:read("gemeinsam.lua"), "@gemeinsam.lua"))()(mod)
  local K = {}
  local kopie = G.kopie
  local unpack = table.unpack or unpack

  local IMPORT = { gold = "gold_de", silver = "silber_de", crystal = "kristall_de" }

  -- f(...) geschützt aufrufen, danach in jedem Fall zurueck() (vorübergehend ersetzte Funktionen wiederherstellen),
  -- Fehler weiterreichen, sonst die Rückgabewerte von f
  local function danach(zurueck, f, ...)
    local erg = { pcall(f, ...) }
    zurueck()
    if not erg[1] then error(erg[2], 0) end
    return unpack(erg, 2)
  end

  -- Kachelbild (Graustufen, Farbe 0 durchsichtig) aus Pixelwerten 0–3 als Ziffernkette, Zeile für Zeile
  local function obj_bild(pix, breite, hoehe)
    local SCHATTEN = { 255, 170, 85, 0 }
    local id = love.image.newImageData(breite, hoehe)
    for i = 1, breite * hoehe do
      local w = tonumber(pix:sub(i, i))
      local g = SCHATTEN[w + 1] / 255
      id:setPixel((i - 1) % breite, math.floor((i - 1) / breite), g, g, g, w == 0 and 0 or 1)
    end
    local img = love.graphics.newImage(id)
    img:setFilter("nearest", "nearest")
    return img
  end

  -- ================================================================ 1. Extraktion

  -- Manifest des Ports mit den Symbolen der DE-ROM und dem deutschen Zeichensatz
  local function manifest(edition, rezept, Z)
    local m = G.rom_manifest(edition)
    local syms = {}
    for name, ort in pairs(m.symbols) do
      if ort[2] >= 0x8000 then syms[name] = ort end  -- RAM bleibt; ROM nur mit belegter DE-Adresse
    end
    for name, ort in pairs(rezept.s) do syms[name] = { ort[1], ort[2] } end
    m.symbols = syms
    m.symbolRevisions = nil
    Z.anwenden(m)
    return m
  end

  -- Pokédex der deutschen Editionen: Kategorie@, Größe (1 Byte, Dezimeter), Gewicht (2 Byte, Hektogramm), dann zwei
  -- Seiten Text (wie Gen 1 DE).  Der Port zeigt metrische Werte über heightM / weightKg (src/ui/gen2/PokedexMenu.lua).
  local function pokedexDe(self)
    self:beginStage("Pokedex")
    local consts = self.manifest.constants
    local speciesOrder = consts.speciesOrder or {}
    local charmap = self.manifest.charmap or {}
    local entries = {}
    for index, species in ipairs(speciesOrder) do
      local asset = self.manifest.pokemonAssets[species]
      local symbol = asset and asset.dexLabel and self.symbols[asset.dexLabel]
      if symbol and species ~= "UNUSED" then
        local bank, address = symbol[1], symbol[2]
        local kind, consumed = self.rom:readString(bank, address, charmap, 0x50, 24)
        local at = address + consumed
        local dm = self.rom:byte(bank, at)
        local hg = self.rom:word(bank, at + 1)
        local text, n1 = self.rom:readString(bank, at + 3, charmap, 0x50, 256)
        local text2 = self.rom:readString(bank, at + 3 + n1, charmap, 0x50, 256)
        entries[species] = { id = species, dex = index, kind = kind, heightM = dm / 10, weightKg = hg / 10,
          text = text, text2 = text2 }
      end
    end
    local function readOrder(name, length)
      local s = self:symbol(name)
      local list = {}
      for i = 0, length - 1 do
        local id = self.rom:byte(s.bank, s.address + i)
        list[i + 1] = speciesOrder[id] or id
      end
      return list
    end
    local data = { generation = 2, entries = entries,
      newOrder = readOrder("NewPokedexOrder", #speciesOrder),
      alphabeticalOrder = readOrder("AlphabeticalPokedexOrder", #speciesOrder) }
    self:write("pokedex", data)
    return data
  end

  -- Ergebnisse der Stufen, die der Mod braucht (Name in data/generated → behalten)
  local BEHALTEN = { font = true, text = true, rom_text = true, pokemon = true, moves = true, items = true,
    type_chart = true, trainers = true, pokedex = true, landmarks = true, events = true, oak_speech = true,
    menu_gfx = true, credits = true, diploma = true, title = true, trade = true, intro = true, maps = true,
    tilesets = true, scripts = true }

  -- Anzeige-Zeichenketten eines Skripts (Menüeinträge samt Kastenmaßen, stringtotext, Briefe) je Befehlsnummer
  local function anzeige_von(befehle)
    local aus = {}
    for i, cmd in ipairs(befehle or {}) do
      if type(cmd) == "table" and (cmd.menu or cmd.string or cmd.mail) then
        aus[i] = { op = cmd.op, menu = cmd.menu, string = cmd.string, mail = cmd.mail }
      end
    end
    return aus
  end

  -- Tastatur-Tafel der DE-ROM (data/text/name_input_chars.asm, mail_input_chars.asm): „zeilen“ Zeilen zu „breite“
  -- Bytes mit je „zellen“ Zeichen auf den geraden Spalten, danach die Umschaltzeile („klein LÖSCH ENDE“).  Ergebnis:
  -- Zellen als Zeichenfolgen des Ports ($7F = Leerzeichen) und die Anfangsspalten der drei Wörter der Umschaltzeile.
  local function tafel(ex, ort, zeilen, zellen, breite, charmap)
    local raster, adr = {}, ort[2]
    for r = 1, zeilen do
      local z = {}
      for c = 1, zellen do
        local x = ex.rom:byte(ort[1], adr + (c - 1) * 2)
        z[c] = x == 0x7F and " " or charmap[tostring(x)]
        if not z[c] then error(("Tastatur %02X:%04X: Zeichen $%02X unbekannt"):format(ort[1], ort[2], x)) end
      end
      raster[r] = z
      adr = adr + breite
    end
    local spalten, vorher_leer = {}, true
    for i = 0, breite - 1 do
      local leer = ex.rom:byte(ort[1], adr + i) == 0x7F
      if not leer and vorher_leer then spalten[#spalten + 1] = i end
      vorher_leer = leer
    end
    if #spalten ~= 3 then error(("Tastatur %02X:%04X: Umschaltzeile ohne drei Wörter"):format(ort[1], ort[2])) end
    -- erstes Wort der Umschaltzeile („klein“ auf der Großtafel, „GROß“ auf der Kleintafel)
    local wort = {}
    for i = spalten[1], breite - 1 do
      local x = ex.rom:byte(ort[1], adr + i)
      if x == 0x7F then break end
      wort[#wort + 1] = charmap[tostring(x)] or ""
    end
    return { zeilen = raster, spalten = spalten, wort = table.concat(wort) }
  end

  local function tasten_lesen(ex, t, charmap)
    return {
      name_klein = tafel(ex, t.name_klein, 4, 9, 17, charmap), name_gross = tafel(ex, t.name_gross, 4, 9, 17, charmap),
      box_klein = tafel(ex, t.box_klein, 5, 9, 17, charmap), box_gross = tafel(ex, t.box_gross, 5, 9, 17, charmap),
      brief_klein = tafel(ex, t.brief_klein, 5, 10, 19, charmap),
      brief_gross = tafel(ex, t.brief_gross, 5, 10, 19, charmap),
    }
  end

  -- Kachelkoordinate aus einem Befehl des DE-Codes (Befehl op, dann Adresse in der Kachelkarte ab karte, 20 breit)
  local function koord(ex, b, a, op, karte)
    if ex.rom:byte(b, a) ~= op then error(("%02X:%04X kein Befehl $%02X"):format(b, a, op)) end
    local v = ex.rom:word(b, a + 1) - karte
    return v % 20, math.floor(v / 20)
  end

  -- Kasten im DE-Code: ld hl, Kachel / ld b, Höhe / ld c, Breite
  local function kasten(ex, b, a, karte)
    if ex.rom:byte(b, a + 3) ~= 0x06 or ex.rom:byte(b, a + 5) ~= 0x0E then
      error(("%02X:%04X kein Kasten"):format(b, a))
    end
    local x, y = koord(ex, b, a, 0x21, karte)
    return x, y, ex.rom:byte(b, a + 4), ex.rom:byte(b, a + 6)
  end

  -- eine Zeile einer 2bpp-Kachel (zwei Bytes ab adr) als acht Pixelwerte 0–3 nach pix[basis …]
  local function kachelzeile(ex, b, adr, pix, basis)
    local lo, hi = ex.rom:byte(b, adr), ex.rom:byte(b, adr + 1)
    for bit = 7, 0, -1 do
      pix[basis + (7 - bit)] = (math.floor(lo / 2 ^ bit) % 2) + 2 * (math.floor(hi / 2 ^ bit) % 2)
    end
  end

  -- Lesestufen für Rezeptfelder: leser(feld, was, f) – beim Extrahieren daten[feld] = f(ex, rezept[feld], charmap);
  -- ein Fehler kommt als „was: Meldung“ in die Fehlerliste (dann kein Cache).  Felder ohne Eintrag im Rezept gibt es
  -- bei dieser Edition nicht.  Gelesen wird in der Reihenfolge der leser-Aufrufe.
  local LESER = {}
  local function leser(feld, was, f) LESER[#LESER + 1] = { feld = feld, was = was, f = f } end

  -- VM statt HM (Rezept vm): die DE-ROM nennt die Versteckten Maschinen „VM01“ … (GetTMHMName) und schreibt in der
  -- TM-Tasche „V1“ (tmhm.asm); der Port setzt beides selbst mit „HM“ bzw. „H“ zusammen (RomExtractorGen2
  -- extractItems tmLabel, PackMenu tmhmLabelFor)
  leser("vm", "VM", function(ex, r, cm)
    local p, t = r.praefix, r.tasche
    local praefix = ex.rom:readString(p[1], p[2], cm, 0x50, 4)
    return { praefix = praefix, tasche = cm[tostring(ex.rom:byte(t[1], t[2]))] }
  end)

  -- Uhr-Kasten im Hauptmenü (Rezept uhr, Gold/Silber): Kasten, Wochentag und Uhrzeit (decoord) aus dem DE-Code
  leser("uhr", "Uhr", function(ex, u)
    local k = u.kasten
    local x, y, h, w = kasten(ex, k[1], k[2], u.karte)
    return { x = x, y = y, h = h, w = w, tag = { koord(ex, u.tag[1], u.tag[2], 0x11, u.karte) },
      zeit = { koord(ex, u.zeit[1], u.zeit[2], 0x11, u.karte) } }
  end)

  -- Karten-Flip, Münzfenster (Rezept muenzen): Kasten, Beschriftung (+10) und Zahl (+19) aus dem DE-Code
  leser("muenzen", "Münzfenster", function(ex, r)
    local b, a, karte = r[1], r[2], r.karte
    local x, y, h, w = kasten(ex, b, a, karte)
    local lx, ly = koord(ex, b, a + 10, 0x21, karte)
    local zx, zy = koord(ex, b, a + 19, 0x21, karte)
    return { x = x, y = y, h = h, w = w, lx = lx, ly = ly, zx = zx, zy = zy }
  end)

  -- Käferwettbewerb, Tausch-Bildschirm (Rezept kaefertausch, ContestDropOffMons): Spalte der Beschriftung „  GESU“
  -- und der KP-Zahl aus den hlcoord-Befehlen der DE-ROM (EN 5 und 11, DE eine Spalte weiter links)
  leser("kaefertausch", "Käfertausch", function(ex, r)
    local gx = koord(ex, r.gesu[1], r.gesu[2], 0x21, r.karte)
    local kx = koord(ex, r.kp[1], r.kp[2], 0x21, r.karte)
    return { gesu = gx, kp = kx }
  end)

  -- Diplom (Rezept diplom, PlaceDiplomaOnScreen): Wort „TRAINER“ (ld de / hlcoord), dann der Spielername – in der
  -- DE-ROM nicht an fester Spalte, sondern hinter dem Wort (ld h, b / ld l, c / inc hl) –, dann die Bestätigung
  -- (ld de / hlcoord); PlaceString setzt sie mit <NEXT> zwei Zeilen tiefer je Zeile
  leser("diplom", "Diplom", function(ex, r)
    local b, a, karte = r[1], r[2], r.karte
    if ex.rom:byte(b, a) ~= 0x11 then error(("%02X:%04X kein ld de"):format(b, a)) end
    local wx, wy = koord(ex, b, a + 3, 0x21, karte)
    local p, name = a + 12, nil
    if ex.rom:byte(b, p) == 0x60 and ex.rom:byte(b, p + 1) == 0x69 and ex.rom:byte(b, p + 2) == 0x23 then
      name = "hinter_wort"
    else
      name = { koord(ex, b, p, 0x21, karte) }
    end
    local tx, ty = koord(ex, b, p + 9, 0x21, karte)
    return { wort = { wx, wy }, name = name, text = { tx, ty } }
  end)

  -- Geschlechtswahl (Rezept geschlecht, Kristall): menu_coords aus dem MenuHeader der DE-ROM
  leser("geschlecht", "Geschlechtswahl", function(ex, r)
    local b, a = r[1], r[2]
    if ex.rom:byte(b, a) ~= 0x40 then error("kein MenuHeader") end
    return { y1 = ex.rom:byte(b, a + 1), x1 = ex.rom:byte(b, a + 2), y2 = ex.rom:byte(b, a + 3),
      x2 = ex.rom:byte(b, a + 4) }
  end)

  -- PC-Menüs (Rezept pcmenue): rechte Spalte aus dem MenuHeader der DE-ROM (menu_coords …, 12, x2 – „ITEM AUFNEHMEN“
  -- braucht eine Spalte mehr als „WITHDRAW ITEM“)
  leser("pcmenue", "PC-Menü", function(ex, r)
    local aus = {}
    for name, ort in pairs(r) do
      local flags = ex.rom:byte(ort[1], ort[2])
      if (flags ~= 0x40 and flags ~= 0x48) or ex.rom:byte(ort[1], ort[2] + 1) ~= 0 then
        error(("%02X:%04X kein MenuHeader"):format(ort[1], ort[2]))
      end
      aus[name] = ex.rom:byte(ort[1], ort[2] + 4) + 1
    end
    return aus
  end)

  -- Pokédex-Suche (Rezept dexsuche): die Typ-Tafel der DE-ROM (PokedexTypeSearchStrings, je 8 Zeichen + „@“, zuerst
  -- „  ----  “), in der Reihenfolge, in der das Rad sie durchläuft
  leser("dexsuche", "Dex-Suche", function(ex, r, cm)
    local b, a = r[1], r[2]
    local aus = {}
    for i = 0, 17 do
      if ex.rom:byte(b, a + i * 9 + 8) ~= 0x50 then error(("%02X:%04X keine Tafel"):format(b, a)) end
      local t = {}
      for j = 0, 7 do
        local x = ex.rom:byte(b, a + i * 9 + j)
        t[#t + 1] = x == 0x7F and " " or cm[tostring(x)] or error(("Zeichen $%02X"):format(x))
      end
      aus[i] = table.concat(t)
    end
    return aus
  end)

  -- Statusseite 2 (Rezept statusseite): Spalte des getragenen Items (hlcoord im DE-Code) und die zwei Kacheln, die
  -- die DE-ROM für „AP“ setzt (ld [hl], $32 / inc hl / ld [hl], $3E – fette Kacheln der Status-Grafik)
  leser("statusseite", "Statusseite", function(ex, r)
    local x, y = koord(ex, r.item[1], r.item[2], 0x21, r.karte)
    local kb, ka = r.ap[1], r.ap[2]
    if ex.rom:byte(kb, ka) ~= 0x36 or ex.rom:byte(kb, ka + 2) ~= 0x23 or ex.rom:byte(kb, ka + 3) ~= 0x36 then
      error(("%02X:%04X keine AP-Kacheln"):format(kb, ka))
    end
    return { item_x = x, item_y = y, ap = { ex.rom:byte(kb, ka + 1), ex.rom:byte(kb, ka + 4) } }
  end)

  -- Team-Untermenü (Rezept teammenue, mon_submenu.asm MonSubmenu .MenuHeader): linke Spalte des Kastens in der DE-ROM
  leser("teammenue", "Team-Untermenü", function(ex, r)
    local b, a = r[1], r[2]
    if ex.rom:byte(b, a) ~= 0x40 or ex.rom:byte(b, a + 1) ~= 0 or ex.rom:byte(b, a + 4) ~= 19 then
      error(("%02X:%04X kein MenuHeader"):format(b, a))
    end
    return ex.rom:byte(b, a + 2)
  end)

  -- Pokédex-Suche (Rezept suchbild): das 3×3-Kachel-OBJ in der Mitte der Suche (Kachelbogen 16 Kacheln breit, Zeilen
  -- im Abstand $100) und seine OBJ-Palette; die ROM zeigt sie über rOBP0 = %11100000 (Farbe 1 = Farbe 0)
  leser("suchbild", "Suchbild", function(ex, r)
    local g, pa = r.gfx, r.pal
    local pix = {}
    for ky = 0, 2 do
      for kx = 0, 2 do
        for zeile = 0, 7 do
          kachelzeile(ex, g[1], g[2] + ky * 0x100 + kx * 16 + zeile * 2, pix, (ky * 8 + zeile) * 24 + kx * 8 + 1)
        end
      end
    end
    local c = ex:colors(pa[1], pa[2], 4)
    return { pix = table.concat(pix), pal = { c[1], c[1], c[3], c[4] }, x = r.x, y = r.y }
  end)

  -- Brief schreiben (Rezept briefsymbol): der Umschlag oben links (vier 2bpp-Kacheln, OBJ oben links, rechts, unten
  -- links, rechts) und seine OBJ-Palette aus der DE-ROM
  leser("briefsymbol", "Briefsymbol", function(ex, r)
    local g, pa = r.gfx, r.pal
    local pix = {}
    for k = 0, 3 do
      local ox, oy = (k % 2) * 8, math.floor(k / 2) * 8
      for zeile = 0, 7 do
        kachelzeile(ex, g[1], g[2] + k * 16 + zeile * 2, pix, (oy + zeile) * 16 + ox + 1)
      end
    end
    return { pix = table.concat(pix), pal = ex:colors(pa[1], pa[2], 4) }
  end)

  -- Spielautomat, Einsatz (Rezept einsatz, slot_machine.asm Slots_AskBet .MenuHeader): menu_coords und die drei
  -- Einträge der DE-ROM (Kristall DE: Kasten 15,6 – 19,13, „3“ ohne Leerzeichen)
  leser("einsatz", "Einsatz", function(ex, r, cm)
    local b, a = r[1], r[2]
    if ex.rom:byte(b, a) ~= 0x40 or ex.rom:byte(b, a + 9) ~= 3 then
      error(("%02X:%04X kein MenuHeader"):format(b, a))
    end
    local w = { y1 = ex.rom:byte(b, a + 1), x1 = ex.rom:byte(b, a + 2), y2 = ex.rom:byte(b, a + 3),
      x2 = ex.rom:byte(b, a + 4), labels = {} }
    local adr = a + 10
    for i = 1, 3 do
      local t, n = ex.rom:readString(b, adr, cm, 0x50, 6)
      w.labels[i] = t
      adr = adr + n
    end
    return w
  end)

  -- Startmenü (Rezept startmenue_ende): Beschreibung der letzten Zeile (.ExitDesc, „Menü / schliessen“)
  leser("startmenue_ende", "Startmenü", function(ex, r, cm)
    local t = G.romtext(ex, cm, r[1], r[2], 1, 0, 0)
    if type(t) ~= "string" then error(tostring(t)) end
    return t
  end)

  -- Duellturm-Menü (Rezept turmmenue, Kristall): menu_coords des MenuHeaders der DE-ROM (y1, x1, y2, x2 ab Byte 1)
  leser("turmmenue", "Duellturm-Menü", function(ex, r)
    local b, a = r[1], r[2]
    return { ex.rom:byte(b, a + 1), ex.rom:byte(b, a + 2), ex.rom:byte(b, a + 3), ex.rom:byte(b, a + 4) }
  end)

  -- Ruhmeshalle (Rezept hof_trenner): das Zeichen hinter „<ID>№“, das DisplayHOFMon/HOF_AnimatePlayerPic mit
  -- `ld [hl], …` schreiben (EN „/“, DE „.“) – Bank/Adresse des Operanden
  leser("hof_trenner", "Ruhmeshalle", function(ex, r, cm)
    local z = cm[tostring(ex.rom:byte(r[1], r[2]))]
    if type(z) ~= "string" or z == "" then error("kein Trennzeichen") end
    return z
  end)

  -- Tastaturen (Rezept tasten): Namens-, Box- und Brieftafeln mit Ä Ö Ü ä ö ü ß und die Lage der Umschaltzeile
  leser("tasten", "Tastaturen", function(ex, r, cm) return tasten_lesen(ex, r, cm) end)

  -- Titelbild Gold/Silber (Rezept titel_streifen): der Untertitel „GOLDENE EDITION“ ist eine Spalte breiter als „GOLD
  -- VERSION“; die DE-ROM färbt den Streifen entsprechend breiter, der Port-Extraktor nimmt die EN-Breite fest →
  -- zusätzliche Kacheln nachfärben: Schatten je Pixel aus dem grauen Bild, Farbe je Schatten aus dem Streifen selbst
  local function titel_streifen(bilder, ts)
    if type(ts) ~= "table" or not (ts.de_w and ts.en_w and ts.de_w > ts.en_w) then return end
    pcall(function()
      local y0 = ts.y * 8
      for _, rel in ipairs({ "title/title_screen.png", "title/pokemon_logo.png" }) do
        local farbe, grau = bilder[rel], bilder["title/title_screen_gray.png"]
        if farbe and grau then
          local karte = {}
          for y = y0, y0 + 7 do
            for x = ts.x * 8, (ts.x + ts.en_w) * 8 - 1 do
              local g = grau:getPixel(x, y)
              local r, gg, b = farbe:getPixel(x, y)
              karte[math.floor(g * 255 + 0.5)] = karte[math.floor(g * 255 + 0.5)] or { r, gg, b }
            end
          end
          for y = y0, y0 + 7 do
            for x = (ts.x + ts.en_w) * 8, (ts.x + ts.de_w) * 8 - 1 do
              local f = karte[math.floor(grau:getPixel(x, y) * 255 + 0.5)]
              if f then farbe:setPixel(x, y, f[1], f[2], f[3], 1) end
            end
          end
        end
      end
    end)
  end

  -- Port-Texte (Menüs, Statuswerte, Engine-Meldungen …), deren Vorlage in der ROM steht (Rezept p, pk)
  local function porttexte(ex, rezept, m, daten, fehler)
    local ok, p, pk = pcall(G.porttexte_lesen, ex, rezept, m.charmap, { text = daten.rom_text or {},
      pokemon = daten.pokemon, moves = daten.moves, items = daten.items })
    if not ok then
      fehler[#fehler + 1] = "Port-Texte: " .. tostring(p)
      return
    end
    -- PokéCom-Uhr: die DE-ROM führt „ WEITER▶“ als eine Zeichenkette, den Pfeil zeichnet der Port selbst
    -- (Pokegear:drawClock, cursor 19,1) → Pfeil am Ende weglassen
    local pg = type(pk) == "table" and pk["src/ui/gen2/Pokegear.lua"]
    for k, v in pairs(type(pg) == "table" and pg or {}) do
      if type(v) == "string" then pg[k] = v:gsub("\226\150\182$", "") end
    end
    -- Trenner, die der Port anders erwartet als die ROM sie schreibt (Rezept ersetzen = { [Prüfsumme] = { alt,
    -- neu } }): Ei-Texte der Statusseite (<NEXT> statt Zeilenwechsel), Kampfturm-Seiten (Leerzeile statt Absatz)
    for chk, e in pairs(type(rezept.ersetzen) == "table" and rezept.ersetzen or {}) do
      if type(p[chk]) == "string" and type(e) == "table" and type(e[1]) == "string" and type(e[2]) == "string" then
        local alt, neu = e[1], e[2]
        p[chk] = p[chk]:gsub(alt:gsub("%p", "%%%0"), (neu:gsub("%%", "%%%%")))
      end
    end
    daten.porttexte, daten.portkontexte = p, pk
  end

  -- Namenslisten und kurze Zeichenketten direkt aus der DE-ROM (fehlende Einträge bleiben still weg)
  local function listen(ex, rezept, m, daten)
    -- Kampfmenü: Spalte des Kastens und Spaltenabstand aus den DE-Menüköpfen (Rezept km2)
    if rezept.km2 then
      local km = {}
      for art, ort in pairs(rezept.km2) do
        local ok, wert = pcall(function()
          local md = ex.rom:word(ort[1], ort[2] + 5)
          return { x = ex.rom:byte(ort[1], ort[2] + 2), abstand = ex.rom:byte(ort[1], md + 2) }
        end)
        if ok then km[art] = wert end
      end
      daten.kampfmenue = km
    end
    -- Pokédex-Modi: zwei Zeilen Beschreibung je Modus (die DE-Fassung formuliert die erste Zeile je Modus anders)
    if rezept.dexmodi then
      local dm = {}
      for i, ort in ipairs(rezept.dexmodi) do
        local ok, t = pcall(G.romtext, ex, m.charmap, ort[1], ort[2], 1, 0, 0)
        if ok and t then dm[i] = t end
      end
      daten.dexmodi = dm
    end
    -- Radiosender: Namen aus der DE-ROM (Rezept sender, Station → Bank/Adresse)
    if rezept.sender then
      local s = {}
      for id, ort in pairs(rezept.sender) do
        local ok, t = pcall(G.romtext, ex, m.charmap, ort[1], ort[2], 1, 0, 0)
        if ok and t then s[id] = t end
      end
      daten.sender = s
    end
    -- Dekorationsnamen: DecorationNames der DE-ROM (26 @-Einträge), Zuordnung über die Prüfsummen der EN-Einträge
    if rezept.deko then
      local b, a, liste = rezept.deko[1], rezept.deko[2], {}
      for i = 1, #rezept.deko[3] do
        local ok, t, n = pcall(ex.rom.readString, ex.rom, b, a, m.charmap, 0x50, 40)
        if not ok then break end
        for chk in tostring(rezept.deko[3][i]):gmatch("[^|]+") do liste[chk] = t end
        a = a + n
      end
      daten.deko = liste
    end
    -- Namensvorschläge des Spielers (data/player_names.asm PlayerNameArray, Kristall auch FemalePlayerNameArray):
    -- fünf @-Zeichenketten, die erste ist der Menüpunkt für die eigene Eingabe
    if rezept.namen2 then
      daten.namen2 = {}
      for wer, ort in pairs(rezept.namen2) do
        local a, l = ort[2], {}
        for i = 1, 5 do
          local ok, t, n = pcall(ex.rom.readString, ex.rom, ort[1], a, m.charmap, 0x50, 12)
          if not ok or type(t) ~= "string" then break end
          l[i] = t
          a = a + n
        end
        if #l == 5 then
          daten.namen2[wer] = l
          -- danach (STATICMENU_PLACE_TITLE): Einrückung des Titels und der Titel selbst (DE-Gold/-Silber „ NAME “ ab
          -- Spalte 1, EN-Gold „NAME“ ab Spalte 2)
          local einr = ex.rom:byte(ort[1], a)
          local ok, t = pcall(ex.rom.readString, ex.rom, ort[1], a + 1, m.charmap, 0x50, 12)
          if einr <= 4 and ok and type(t) == "string" and t:match("%S") then
            daten.namen2.titel = { x = einr, text = t }
          end
        end
      end
    end
    -- Feste NPC-Namen (Rezept npcnamen): Telefonliste NonTrainerCallerNames (vier @-Namen nach „----------“, Kristall
    -- mit „:“) und der Name im Fang-Tutorial (CatchTutorial .Dude)
    if rezept.npcnamen then
      local nn, t = {}, rezept.npcnamen.telefon
      if type(t) == "table" then
        local a, tel = t[2], {}
        for i = 1, #t[3] do
          local ok, s, n = pcall(ex.rom.readString, ex.rom, t[1], a, m.charmap, 0x50, 20)
          if not ok or type(s) ~= "string" then break end
          if t[4] then s = s:gsub(":$", "") end
          tel[t[3][i]] = s
          a = a + n
        end
        nn.telefon = tel
      end
      local k = rezept.npcnamen.kumpel
      if type(k) == "table" then
        local ok, s = pcall(ex.rom.readString, ex.rom, k[1], k[2], m.charmap, 0x50, 12)
        if ok and type(s) == "string" and s ~= "" then nn.kumpel = { [k[3]] = s } end
      end
      daten.npcnamen = nn
    end
  end

  -- Skripttexte und Anzeige-Zeichenketten der Skripte unter dem EN-Schlüssel, den das Rezept zuordnet (g2t, g2s)
  local function skripte(ex, rezept, m, daten)
    local deText = daten.text or {}
    local skript = {}
    for en, de in pairs(rezept.g2t or {}) do
      local t = deText[de]
      if t == nil then
        local b, a = de:match("^(%x%x):(%x%x%x%x)$")
        if b then
          local ok, d = pcall(ex.decodeGen2Text, ex, tonumber(b, 16), tonumber(a, 16), m.charmap)
          if ok then t = d end
        end
      end
      if t ~= nil then skript[en] = t end
    end
    daten.text = nil
    daten.skripttext = skript
    local anzeige = {}
    for en, de in pairs(rezept.g2s or {}) do
      local befehle = daten.scripts and daten.scripts[de]
      if befehle then
        anzeige[en] = anzeige_von(befehle)
        -- Gold/Silber DE: wo die EN-ROM „getstring <Ortsname>“ hat, steht Befehl $A3 <Landmarke> <Puffer> (wie
        -- Kristalls getlandmarkname, den der Extraktor für Gold/Silber nicht kennt) – der Ort kommt dann aus der
        -- Landmarken-Tabelle
        for i, cmd in ipairs(befehle) do
          local b, a
          if type(cmd) == "table" and cmd.op == "unknown" and cmd.code == 0xA3 then
            b, a = tostring(cmd.source or ""):match("^ROM:(%x%x):(%x%x%x%x)$")
          end
          if b then
            -- source ist der Skriptanfang: die Befehle davor nach ihrer Länge (Opcodes, Gold/Silber) überspringen
            local bank, pos, okw = tonumber(b, 16), tonumber(a, 16), true
            for _ = 1, i - 1 do
              local okb, op = pcall(ex.rom.byte, ex.rom, bank, pos)
              local def = okb and Opcodes[op]
              if not (def and def.size) then okw = false break end
              pos = pos + 1 + def.size
            end
            local okb, op = pcall(ex.rom.byte, ex.rom, bank, pos)
            local okl, lm = pcall(ex.rom.byte, ex.rom, bank, pos + 1)
            if okw and okb and op == 0xA3 and okl and type(lm) == "number" then
              anzeige[en][i] = { op = "getstring", landmarke = lm }
            end
          end
        end
      end
    end
    daten.scripts = nil
    daten.skriptanzeige = anzeige
  end

  local function extrahieren(edition, rom, rezept, Z)
    local m = manifest(edition, rezept, Z)
    local ex = RomExtractorGen2.new(rom, m, nil, nil)
    local daten, bilder, fehler = {}, {}, {}
    ex.write = function(_, name, wert) if BEHALTEN[name] then daten[name] = wert end end
    ex.save = function(_, bild, rel) bilder[rel] = bild end
    ex.extractPokedex = pokedexDe
    local function stufe(name, ...)
      local ok, wert = pcall(ex[name], ex, ...)
      if not ok then fehler[#fehler + 1] = name .. ": " .. tostring(wert) end
      return ok and wert or nil
    end
    stufe("extractConstants")
    stufe("extractFont")
    stufe("extractTilesets")
    local maps = stufe("extractMaps")
    local std = stufe("extractStdScripts")
    if maps then stufe("extractScriptsAndText", maps, std) end
    stufe("extractText")
    local pokemon = stufe("extractPokemon")
    stufe("extractMoves")
    stufe("extractItems")
    stufe("extractTrainers")
    stufe("extractPokedex")
    stufe("extractLandmarks")
    stufe("extractIntro")
    stufe("extractMenuGfx")
    if edition == "crystal" then stufe("extractMobileGfx") end
    if pokemon then stufe("extractOakSpeech", pokemon) end
    stufe("extractTitle")
    stufe("extractCredits")
    stufe("extractDiploma")
    stufe("extractTrade")
    titel_streifen(bilder, rezept.titel_streifen)
    for rel, bild in pairs(bilder) do
      if not G.anders_als_en(rel, bild) then bilder[rel] = nil end
    end
    listen(ex, rezept, m, daten)
    porttexte(ex, rezept, m, daten, fehler)
    for _, l in ipairs(LESER) do
      if type(rezept[l.feld]) == "table" then
        local ok, wert = pcall(l.f, ex, rezept[l.feld], m.charmap)
        if ok then daten[l.feld] = wert else fehler[#fehler + 1] = l.was .. ": " .. tostring(wert) end
      end
    end
    -- ROM-Literale (Rezept pl): Menüwörter und Überschriften, die der Port fest einträgt
    daten.romliterale = G.romliterale_lesen(ex, rezept, m.charmap)
    skripte(ex, rezept, m, daten)
    -- Karten und Kachelsätze: nur Blöcke / Kollision (Wandwörter der Alph-Ruinen, Schilder, Poster)
    local karten = {}
    for id, k in pairs(daten.maps or {}) do
      if type(k) == "table" and k.blocks then karten[id] = { blocks = k.blocks } end
    end
    daten.maps = karten
    local saetze = {}
    for id, t in pairs(daten.tilesets or {}) do
      if type(t) == "table" and t.blocks then saetze[id] = { blocks = t.blocks, collision = t.collision } end
    end
    daten.tilesets = saetze
    return daten, bilder, fehler
  end

  -- ================================================================ 2. Übernehmen
  local function schluessel_artig(s)
    return type(s) == "string" and s:match("^%x%x:%x%x%x%x$") ~= nil
  end

  -- DE-Tabelle in die EN-Tabelle einmischen: nur Blätter, die es in EN gibt, vom selben Typ sind und sich
  -- unterscheiden; erlaubt(pfad, en, de) entscheidet je Feld (Anzeige ja, Adressen/Kennungen nein).
  local function einmischen(ziel, quelle, erlaubt, pfad, zaehler)
    if type(ziel) ~= "table" or type(quelle) ~= "table" then return end
    for k, v in pairs(quelle) do
      local alt = ziel[k]
      local p = pfad .. "." .. tostring(k)
      if type(v) == "table" and type(alt) == "table" then
        einmischen(alt, v, erlaubt, p, zaehler)
      elseif alt ~= nil and type(alt) == type(v) and alt ~= v and erlaubt(p, alt, v) then
        ziel[k] = v
        zaehler.n = zaehler.n + 1
      end
    end
  end

  local function nur_texte(_p, alt, neu)
    return type(neu) == "string" and not schluessel_artig(alt) and not schluessel_artig(neu)
  end

  local function alles(_p, alt, neu) return not schluessel_artig(alt) and not schluessel_artig(neu) end

  -- Ereignistabellen: Texte (Tauschdialoge, Spitznamen, OT, Stockwerke, Buena-Passwort, Icognito-Wörter) und die
  -- Anzeige-Zahlen dazu (Breite der Passwort-Spalten, Icognito-Buchstaben und Wandbreite); keine Adressen
  local function ereignis_erlaubt(p, alt, neu)
    if type(neu) == "string" then return nur_texte(p, alt, neu) end
    if p:match("[Aa]ddress$") or p:match("%.condition$") or p:match("%.bank$") then return false end
    return p:match("^%.unownWalls") ~= nil or p:match("^%.buenaPassword%.categories.*%.width$") ~= nil
  end

  -- Trainer: Namen, Klassennamen, Kampfturm-Sprüche (Texte) und die Kampfturm-Rohnamen (Bytes, aus denen der Port
  -- den Namen setzt)
  local function trainer_erlaubt(p, alt, neu)
    if type(neu) == "string" then return nur_texte(p, alt, neu) end
    return p:match("%.nameRaw%.%d+$") ~= nil
  end

  -- Vor dem Zusammenführen (Registries): Texte, Namen, Beschreibungen, Pokédex-Einträge
  local function registries(daten, bericht)
    local c = mod.content
    local n = 0
    for en, t in pairs(daten.skripttext or {}) do
      -- leerer DE-Text (Kristall: PokéCom-Center, „text_start / done“): die DE-ROM zeigt ein leeres Fenster, der Port
      -- zeigt für "" „...“ (src/script/gen2/Vm.lua showText) → ein Leerzeichen, das nichts zeichnet
      if t == "" then t = " " end
      c.text:override(en, t)
      n = n + 1
    end
    bericht.skripttexte = n
    n = 0
    for label, t in pairs(daten.rom_text or {}) do
      if type(t) == "string" then
        c.rom_text:override(label, t)
        n = n + 1
      end
    end
    bericht.texte = n
    n = 0
    local dex = daten.pokedex and daten.pokedex.entries or {}
    for id, p in pairs(daten.pokemon or {}) do
      if type(p) == "table" and type(p.name) == "string" then
        local eintrag = { name = p.name }
        local e = dex[id]
        if e then
          eintrag.dexEntry = { kind = e.kind, text = e.text, text2 = e.text2, heightM = e.heightM,
            weightKg = e.weightKg }
        end
        c.pokemon:patch(id, eintrag)
        n = n + 1
      end
    end
    bericht.pokemon = n
    for id, mv in pairs(daten.moves or {}) do
      if type(mv) == "table" and type(mv.name) == "string" then
        c.moves:patch(id, { name = mv.name, description = mv.description })
      end
    end
    local vm = type(daten.vm) == "table" and type(daten.vm.praefix) == "string" and daten.vm.praefix ~= ""
      and daten.vm.praefix
    for id, it in pairs(daten.items or {}) do
      if type(it) == "table" and type(it.name) == "string" then
        local name = it.name
        -- VM: der Port bildet den Namen aus seiner eigenen Kennung (tmLabel) → Präfix der DE-ROM davor
        local nr = vm and name == it.tmLabel and tostring(id):match("^HM_") and name:match("(%d+)$")
        if nr then name = vm .. nr end
        c.items:patch(id, { name = name, description = it.description })
      end
    end
  end

  -- Nach dem Zusammenführen (mods.loaded, data = Datensatz von Gold/Silber/Kristall): Tabellen ohne Registry
  local function tabellen(data, daten, bilder, bericht, schluessel)
    local z = { n = 0 }
    -- Startvorgabe der Namensvorschläge (field.boot.namePresets.player, OakSpeech namePresets): wie NamePick
    local boot = data.field and data.field.boot
    local n2 = daten.namen2
    if type(n2) == "table" and type(n2.m) == "table" and boot and type(boot.namePresets) == "table"
        and type(boot.namePresets.player) == "table" then
      local tab = boot.namePresets.player
      for i = #tab, 1, -1 do tab[i] = nil end
      for i = 2, #n2.m do tab[#tab + 1] = n2.m[i] end
      z.n = z.n + 1
    end
    einmischen(data.type_chart, daten.type_chart, nur_texte, "", z)
    einmischen(data.gen2Trainers, daten.trainers, trainer_erlaubt, "", z)
    einmischen(data.gen2Landmarks, daten.landmarks, nur_texte, "", z)
    einmischen(data.gen2EventTables, daten.events, ereignis_erlaubt, "", z)
    einmischen(data.gen2MenuGfx, daten.menu_gfx, alles, "", z)
    einmischen(data.gen2Tilesets, daten.tilesets, alles, "", z)
    einmischen(data.gen2Maps, daten.maps, alles, "", z)
    -- Radiosender (Registry radio_channels → data.gen2RadioChannels[station].name, Pokegear:stationName)
    local rc = data.gen2RadioChannels
    if type(rc) == "table" and type(daten.sender) == "table" then
      for id, name in pairs(daten.sender) do
        if type(rc[id]) == "table" and type(name) == "string" and name ~= "" then rc[id].name = name end
      end
    end
    -- Dekorationen: Grundnamen (Farben, Pflanzen, Konsolen, Trophäen, Kategorien) aus der DE-ROM; Poster/Puppen/
    -- Riesenpuppen (Typ 4–6) führen dort eine Arten-Kennung, die Decorations.name über den Pokémon-Namen auflöst
    local dk = data.gen2Decorations
    if type(dk) == "table" and type(daten.deko) == "table" then
      for _, e in pairs(dk) do
        if type(e) == "table" and type(e.name) == "string" and not (e.type == 4 or e.type == 5 or e.type == 6) then
          local de = daten.deko[G.pruefsumme(e.name)]
          if type(de) == "string" and de ~= "" then e.name = de; z.n = z.n + 1 end
        elseif type(e) == "table" and type(e.name) == "string" then
          -- GetDecorationName → GetPokemonName: kein Aufrufer des Ports reicht monName herein, also hier der
          -- (schon deutsche) Artname aus data.pokemon
          local art = data.pokemon and data.pokemon[e.name]
          if type(art) == "table" and type(art.name) == "string" and art.name ~= "" then
            e.name = art.name; z.n = z.n + 1
          end
        end
      end
    end
    -- Pokédex-Sortierung „ABC“ nach den deutschen Namen (Reihenfolge der DE-ROM)
    local dex = data.gen2Pokedex
    if dex and daten.pokedex and daten.pokedex.alphabeticalOrder then
      dex.alphabeticalOrder = daten.pokedex.alphabeticalOrder
    end
    -- Zeichensatz: deutsche Codes (die Glyphen liefert das Schriftbild der DE-ROM unten)
    if data.font and daten.font and daten.font.charmap then data.font.charmap = daten.font.charmap end
    -- Menüs, stringtotext und Briefe in Skripten (gleiche Befehlsnummer, gleicher Befehl)
    local skripte_en = data.gen2Scripts or {}
    local landmarke_nach_nummer = {}
    for _, l in pairs(data.gen2Landmarks and data.gen2Landmarks.landmarks or {}) do
      if type(l) == "table" and type(l.index) == "number" and type(l.name) == "string" then
        landmarke_nach_nummer[l.index] = l.name
      end
    end
    for en, teile in pairs(daten.skriptanzeige or {}) do
      local befehle = skripte_en[en]
      if befehle then
        for i, t in pairs(teile) do
          local cmd = befehle[tonumber(i)]
          if type(cmd) == "table" and cmd.op == t.op then
            if t.menu and cmd.menu then
              for k, v in pairs(t.menu) do
                if k ~= "key" then cmd.menu[k] = v end
              end
              z.n = z.n + 1
            end
            if t.string and cmd.string then cmd.string = t.string end
            if t.landmarke and cmd.string then
              -- Der Ortsname trägt <BSP> (Port: Zeilenumbruch); im Text druckt ihn die DE-ROM als Leerzeichen
              -- (Bank 0 PlaceNextChar 00:100E: cp $1F / jr nz / ld a,$7F)
              local name = landmarke_nach_nummer[t.landmarke]
              if name then cmd.string = (name:gsub("\n", " ")); z.n = z.n + 1 end
            end
            if t.mail and cmd.mail then cmd.mail.message = t.mail.message end
          end
        end
      end
    end
    bericht.felder = z.n
    bericht.bilder = G.bilder_einhaengen(bilder, schluessel, { data.font, data.gen2MenuGfx, data.gen2Intro,
      data.gen2Credits, data.gen2Diploma, data.gen2Trade, data.gen2Tilesets })
  end

  -- Spielobjekt (game.ready): Eichs Rede und das Titelbild halten eigene Kopien der Daten
  local function spielobjekt(game, daten)
    if type(game.oakSpeechData) == "table" then
      einmischen(game.oakSpeechData, daten.oak_speech, nur_texte, "", { n = 0 })
    end
    if type(game.titleData) == "table" then
      einmischen(game.titleData, daten.title, alles, "", { n = 0 })
    end
  end

  -- ================================================================ 3. Haken: Texte und Platzhalter

  -- Platzhalter-Reihenfolge: Der Port füllt {STRBUF}/{NUM} der Reihe nach mit den Werten in englischer
  -- Reihenfolge (z. B. HeldItemMenu: Meldung beim Tauschen des getragenen Items, drei Puffer).  Wo der deutsche Text
  -- die Puffer anders ordnet (Rezept pf), werden die Werte für dieses Label umgestellt.
  -- zusatz[label]() liefert einen Wert, den der deutsche Text zusätzlich nennt (Verkaufen: die Menge); er steht hinter
  -- den Werten des Ports und wird über die Reihenfolge im Rezept an seine Stelle gesetzt.
  local function puffer_einhaengen(pf, zusatz)
    if type(pf) ~= "table" or not next(pf) then return end
    local CommonText = require("src.core.gen2.CommonText")
    local folge_von = setmetatable({}, { __mode = "k" })
    local label_von = setmetatable({}, { __mode = "k" })
    local fill = CommonText.fill
    CommonText.fill = function(pages, values)
      local folge = pages and folge_von[pages]
      if folge and type(values) == "table" then
        local extra = zusatz and zusatz[label_von[pages]]
        if extra then
          local mit = {}
          for k, v in pairs(values) do mit[k] = v end
          mit[#values + 1] = extra()
          values = mit
        end
        local neu = {}
        for k, i in ipairs(folge) do neu[k] = values[i + 1] end
        for key, v in pairs(values) do
          if type(key) ~= "number" then neu[key] = v end
        end
        values = neu
      end
      return fill(pages, values)
    end
    local of = CommonText.of
    CommonText.of = function(text, label, values)
      if not pf[label] then return of(text, label, values) end
      local pages = CommonText.pages(CommonText.get(text, label))
      if not pages then return nil end
      folge_von[pages] = pf[label]
      label_von[pages] = label
      if values then return CommonText.fill(pages, values) end
      return pages
    end
  end

  -- Verkaufen im Laden (MartMenu:completeSale → sellText.bought(Name, Preis)): der DE-Text _MartBoughtText nennt
  -- auch die Menge („Erhält ¥{NUM} für / {NUM} x {STRBUF}.“), der Port gibt sie nicht mit → während des Verkaufs die
  -- Menge bereithalten, puffer_einhaengen setzt sie über die Rezept-Reihenfolge (pf) an ihre Stelle
  local verkauf_menge
  local function verkauf_einhaengen()
    local okm, MartMenu = G.port_modul("src.ui.gen2.MartMenu")
    if not okm or type(MartMenu) ~= "table" or type(MartMenu.completeSale) ~= "function" then return end
    local alt = MartMenu.completeSale
    MartMenu.completeSale = function(self, ...)
      verkauf_menge = self.qty
      return danach(function() verkauf_menge = nil end, alt, self, ...)
    end
  end

  -- PC-Item-Ablage (ItemPcMenu:askQuantity): die Rückfrage steht als feste Zeilen im Fenster, getrennt nur an „\n“;
  -- der DE-Text „Wie viele / {STRBUF}\vwegwerfen?“ rollt im Original eine Zeile weiter (\v), stehen bleiben die
  -- letzten zwei Zeilen („GEGENGIFT / wegwerfen?“) → dieselben zwei Zeilen zeigen statt einer überlangen
  local function pc_frage_einhaengen()
    local okp, ItemPcMenu = G.port_modul("src.ui.gen2.ItemPcMenu")
    if not okp or type(ItemPcMenu) ~= "table" or type(ItemPcMenu.askQuantity) ~= "function" then return end
    local alt = ItemPcMenu.askQuantity
    ItemPcMenu.askQuantity = function(self, max, prompt, ...)
      if type(prompt) == "table" then
        local text = table.concat(prompt, "\n")
        if text:find("[\v\f]") then
          text = text:gsub("^.*\f", "")
          local zeilen = {}
          for z in (text:gsub("\v", "\n") .. "\n"):gmatch("(.-)\n") do zeilen[#zeilen + 1] = z end
          prompt = { zeilen[#zeilen - 1], zeilen[#zeilen] }
          if #zeilen < 2 then prompt = { zeilen[1] } end
        end
      end
      return alt(self, max, prompt, ...)
    end
  end

  -- STACHLER: der Port meldet die gelegten Stachler ohne Ziel („Spikes were scattered all around!“, src/battle/gen2/
  -- Battle.lua EFFECT_SPIKES – SpikesText hat englisch drei Zeilen mit <TARGET>, das Meldungsfenster des Ports nur
  -- zwei); die DE-ROM schreibt SpikesText zweizeilig „STACHLER umgibt⏎<TARGET>!“ → diese Meldung mit dem Namen der
  -- Seite, auf der die Stachler gerade neu liegen.  Battle:emit ist die einzige Stelle, die das Ereignis sieht.
  local function stachler_einhaengen(vorlage)
    if type(vorlage) ~= "string" or not vorlage:find("{TARGET}", 1, true) then return end
    local okb, Battle = G.port_modul("src.battle.gen2.Battle")
    if not okb or type(Battle) ~= "table" or type(Battle.emit) ~= "function"
        or type(Battle.battlerName) ~= "function" then
      return
    end
    local Strings = require("src.core.Strings")
    vorlage = G.ohne_ende(vorlage)
    local en
    local alt = Battle.emit
    Battle.emit = function(self, ev, ...)
      pcall(function()
        local sp = type(self) == "table" and rawget(self, "spikes")
        if type(sp) ~= "table" then return end
        local vorher = rawget(self, "__dg_stachler") or {}
        if type(ev) == "table" and ev.kind == "message" and type(ev.text) == "string" then
          en = en or Strings("Spikes were scattered all around!")
          if ev.text == en then
            for _, seite in ipairs({ "player", "enemy" }) do
              if sp[seite] and not vorher[seite] then
                local name = self:battlerName(seite == "player" and self.player or self.enemy)
                if type(name) == "string" then
                  ev.text = (vorlage:gsub("{TARGET}", function() return name end))
                end
                break
              end
            end
          end
        end
        rawset(self, "__dg_stachler", { player = sp.player, enemy = sp.enemy })
      end)
      return alt(self, ev, ...)
    end
  end

  -- Pokémon-Namen der Spezialroutinen: mehrere Handler (src/script/gen2/Specials.lua nameMon, z. B. CheckFirstMonIsEgg
  -- am Käferwettbewerb) reichen der Welt-Routine monName die Art als Konstante („TOTODILE“) statt als Index; monName
  -- findet dazu nichts, und nameMon schreibt die englische Konstante in den Textpuffer → Konstante in den Namen der
  -- Pokémon-Tabelle übersetzen (dort steht der Name der DE-ROM)
  local function artname_einhaengen()
    local okw, World = G.port_modul("src.world.gen2.World")
    if not okw or type(World) ~= "table" or type(World.specialHooks) ~= "function" then return end
    local alt = World.specialHooks
    World.specialHooks = function(self, ...)
      local h = alt(self, ...)
      if type(h) == "table" and type(h.monName) == "function" then
        local mn = h.monName
        h.monName = function(art, ...)
          local r = mn(art, ...)
          if (r == nil or r == art) and type(art) == "string" then
            local data = type(self) == "table" and self.game and self.game.data
            local e = data and type(data.pokemon) == "table" and data.pokemon[art]
            if type(e) == "table" and type(e.name) == "string" then return e.name end
          end
          return r
        end
      end
      return h
    end
  end

  -- Skriptmenüs mit Port-Einträgen: Spezialroutinen bauen manche Menüs aus eigenen Quelltexten (Kristall-Duellturm
  -- src/script/gen2/specials/battle_tower.lua CHALLENGE_MENU_ROWS, Strings.source), das Skriptmenü
  -- (World:openScriptMenu → Gen2ScriptMenu) zeichnet die Einträge aber unübersetzt, weil Skriptmenüs sonst schon die
  -- Texte der ROM tragen → Einträge durch den Katalog schicken; Kastenmaße des Duellturm-Menüs aus dem MenuHeader der
  -- DE-ROM (daten.turmmenue, menu_coords y1 x1 y2 x2)
  local function skriptmenue_einhaengen(turm_kasten)
    local okw, World = G.port_modul("src.world.gen2.World")
    if not okw or type(World) ~= "table" or type(World.openScriptMenu) ~= "function" then return end
    local Strings = require("src.core.Strings")
    local alt = World.openScriptMenu
    World.openScriptMenu = function(self, header, ...)
      pcall(function()
        local items = type(header) == "table" and header.items
        if type(items) ~= "table" then return end
        local turm = items[1] == "Challenge"
        local neu = {}
        for i, it in ipairs(items) do
          if type(it) == "string" then
            local ok, t = pcall(Strings, it)
            neu[i] = (ok and type(t) == "string") and t or it
          else
            neu[i] = it
          end
        end
        local h = {}
        for k, v in pairs(header) do h[k] = v end
        h.items = neu
        if turm and type(turm_kasten) == "table" then
          h.top, h.left, h.bottom, h.right = turm_kasten[1], turm_kasten[2], turm_kasten[3], turm_kasten[4]
        end
        header = h
      end)
      return alt(self, header, ...)
    end
  end

  -- Geben/Nehmen (src/ui/gen2/HeldItemMenu.lua): die Texte (_PokemonHoldItemText …) sucht der Port in den Skripttexten
  -- (game.world.text), wo diese Labels nie stehen – er fällt dann auf feste englische Zeilen zurück („Made KARNIMANI
  -- hold …“).  Die deutschen Texte liegen unter demselben Label in data.text (rom_text der DE-ROM) → von dort füllen
  local GEBEN_WERTE = {
    hold = function(mon, item) return { mon, item } end,
    notHolding = function(mon) return { mon } end,
    tookItem = function(item, mon) return { item, mon } end,
    askSwap = function(mon, item) return { mon, item } end,
    swapped = function(mon, old, new) return { mon, old, new } end,
  }
  local function geben_einhaengen()
    local okh, HIM = G.port_modul("src.ui.gen2.HeldItemMenu")
    if not okh or type(HIM) ~= "table" or type(HIM.new) ~= "function" or type(HIM.LABELS) ~= "table" then return end
    local CommonText = require("src.core.gen2.CommonText")
    local alt = HIM.new
    HIM.new = function(game, opts, ...)
      local self = alt(game, opts, ...)
      local dt = type(game) == "table" and type(game.data) == "table" and game.data.text
      if type(self) ~= "table" or type(self.TEXT) ~= "table" or type(dt) ~= "table" then return self end
      for key, label in pairs(HIM.LABELS) do
        if not CommonText.of(self.textData, label) and type(dt[label]) == "string" and dt[label] ~= "" then
          -- data.text ist nach Label geordnet, CommonText.of erwartet die Form der Skripttexte (labels → Schlüssel);
          -- über CommonText.of, damit die Platzhalter-Reihenfolge (Rezept pf) greift
          local liste = CommonText.of({ labels = { [label] = 1 }, dt[label] }, label)
          if liste then
            local werte = GEBEN_WERTE[key]
            if werte then
              self.TEXT[key] = function(...) return CommonText.fill(liste, werte(...)) end
            else
              self.TEXT[key] = liste
            end
          end
        end
      end
      return self
    end
  end

  -- EP-Balken über mehrere Level: Zwischenstufen setzt der Port als Literal „<Name> grew to level N!“ zusammen
  -- (BattleState:expLevelLine); nur die letzte Stufe trägt den Text der Level-Meldung.  Die Zwischenstufen nehmen
  -- dieselbe Vorlage, also den DE-ROM-Text.
  local function ep_level_einhaengen()
    local ok, BS = G.port_modul("src.ui.gen2.BattleState")
    if not ok or type(BS) ~= "table" or type(BS.expLevelLine) ~= "function" then return end
    local original = BS.expLevelLine
    BS.expLevelLine = function(self, anim, level, toLevel, ...)
      -- anim.line ist die deutsche Zeile der Zielstufe (Katalog/DE-ROM); für Zwischenstufen nur die Zahl tauschen
      -- (letztes Vorkommen der Zielstufe), so braucht der Mod keinen englischen Text
      if type(anim) == "table" and type(anim.line) == "string" and level ~= toLevel then
        local z = tostring(toLevel)
        local a, e
        local von = 1
        while true do
          local i, j = anim.line:find(z, von, true)
          if not i then break end
          a, e, von = i, j, j + 1
        end
        if a then return anim.line:sub(1, a - 1) .. tostring(level) .. anim.line:sub(e + 1) end
      end
      -- ohne Zeile: Vorlage der Level-Meldung aus dem Katalog per Prüfsumme (DE-ROM), Platzhalter %s/%d bzw. %n$
      local vorlage = level ~= toLevel and type(self.name) == "function" and G.katalog and G.katalog["~3472cb950014"]
      if type(vorlage) == "string" then
        local werte, n = { self:name(anim.mon), level }, 0
        return (vorlage:gsub("%%(%d*)%$?([sd])", function(i, _)
          n = n + 1
          return tostring(werte[tonumber(i) or n] or "")
        end))
      end
      return original(self, anim, level, toLevel, ...)
    end
  end

  -- Statuskürzel im Kampf-HUD (src/ui/gen2/BattleState.lua statusTag): ist der Status-Eintrag nach dem Laden der
  -- Mods eine Kopie (nicht mehr dieselbe Tabelle wie Battle.STATUSES), gibt der Port das Label roh zurück, ohne
  -- Strings() → hier nachholen (Katalog: DE-ROM SLF/BRT/PAR/GIF/GFR); Team und Status rufen Strings() selbst auf
  local function statuskuerzel_einhaengen()
    local okb, BS = G.port_modul("src.ui.gen2.BattleState")
    if not okb or type(BS) ~= "table" or type(BS.statusTag) ~= "function" then return end
    local S = require("src.core.Strings")
    local alt = BS.statusTag
    BS.statusTag = function(...)
      local r = alt(...)
      if type(r) == "string" then return S(r) end
      return r
    end
  end

  -- Taschennamen in „… in die <TASCHE> gesteckt“ (src/script/gen2/Vm.lua POCKET_NAMES über Vm:pocketName): die
  -- Namen setzt der Port per Strings-Platzhalter ein, am Kodierpunkt ist das Wort nicht mehr allein → hier tauschen
  -- (ItemPocketNames der DE-ROM, Rezept pl)
  local function taschennamen_einhaengen()
    local okv, Vm = G.port_modul("src.script.gen2.Vm")
    if not okv or type(Vm) ~= "table" or type(Vm.pocketName) ~= "function" then return end
    local alt = Vm.pocketName
    Vm.pocketName = function(...)
      local en = alt(...)
      return type(en) == "string" and G.literale_global[G.pruefsumme(en)] or en
    end
  end

  -- Telefon (PokéCom-Liste, Anruffenster): die Namen der Nicht-Trainer führt der Port fest englisch
  -- (src/core/gen2/Phone.lua NON_TRAINER_NAMES und CONTACTS[n].name) → DE-ROM; Fang-Tutorial: Spielername im Kampf
  -- (src/core/gen2/CatchTutorial.lua DUDE_NAME) → DE-ROM
  local function npcnamen_einhaengen(nn, r)
    if type(nn) ~= "table" then return end
    local tel = nn.telefon
    local okp, Phone = G.port_modul("src.core.gen2.Phone")
    if okp and type(Phone) == "table" and type(tel) == "table" then
      local function de(en) return type(en) == "string" and tel[G.pruefsumme(en)] or nil end
      for i, en in pairs(type(Phone.NON_TRAINER_NAMES) == "table" and Phone.NON_TRAINER_NAMES or {}) do
        local d = de(en)
        if d then Phone.NON_TRAINER_NAMES[i] = d end
      end
      -- Kontaktzeilen: Phone.useRegistry legt die (englisch vorbelegten) phone_contacts-Zeilen beim Laden
      -- wieder darüber → nach jedem useRegistry erneut setzen
      local function zeilen()
        for _, c in pairs(type(Phone.CONTACTS) == "table" and Phone.CONTACTS or {}) do
          local d = type(c) == "table" and de(c.name)
          if d then c.name = d end
        end
      end
      zeilen()
      if type(Phone.useRegistry) == "function" and not Phone.__dg_namen then
        local alt_use = Phone.useRegistry
        Phone.__dg_namen = true
        Phone.useRegistry = function(data, ...)
          -- die Registry-Zeilen selbst (useExtracted legt sie über eine interne Funktion erneut darüber)
          pcall(function()
            for _, reg in pairs(type(data) == "table" and type(data.gen2PhoneContacts) == "table"
                and data.gen2PhoneContacts or {}) do
              local d = type(reg) == "table" and de(reg.name)
              if d then reg.name = d end
            end
          end)
          local erg = alt_use(data, ...)
          pcall(zeilen)
          return erg
        end
      end
    end
    -- Kristall: die Namen der ROM tragen den Doppelpunkt selbst („MAMA:“), der leere Platz „----------“ keinen;
    -- der Port hängt jedem Eintrag „:“ an (Pokegear:contactRow) → beim leeren Platz wieder weglassen
    local t = r and r.telefon
    local okg, Pokegear = G.port_modul("src.ui.gen2.Pokegear")
    if type(t) == "table" and t[4] and okg and type(Pokegear) == "table" and okp
        and type(Pokegear.contactRow) == "function" and type(Phone.contactName) == "function" then
      local alt_row = Pokegear.contactRow
      Pokegear.contactRow = function(self, id, ...)
        local zeile, klasse = alt_row(self, id, ...)
        local leer = type(Phone.NON_TRAINER_NAMES) == "table" and Phone.NON_TRAINER_NAMES[0]
        if type(zeile) == "string" and leer and Phone.contactName(id, self.trainers) == leer then
          zeile = zeile:gsub(":$", "")
        end
        return zeile, klasse
      end
    end
    local ku = nn.kumpel
    local okc, Tut = G.port_modul("src.core.gen2.CatchTutorial")
    if okc and type(Tut) == "table" and type(ku) == "table" then
      local d = ku[G.pruefsumme(tostring(Tut.DUDE_NAME))]
      if d then Tut.DUDE_NAME = d end
    end
  end

  -- ================================================================ 4. Haken: Fenster und Menüs wie in der DE-ROM

  -- JA/NEIN-Fenster (home/menu.asm _YesNoBox): die DE-Fassung macht es eine Kachel breiter und rückt das Standard-
  -- fenster (x 14) eine Spalte nach links, sonst ragt „NEIN“ hinaus.  Der Port hat die EN-Maße fest – im Theme
  -- (ChoiceBox der Skripte) und in den Menüs (Chrome-Kasten 6×5, JA/NEIN bei x+2, Cursor bei x+1).  Kasten umsetzen,
  -- Wörter und Cursor in seinen beiden Zeilen mitnehmen (Rezept ja_nein).
  -- Dazu Aufrufe mit eigener, in DE tieferer Lage: Sichern (SaveMenu/StartMenu, Kasten 0,7 – nur dort) und der
  -- Käferwettbewerb (ContestMenu:drawYesNo, Kasten 14,7 wie viele andere → nur während dieser Zeichenfunktion).
  local function ja_nein_einhaengen(jn)
    if type(jn) ~= "table" or not jn.de_w then return end
    local function lage(x) return x == jn.en_x and jn.de_x or x end
    local _, Theme = G.port_modul("src.ui.Theme")
    local cb = type(Theme) == "table" and Theme.choiceBox
    if type(cb) == "table" and cb.tw == jn.en_w then cb.tx, cb.tw = lage(cb.tx), jn.de_w end
    local _, Chrome = G.port_modul("src.ui.gen2.Chrome")
    local fenster   -- zuletzt gezeichnetes JA/NEIN-Fenster { x EN, x DE, y EN, y DE }
    local innen = false   -- print → printThrough, cursor → cursorThrough: nur einmal umsetzen
    local im_wettbewerb = false
    local pb = Chrome.paletteBox
    Chrome.paletteBox = function(tx, ty, tw, th, ...)
      if tw == jn.en_w and th == 5 then
        local l = jn.sichern
        if not (l and tx == l[1] and ty == l[2]) then l = im_wettbewerb and jn.wettbewerb or nil end
        if l and not (tx == l[1] and ty == l[2]) then l = nil end
        fenster = { tx, lage(l and l[3] or tx), ty, l and l[4] or ty }
        return pb(fenster[2], fenster[4], jn.de_w, th, ...)
      end
      fenster = nil
      return pb(tx, ty, tw, th, ...)
    end
    local function versetzt(tx, ty, abstand)
      if fenster and tx == fenster[1] + abstand and (ty == fenster[3] + 1 or ty == fenster[3] + 3) then
        return fenster[2] + abstand, ty + fenster[4] - fenster[3]
      end
      return tx, ty
    end
    if jn.wettbewerb then
      local okC, ContestMenu = G.port_modul("src.ui.gen2.ContestMenu")
      if okC and type(ContestMenu.drawYesNo) == "function" then
        local alt = ContestMenu.drawYesNo
        ContestMenu.drawYesNo = function(...)
          im_wettbewerb = true
          return danach(function() im_wettbewerb = false end, alt, ...)
        end
      end
    end
    local function einmal(f, ...)
      innen = true
      return danach(function() innen = false end, f, ...)
    end
    for _, name in ipairs({ "print", "printThrough" }) do
      local f = Chrome[name]
      Chrome[name] = function(text, tx, ty, ...)
        if innen then return f(text, tx, ty, ...) end
        local x, y = versetzt(tx, ty, 2)
        return einmal(f, text, x, y, ...)
      end
    end
    for _, name in ipairs({ "cursor", "cursorThrough" }) do
      local f = Chrome[name]
      Chrome[name] = function(tx, ty, ...)
        if innen then return f(tx, ty, ...) end
        local x, y = versetzt(tx, ty, 1)
        return einmal(f, x, y, ...)
      end
    end
  end

  -- Spielstand-Fenster (Hauptmenü WEITER, Sichern): die DE-Fassung setzt es weiter links und breiter (Platz für
  -- „SPIELZEIT“), die Zahlen bleiben an ihrer Stelle.  Während der Zeichenfunktion werden Rahmen und Beschriftungs-
  -- spalte umgesetzt (Rezept spielstand: Versatz/rechter Rand EN und DE aus _OffsetMenuHeader und dem MenuHeader).
  local function spielstand_einhaengen(ss)
    if type(ss) ~= "table" or not ss.de_x or ss.de_x == ss.en_x then return end
    local _, Chrome = G.port_modul("src.ui.gen2.Chrome")
    local links = ss.en_x - ss.de_x
    -- rechter Rand absolut: EN en_x + en_r, DE de_x + de_r → Breite wächst um die Differenz plus den Versatz
    local breiter = (ss.de_x + ss.de_r) - (ss.en_x + ss.en_r) + links
    local function umsetzen(f)
      return function(...)
        local box, print_ = Chrome.box, Chrome.print
        Chrome.box = function(x, y, w, h, ...)
          if x == ss.en_x then return box(x - links, y, w + breiter, h, ...) end
          return box(x, y, w, h, ...)
        end
        Chrome.print = function(text, x, y, ...)
          if x == ss.en_x + 1 then x = ss.de_x + 1 end
          return print_(text, x, y, ...)
        end
        return danach(function() Chrome.box, Chrome.print = box, print_ end, f, ...)
      end
    end
    local okS, SaveMenu = G.port_modul("src.ui.gen2.SaveMenu")
    if okS and type(SaveMenu.drawPanel) == "function" then SaveMenu.drawPanel = umsetzen(SaveMenu.drawPanel) end
    local okM, MainMenu = G.port_modul("src.ui.gen2.MainMenu")
    if okM and type(MainMenu.drawSavePanel) == "function" then
      MainMenu.drawSavePanel = umsetzen(MainMenu.drawSavePanel)
    end
  end

  -- Uhr-Kasten im Hauptmenü (WEITER): der Port zeichnet ihn für alle Editionen in der Kristall-Lage (Kasten 0,14
  -- 18×2, Tag 1,15, Zeit 4,16); Gold/Silber DE setzen ihn höher und schmaler (daten.uhr aus dem DE-Code)
  local function uhr_einhaengen(u)
    if type(u) ~= "table" or not u.w then return end
    local okm, MainMenu = G.port_modul("src.ui.gen2.MainMenu")
    if not okm or type(MainMenu) ~= "table" or type(MainMenu.drawClockBox) ~= "function" then return end
    local _, Chrome = G.port_modul("src.ui.gen2.Chrome")
    local alt = MainMenu.drawClockBox
    MainMenu.drawClockBox = function(...)
      local tb, pr = Chrome.textbox, Chrome.print
      local n = 0
      Chrome.textbox = function(_x, _y, _w, _h, ...) return tb(u.x, u.y, u.w, u.h, ...) end
      Chrome.print = function(text, x, y, ...)
        n = n + 1
        local ziel = n == 1 and u.tag or u.zeit
        return pr(text, ziel[1], ziel[2], ...)
      end
      return danach(function() Chrome.textbox, Chrome.print = tb, pr end, alt, ...)
    end
  end

  -- Geschlechtswahl (Kristall, GenderSelect): der Port hat den EN-Kasten fest (menu_coords 6,4,12,9 → Kasten 6,4
  -- 7×6, Text ab Spalte 8, Cursor 7); der DE-Kasten ist breiter („MÄDCHEN“) → Kasten, Text und Cursor umsetzen
  local function geschlecht_einhaengen(m)
    if type(m) ~= "table" or not m.x1 then return end
    local okg, GS = G.port_modul("src.ui.gen2.GenderSelect")
    if not okg or type(GS) ~= "table" or type(GS.drawBody) ~= "function" then return end
    local _, Chrome = G.port_modul("src.ui.gen2.Chrome")
    local dx = m.x1 - 6
    local alt = GS.drawBody
    GS.drawBody = function(...)
      local pb, pt, ct = Chrome.paletteBox, Chrome.printThrough, Chrome.cursorThrough
      Chrome.paletteBox = function(x, y, w, h, ...)
        if x == 6 and y == 4 and w == 7 and h == 6 then
          return pb(m.x1, m.y1, m.x2 - m.x1 + 1, m.y2 - m.y1 + 1, ...)
        end
        return pb(x, y, w, h, ...)
      end
      Chrome.printThrough = function(text, x, y, ...)
        if x == 8 and (y == 6 or y == 8) then x = x + dx end
        return pt(text, x, y, ...)
      end
      Chrome.cursorThrough = function(x, y, ...)
        if x == 7 and (y == 6 or y == 8) then x = x + dx end
        return ct(x, y, ...)
      end
      return danach(function() Chrome.paletteBox, Chrome.printThrough, Chrome.cursorThrough = pb, pt, ct end,
        alt, ...)
    end
  end

  -- Namensvorschläge (NamePick): der Port führt die englischen Listen (NamePick.PRESETS/PRESETS_FEMALE) und
  -- „NEW NAME“; die DE-ROM hat eigene Namen und als ersten Punkt „NAME“.  Listen an Ort und Stelle ersetzen
  -- (presetsFor liest dieselben Tabellen); die Startvorgabe field.boot.namePresets.player setzt tabellen().
  local function namen_einhaengen(n2, edition)
    if type(n2) ~= "table" or type(n2.m) ~= "table" then return end
    local ok, NP = G.port_modul("src.ui.gen2.NamePick")
    if not ok or type(NP) ~= "table" or type(NP.new) ~= "function" then return end
    local function setze(tab, l)
      if type(tab) ~= "table" or type(l) ~= "table" then return end
      for i = #tab, 1, -1 do tab[i] = nil end
      for i = 2, #l do tab[#tab + 1] = l[i] end
    end
    if type(NP.PRESETS) == "table" then setze(NP.PRESETS[edition], n2.m) end
    if type(NP.PRESETS_FEMALE) == "table" and n2.w then setze(NP.PRESETS_FEMALE[edition], n2.w) end
    local alt = NP.new
    NP.new = function(game, opts, ...)
      local self = alt(game, opts, ...)
      if type(self) == "table" and type(self.items) == "table" then
        local l = (self.gender == "female" and n2.w) or n2.m
        self.items[1] = l[1]
      end
      return self
    end
    -- Titel im oberen Rahmen: der Port setzt „NAME“ fest auf Spalte 2 (NamePick TITLE_X) und räumt nur darunter den
    -- Rahmen weg; die ROM setzt ihren Titel samt Leerzeichen ab der Einrückung (DE-Gold „ NAME “ ab Spalte 1)
    local ti = n2.titel
    if type(ti) == "table" and type(ti.text) == "string" and type(NP.drawPanel) == "function" then
      local _, Chrome = G.port_modul("src.ui.gen2.Chrome")
      local Font = require("src.render.Font")
      local alt_draw = NP.drawPanel
      NP.drawPanel = function(self, ...)
        local Gr = love.graphics
        local pr, re = Chrome.print, Gr.rectangle
        local gesehen = false
        Chrome.print = function(text, x, y, ...)
          if y == 0 and x == 2 and not gesehen then
            gesehen = true
            local breite = #Font.split(ti.text)
            Gr.setColor(1, 1, 1, 1)
            re("fill", ti.x * 8, 0, breite * 8, 8)
            return pr(ti.text, ti.x, 0, ...)
          end
          return pr(text, x, y, ...)
        end
        Gr.rectangle = function(mode, x, y, w, h, ...)
          if mode == "fill" and x == 16 and y == 0 and h == 8 and not gesehen then return end
          return re(mode, x, y, w, h, ...)
        end
        local erg = { pcall(alt_draw, self, ...) }
        Chrome.print, Gr.rectangle = pr, re
        if not erg[1] then error(erg[2], 0) end
        -- Unter dem Menü bleibt in der ROM das Textfenster mit Eichs Frage stehen (NamePlayer ruft das Menü über
        -- _OakText6 auf, ohne das Fenster zu löschen); der Port-Bildschirm ist deckend und zeigt es nicht
        local dt = self.game and self.game.data and self.game.data.text
        local frage = type(dt) == "table" and dt._OakText6
        if type(frage) == "string" then
          local CommonText = require("src.core.gen2.CommonText")
          local seiten = CommonText.pages(frage)
          local zeilen = seiten and seiten[#seiten]
          if type(zeilen) == "table" then
            Chrome.box(0, 12, 20, 6)
            for i = 1, math.min(#zeilen, 2) do Chrome.print(zeilen[i], 1, 12 + i * 2) end
          end
        end
        return unpack(erg, 2)
      end
    end
  end

  -- Startmenü, Käferwettbewerb-Fenster: die DE-ROM setzt die Werte auf die festen Spalten des Originals
  -- (StartMenu_DrawBugContestStatusBox: 8, LEVEL 7, BÄLLE 8 – „BESITZ:KEINE“ ohne Lücke), der Port rückt sie hinter
  -- längere Beschriftungen (StartMenu valueColumn) → feste Spalten wie im Original
  local WETTBEWERB_SPALTE = { [1] = 8, [3] = 7, [5] = 8 }
  local function wettbewerb_einhaengen()
    local oks, StartMenu = G.port_modul("src.ui.gen2.StartMenu")
    if not oks or type(StartMenu) ~= "table" or type(StartMenu.drawContestStatus) ~= "function" then return end
    local _, Chrome = G.port_modul("src.ui.gen2.Chrome")
    local alt = StartMenu.drawContestStatus
    StartMenu.drawContestStatus = function(...)
      local pr = Chrome.print
      Chrome.print = function(text, x, y, ...)
        if x ~= 1 and WETTBEWERB_SPALTE[y] then x = WETTBEWERB_SPALTE[y] end
        return pr(text, x, y, ...)
      end
      return danach(function() Chrome.print = pr end, alt, ...)
    end
  end

  -- Beutel-Untermenü: DE-Gold/-Silber setzen es rechts (x 13) wie Kristall, EN-Gold/-Silber links; der Port wählt
  -- die Spalte nach Edition (PackMenu:submenuColumn) → Spalte der DE-ROM (Rezept beutel_spalte)
  local function beutel_einhaengen(spalte)
    if type(spalte) ~= "number" then return end
    local _, PackMenu = G.port_modul("src.ui.gen2.PackMenu")
    PackMenu.submenuColumn = function() return spalte end
  end

  -- TM-Tasche: VM-Zeilen tragen in der DE-ROM den Buchstaben „V“ vor der Nummer (daten.vm.tasche), der Port setzt
  -- „H“ (PackMenu tmhmLabelFor) → nach jedem Aufbau der Zeilen den ersten Buchstaben tauschen
  local function tasche_einhaengen(vm)
    if type(vm) ~= "table" or type(vm.tasche) ~= "string" or vm.tasche == "" then return end
    local okp, PackMenu = G.port_modul("src.ui.gen2.PackMenu")
    if not okp or type(PackMenu) ~= "table" or type(PackMenu.rebuild) ~= "function" then return end
    local alt = PackMenu.rebuild
    PackMenu.rebuild = function(self, ...)
      local erg = { alt(self, ...) }
      for _, row in ipairs(type(self.rows) == "table" and self.rows or {}) do
        if type(row) == "table" and type(row.tmhmLabel) == "string" and tostring(row.id):match("^HM_")
            and row.tmhmLabel:match("^%a%d") then
          row.tmhmLabel = vm.tasche .. row.tmhmLabel:sub(2)
        end
      end
      return unpack(erg)
    end
  end

  -- Team-Bildschirm mit Item-Meldung („TAUBSI erreicht Level 15!“, PartyMenu itemResult): die DE-ROM zeichnet das Team
  -- danach ohne Menü-Cursor neu, der Port lässt ▶ auf dem gewählten POKéMON stehen; mit offenem Untermenü s. u.
  local function team_cursor_einhaengen()
    local okp, PartyMenu = G.port_modul("src.ui.gen2.PartyMenu")
    if not okp or type(PartyMenu) ~= "table" or type(PartyMenu.drawPanel) ~= "function" then return end
    local _, Chrome = G.port_modul("src.ui.gen2.Chrome")
    local alt = PartyMenu.drawPanel
    PartyMenu.drawPanel = function(self, ...)
      local r = self.itemResult
      local meldung = type(r) == "table" and r.text and not self.submenu
      -- liegt ein anderer Bildschirm darüber (Geben/Nehmen, HeldItemMenu), steht der Team-Cursor in der ROM hohl da
      local stack = type(self.game) == "table" and self.game.stack
      local verdeckt = not meldung and type(stack) == "table" and type(stack.top) == "function" and stack:top() ~= self
      if not meldung and not self.submenu and not verdeckt then return alt(self, ...) end
      local cu, pr = Chrome.cursor, Chrome.print
      if meldung then
        Chrome.cursor = function(tx, ...) if tx == 0 then return end return cu(tx, ...) end
      else
        -- Untermenü (STATUS/TAUSCH/…): PokemonActionSubmenu löscht die Zeile der Aufforderung, und der Cursor des
        -- gewählten POKéMON wird zum hohlen ▷
        Chrome.cursor = function(tx, ty, hollow, ...)
          if tx == 0 then return cu(tx, ty, true, ...) end
          return cu(tx, ty, hollow, ...)
        end
        if self.submenu then
          Chrome.print = function(text, tx, ty, ...)
            if tx == 1 and ty == 16 then return end
            return pr(text, tx, ty, ...)
          end
        end
      end
      return danach(function() Chrome.cursor, Chrome.print = cu, pr end, alt, self, ...)
    end
  end

  -- Team-Untermenü (PartyMenu:drawSubmenu): der Port hat den EN-Kasten ab Spalte 6 (MonSubmenu menu_coords 6, 0, 19,
  -- 17); die DE-ROM beginnt eine Spalte weiter links (daten.teammenue) → Kasten, Cursor und Beschriftungen umsetzen
  local function teammenue_einhaengen(links)
    if type(links) ~= "number" or links == 6 then return end
    local okp, PartyMenu = G.port_modul("src.ui.gen2.PartyMenu")
    if not okp or type(PartyMenu) ~= "table" or type(PartyMenu.drawSubmenu) ~= "function" then return end
    local _, Chrome = G.port_modul("src.ui.gen2.Chrome")
    local dx = links - 6
    local alt = PartyMenu.drawSubmenu
    PartyMenu.drawSubmenu = function(self, ...)
      if type(self.submenu) ~= "table" or self.submenu.battle then return alt(self, ...) end
      local bx, pr, cu = Chrome.box, Chrome.print, Chrome.cursor
      Chrome.box = function(x, y, w, h, ...)
        if x == 6 and w == 14 then return bx(links, y, w - dx, h, ...) end
        return bx(x, y, w, h, ...)
      end
      Chrome.print = function(text, x, y, ...)
        if x == 8 then x = 8 + dx end
        return pr(text, x, y, ...)
      end
      Chrome.cursor = function(x, y, ...)
        if x == 7 then x = 7 + dx end
        return cu(x, y, ...)
      end
      return danach(function() Chrome.box, Chrome.print, Chrome.cursor = bx, pr, cu end, alt, self, ...)
    end
  end

  -- Box-Untermenüs (Ablegen/Mitnehmen/Bewegen): der DE-Menükopf beginnt weiter links (MITNEHMEN, FREILASSEN),
  -- rechter Rand bleibt.  Während BoxMenu:drawPanel nach dem Untermenü-Rahmen: Rahmen, Cursor und Zeilen umsetzen.
  local function boxmenue_einhaengen(bm)
    if type(bm) ~= "table" or not bm.de_x or bm.de_x == bm.en_x then return end
    local okB, BoxMenu = G.port_modul("src.ui.gen2.BoxMenu")
    if not okB or type(BoxMenu.drawPanel) ~= "function" then return end
    local _, Chrome = G.port_modul("src.ui.gen2.Chrome")
    local links = bm.en_x - bm.de_x
    local alt = BoxMenu.drawPanel
    BoxMenu.drawPanel = function(...)
      local box, cur, pr = Chrome.box, Chrome.cursor, Chrome.print
      local im_menue = false
      Chrome.box = function(x, y, w, h, ...)
        if x == bm.en_x and y == 4 and h == 10 then
          im_menue = true
          return box(x - links, y, w + links, h, ...)
        end
        return box(x, y, w, h, ...)
      end
      Chrome.cursor = function(x, y, ...)
        if im_menue and x == bm.en_x + 1 then x = x - links end
        return cur(x, y, ...)
      end
      Chrome.print = function(t, x, y, ...)
        if im_menue and x == bm.en_x + 2 then x = x - links end
        return pr(t, x, y, ...)
      end
      return danach(function() Chrome.box, Chrome.cursor, Chrome.print = box, cur, pr end, alt, ...)
    end
  end

  -- PC-Menüs (CenterPcMenu „Zugriff auf wessen PC?“, ItemPcMenu „PC von …“): der Port zeichnet den Kasten 16 breit und
  -- mindestens 12 hoch (menu_coords 0, 0, 15, 12); die DE-ROM ist eine Spalte breiter (x2 = 16) und der Kasten so hoch,
  -- wie die Einträge brauchen (Einträge × 2 + 2, wie im Original zu sehen)
  local function pcmenue_einhaengen(pm)
    if type(pm) ~= "table" then return end
    local _, Chrome = G.port_modul("src.ui.gen2.Chrome")
    local MODULE = { ["src.ui.gen2.CenterPcMenu"] = pm.zentrum, ["src.ui.gen2.ItemPcMenu"] = pm.spieler }
    for modul, breite in pairs(MODULE) do
      local okm, M = G.port_modul(modul)
      if okm and type(M) == "table" and type(M.drawPanel) == "function" and type(breite) == "number" then
        local alt = M.drawPanel
        M.drawPanel = function(self, ...)
          local bx = Chrome.box
          local n = type(self.entries) == "table" and #self.entries or 0
          Chrome.box = function(x, y, w, h, ...)
            if x == 0 and y == 0 and w == 16 and n > 0 and h == math.max(12, n * 2 + 2) then
              return bx(0, 0, breite, n * 2 + 2, ...)
            end
            return bx(x, y, w, h, ...)
          end
          return danach(function() Chrome.box = bx end, alt, self, ...)
        end
      end
    end
  end

  -- Laden, Kaufen: solange eine Ware gewählt ist (Menge, Preisfrage, Meldungen), zeigt die DE-ROM in der Liste den
  -- hohlen Cursor ▷ (ScrollingMenu: PlaceHollowCursor), der Port den vollen ▶ (MartMenu:drawBuyList)
  local function laden_cursor_einhaengen()
    local okm, MartMenu = G.port_modul("src.ui.gen2.MartMenu")
    if not okm or type(MartMenu) ~= "table" or type(MartMenu.drawBuyList) ~= "function" then return end
    local _, Chrome = G.port_modul("src.ui.gen2.Chrome")
    local alt = MartMenu.drawBuyList
    MartMenu.drawBuyList = function(self, ...)
      if not (self.phase == "buyQuantity" or self.message or self.confirm) then return alt(self, ...) end
      local cu = Chrome.cursor
      Chrome.cursor = function(tx, ty) return cu(tx, ty, true) end
      return danach(function() Chrome.cursor = cu end, alt, self, ...)
    end
  end

  -- Karten-Flip (CardFlip:drawPanel): Münzfenster in der EN-Lage (Kasten 9,15 9×1, „COIN“ 10,16, Zahl 15,16);
  -- die DE-ROM setzt es breiter und weiter links (daten.muenzen) → Kasten und Beschriftung umsetzen
  local function muenzen_einhaengen(mz)
    if type(mz) ~= "table" or not mz.w then return end
    local okc, CardFlip = G.port_modul("src.ui.gen2.CardFlip")
    if not okc or type(CardFlip) ~= "table" or type(CardFlip.drawPanel) ~= "function" then return end
    local _, Chrome = G.port_modul("src.ui.gen2.Chrome")
    local alt = CardFlip.drawPanel
    CardFlip.drawPanel = function(...)
      local tb, pr = Chrome.textbox, Chrome.print
      Chrome.textbox = function(x, y, w, h, ...)
        if x == 9 and y == 15 and w == 9 and h == 1 then return tb(mz.x, mz.y, mz.w, mz.h, ...) end
        return tb(x, y, w, h, ...)
      end
      Chrome.print = function(text, x, y, ...)
        if y == 16 and x == 10 then x, y = mz.lx, mz.ly
        elseif y == 16 and x == 15 then x, y = mz.zx, mz.zy end
        return pr(text, x, y, ...)
      end
      return danach(function() Chrome.textbox, Chrome.print = tb, pr end, alt, ...)
    end
  end

  -- Käferwettbewerb, Tausch-Bildschirm (ContestMenu:drawMonBox): der Port setzt Beschriftung und KP-Zahl in die
  -- EN-Spalten 5 und 11 (Zeile Kasten + 4); die DE-ROM eine Spalte weiter links (daten.kaefertausch)
  local function kaefertausch_einhaengen(kt)
    if type(kt) ~= "table" or not kt.gesu or not kt.kp then return end
    local okc, CM = G.port_modul("src.ui.gen2.ContestMenu")
    if not okc or type(CM) ~= "table" or type(CM.drawMonBox) ~= "function" then return end
    local _, Chrome = G.port_modul("src.ui.gen2.Chrome")
    local alt = CM.drawMonBox
    CM.drawMonBox = function(self, boxY, ...)
      local pr = Chrome.print
      Chrome.print = function(text, x, y, ...)
        if y == (boxY or 0) + 4 then
          if x == 5 then x = kt.gesu elseif x == 11 then x = kt.kp end
        end
        return pr(text, x, y, ...)
      end
      return danach(function() Chrome.print = pr end, alt, self, boxY, ...)
    end
  end

  -- Diplom (Diploma:drawPanel): der Port setzt den Namen fest auf 9,5 (EN „PLAYER“ endet in Spalte 7) und die
  -- Bestätigung zeilenweise ab 2,8 (eine Zeile je <NEXT>); die DE-ROM schreibt den Namen eine Spalte hinter
  -- „TRAINER“ und die Zeilen im Abstand zwei (daten.diplom)
  local function diplom_einhaengen(dp)
    if type(dp) ~= "table" or type(dp.wort) ~= "table" or type(dp.text) ~= "table" then return end
    local okd, Diploma = G.port_modul("src.ui.gen2.Diploma")
    if not okd or type(Diploma) ~= "table" or type(Diploma.drawPanel) ~= "function" then return end
    local _, Chrome = G.port_modul("src.ui.gen2.Chrome")
    local Font = require("src.render.Font")
    local alt = Diploma.drawPanel
    Diploma.drawPanel = function(...)
      local pt = Chrome.printThrough
      local ende
      Chrome.printThrough = function(text, x, y, ...)
        if x == 2 and y == 5 then
          x, y = dp.wort[1], dp.wort[2]
          local ok, codes = pcall(Font.encode, text)
          ende = x + (ok and type(codes) == "table" and #codes or #tostring(text))
        elseif x == 9 and y == 5 then
          if dp.name == "hinter_wort" then
            if ende then x, y = ende + 1, dp.wort[2] end
          elseif type(dp.name) == "table" then
            x, y = dp.name[1], dp.name[2]
          end
        elseif x == 2 and y >= 8 and y <= 12 then
          x, y = dp.text[1], dp.text[2] + (y - 8) * 2
        end
        return pt(text, x, y, ...)
      end
      return danach(function() Chrome.printThrough = pt end, alt, ...)
    end
  end

  -- Spielautomat, Einsatz (SlotMachine:drawPanel, phase "bet"): der Port setzt das Textfenster schmal (0,12 12×4) und
  -- das Einsatzmenü fest auf 14,10 – 19,17 mit „ 3“; die ROM zeigt das volle Textfenster und darüber das Menü mit den
  -- Koordinaten und Einträgen der DE-ROM (daten.einsatz)
  local function einsatz_einhaengen(e)
    if type(e) ~= "table" or not e.x1 or type(e.labels) ~= "table" then return end
    local oks, SM = G.port_modul("src.ui.gen2.SlotMachine")
    if not oks or type(SM) ~= "table" or type(SM.drawPanel) ~= "function" then return end
    local _, Chrome = G.port_modul("src.ui.gen2.Chrome")
    local dy = e.y1 - 10
    local alt = SM.drawPanel
    SM.drawPanel = function(self, ...)
      if self.phase ~= "bet" then return alt(self, ...) end
      local tb, cu, pr = Chrome.textbox, Chrome.cursor, Chrome.print
      Chrome.textbox = function(x, y, w, h, ...)
        if x == 0 and y == 12 and w == 12 and h == 4 then return tb(0, 12, 18, 4, ...) end
        if x == 14 and y == 10 and w == 4 and h == 6 then
          return tb(e.x1, e.y1, e.x2 - e.x1 - 1, e.y2 - e.y1 - 1, ...)
        end
        return tb(x, y, w, h, ...)
      end
      Chrome.cursor = function(x, y, ...)
        if x == 15 and (y == 12 or y == 14 or y == 16) then return cu(e.x1 + 1, y + dy, ...) end
        return cu(x, y, ...)
      end
      Chrome.print = function(text, x, y, ...)
        if x == 16 and (y == 12 or y == 14 or y == 16) and type(text) == "string" and text:match("^%s*%d$") then
          return pr(e.labels[(y - 10) / 2] or text, e.x1 + 2, y + dy, ...)
        end
        return pr(text, x, y, ...)
      end
      return danach(function() Chrome.textbox, Chrome.cursor, Chrome.print = tb, cu, pr end, alt, self, ...)
    end
  end

  -- Trainerpass: die DE-ROM setzt den Spielernamen auf Spalte 2 (ihr „NAME/“ ist leer), der Port fest auf
  -- Spalte 7 (src/ui/gen2/TrainerCard.lua drawTopHalf) → in der Zeile 2 die Spalte umsetzen (Rezept trainerpass)
  local function trainerpass_einhaengen(tp)
    if type(tp) ~= "table" then return end
    local okt, TC = G.port_modul("src.ui.gen2.TrainerCard")
    if not okt or type(TC) ~= "table" or type(TC.print) ~= "function" then return end
    local alt, en_x, de_x = TC.print, tp.en_x, tp.de_x
    TC.print = function(self, text, tx, ty, ...)
      if ty == 2 and tx == en_x then tx = de_x end
      return alt(self, text, tx, ty, ...)
    end
  end

  -- ================================================================ 5. Haken: Kampf

  -- Kampfmenü nach dem DE-Layout: der Port setzt den Kasten fest an Spalte 8 (Wettbewerb 2) mit Abstand 6 (12);
  -- die DE-ROM an Spalte 4 mit Abstand 7 (Wettbewerb 3 / 8), sonst überlappen „BEUTEL“ und „FLUCHT“.  Während
  -- drawBottom im Menü werden Kasten, Cursor und Beschriftungen auf die DE-Spalten umgesetzt (daten.kampfmenue).
  local function kampfmenue_einhaengen(km)
    if type(km) ~= "table" or not km.normal then return end
    local ok, BS = G.port_modul("src.ui.gen2.BattleState")
    if not ok or type(BS) ~= "table" or type(BS.drawBottom) ~= "function" then return end
    local _, Chrome = G.port_modul("src.ui.gen2.Chrome")
    local original = BS.drawBottom
    BS.drawBottom = function(self, ox, ...)
      if self.phase ~= "menu" then return original(self, ox, ...) end
      local de = self.contest and km.wettbewerb or km.normal
      if not de then return original(self, ox, ...) end
      local o = ox or 0
      local en_x = (self.contest and 2 or 8) + o
      local en_ab = self.contest and 12 or 6
      local de_x = de.x + o
      local function spalte(tx)
        local rel = tx - en_x - 2
        if rel >= 0 and rel % en_ab == 0 and rel / en_ab <= 1 then
          return de_x + 2 + (rel / en_ab) * de.abstand
        end
        return nil
      end
      local box, cur, pr = Chrome.box, Chrome.cursorThrough, Chrome.printThrough
      Chrome.box = function(tx, ty, tw, th, ...)
        if ty == 12 and tx == en_x and th == 6 then return box(de_x, ty, tw + tx - de_x, th, ...) end
        return box(tx, ty, tw, th, ...)
      end
      Chrome.cursorThrough = function(tx, ty, ...)
        local neu = (ty == 14 or ty == 16) and spalte(tx + 1)
        return cur(neu and neu - 1 or tx, ty, ...)
      end
      Chrome.printThrough = function(text, tx, ty, ...)
        local neu = (ty == 14 or ty == 16) and spalte(tx)
        return pr(text, neu or tx, ty, ...)
      end
      danach(function() Chrome.box, Chrome.cursorThrough, Chrome.printThrough = box, cur, pr end,
        original, self, ox, ...)
    end
  end

  -- Kampf-HUD des Spielers: die ROM druckt die KP mit PrintNum in zwei 3er-Feldern („ 42/ 42“ ab Spalte 11), der Port
  -- rückt „42/42“ bündig an Spalte 18 (BattleState:drawPlayerHud) → Felder wie im Original
  local function kampf_kp_einhaengen()
    local okb, BS = G.port_modul("src.ui.gen2.BattleState")
    if not okb or type(BS) ~= "table" or type(BS.drawPlayerHud) ~= "function" then return end
    local _, Chrome = G.port_modul("src.ui.gen2.Chrome")
    local alt = BS.drawPlayerHud
    BS.drawPlayerHud = function(self, ...)
      local pr = Chrome.printRightThrough
      Chrome.printRightThrough = function(text, tx, ty, ...)
        local a, b
        if type(text) == "string" then a, b = text:match("^(%d+)/(%d+)$") end
        if a and tx == 18 and ty == 10 and #a <= 3 and #b <= 3 then
          text = ("%3d/%3d"):format(tonumber(a), tonumber(b))
        end
        return pr(text, tx, ty, ...)
      end
      return danach(function() Chrome.printRightThrough = pr end, alt, self, ...)
    end
  end

  -- ================================================================ 6. Haken: Pokédex, Status, Ruhmeshalle

  -- Pokédex-Optionen: Beschreibung unter jedem Modus (PokedexMenu.OPTION_MODES[i].lines) aus der DE-ROM
  local function dexmodi_einhaengen(dm)
    local _, PM = G.port_modul("src.ui.gen2.PokedexMenu")
    -- Fensterköpfe „ OPTIONEN “ / „ SUCHE “: im DE-Code läuft der Text bis zur Abschluss-Kachel $3C durch; der
    -- Port setzt $3C fest auf Spalte 9 (Länge des englischen „ OPTION “) → hinter den tatsächlichen Text setzen
    local kopf_ende
    local alt_text, alt_tile = PM.text, PM.tile
    PM.text = function(self, str, tx, ty, ...)
      -- Beschreibung der Modi: die zweite Zeile folgt in der DE-ROM nach <NEXT> zwei Zeilen tiefer (Zeilen 14/16),
      -- der Port setzt sie auf Zeile 15 (PokedexMenu:drawOption)
      if tx == 1 and ty == 15 and self.view == "option" then ty = 16 end
      -- Größe/Gewicht: die DE-ROM druckt den Dezimalpunkt von PrintNum („0.5m“, „7.9kg“), der Port ein Komma
      if type(str) == "string" and str:match("^%d+,%d$") then str = str:gsub(",", ".") end
      if tx == 1 and ty == 1 and type(str) == "string" then
        local _, n = str:gsub("[^\128-\191]", "")
        kopf_ende = 1 + n
      end
      return alt_text(self, str, tx, ty, ...)
    end
    PM.tile = function(self, id, tx, ty, ...)
      if id == 0x3c and ty == 1 and tx == 9 and kopf_ende and kopf_ende >= 2 then tx = kopf_ende end
      return alt_tile(self, id, tx, ty, ...)
    end
    if type(dm) ~= "table" or not next(dm) then return end
    for i, t in pairs(dm) do
      local eintrag = PM.OPTION_MODES and PM.OPTION_MODES[i]
      if eintrag then
        local zeilen = {}
        for z in (t .. "\n"):gmatch("(.-)\n") do zeilen[#zeilen + 1] = z end
        eintrag.lines = zeilen
      end
    end
  end

  -- Pokédex-Suche: das Typ-Rad läuft in der DE-ROM (wie im Original überhaupt) in der Reihenfolge der Such-Tafel
  -- (NORMAL, FEUER, WASSER, …), der Port in der von data/types/names.asm (NORMAL, KAMPF, …); die Namen stehen als
  -- 8 Zeichen breite Felder ab Spalte 9 („  ----  “, „ FEUER  “, „PFLANZE “), der Port setzt den bloßen Typnamen
  -- auf Spalte 10 und „-----“ für keinen Typ.  Dazu das Such-OBJ der ROM (der Port zeichnet keins, daten.suchbild).
  local SUCHTYPEN = { "NORMAL", "FIRE", "WATER", "GRASS", "ELECTRIC", "ICE", "FIGHTING", "POISON", "GROUND", "FLYING",
    "PSYCHIC", "BUG", "ROCK", "GHOST", "DRAGON", "DARK", "STEEL" }
  local function dexsuche_einhaengen(suchtafel, bild)
    if type(suchtafel) ~= "table" or not suchtafel[0] then return end
    local okp, PM = G.port_modul("src.ui.gen2.PokedexMenu")
    if not okp or type(PM) ~= "table" or type(PM.SEARCH_TYPES) ~= "table" or #PM.SEARCH_TYPES ~= #SUCHTYPEN
        or type(PM.drawSearch) ~= "function" then
      return
    end
    for i, t in ipairs(SUCHTYPEN) do PM.SEARCH_TYPES[i] = t end
    local alt = PM.drawSearch
    PM.drawSearch = function(self, ...)
      local tx = PM.text
      local namen = {}
      for slot = 1, 2 do namen[slot] = self:searchTypeName(slot) end
      PM.text = function(s, str, x, y, ...)
        if x == 10 and (y == 4 or y == 6) and str == namen[y == 4 and 1 or 2] then
          local feld = suchtafel[(self.searchType or {})[y == 4 and 1 or 2] or 0]
          if feld then return tx(s, feld, 9, y, ...) end
        end
        return tx(s, str, x, y, ...)
      end
      local erg = { pcall(alt, self, ...) }
      PM.text = tx
      if not erg[1] then error(erg[2], 0) end
      if type(bild) == "table" and type(bild.pix) == "string" and #bild.pix == 576 then
        if bild.img == nil then
          local okb, img = pcall(obj_bild, bild.pix, 24, 24)
          bild.img = okb and img or false
        end
        if bild.img then
          local GbcPalette = require("src.render.GbcPalette")
          local Gr = love.graphics
          Gr.setColor(1, 1, 1, 1)
          if GbcPalette.available() and type(bild.pal) == "table" then
            GbcPalette.with(bild.pal, function() Gr.draw(bild.img, bild.x or 64, bild.y or 72) end)
          else
            Gr.draw(bild.img, bild.x or 64, bild.y or 72)
          end
        end
      end
      return unpack(erg, 2)
    end
  end

  -- Pokédex-Optionen: die ROM stellt den Pfeil beim Öffnen auf die erste Zeile, der Port auf den aktuellen Modus
  -- (PokedexMenu:update, Öffnen mit SELECT) – Rezept dexoption_oben
  local function dexoption_einhaengen(an)
    if an ~= true then return end
    local okp, PM = G.port_modul("src.ui.gen2.PokedexMenu")
    if not okp or type(PM) ~= "table" or type(PM.update) ~= "function" then return end
    local alt = PM.update
    PM.update = function(self, ...)
      local vorher = self.view
      local erg = { alt(self, ...) }
      if vorher ~= "option" and self.view == "option" then self.optionIndex = 1 end
      return unpack(erg)
    end
  end

  -- Pokédex-Liste (PokedexMenu:rebuild): die ROM führt im A-Z-Modus nur gesehene POKéMON (Pokedex_ABCMode überspringt
  -- ungesehene) und endet in NEU/ALT beim letzten gesehenen (wDexListingEnd); der Port listet immer alle 251
  local function dexliste_einhaengen()
    local okp, PM = G.port_modul("src.ui.gen2.PokedexMenu")
    if not okp or type(PM) ~= "table" or type(PM.rebuild) ~= "function" or type(PM.mode) ~= "function" then return end
    local alt = PM.rebuild
    PM.rebuild = function(self, ...)
      local erg = { alt(self, ...) }
      local rows = self.rows
      if type(rows) == "table" and #rows > 0 then
        local neu = {}
        if self:mode() == "A-Z" then
          for _, r in ipairs(rows) do if r.seen then neu[#neu + 1] = r end end
        else
          local letzte = 0
          for i, r in ipairs(rows) do if r.seen then letzte = i end end
          for i = 1, letzte do neu[i] = rows[i] end
        end
        if #neu > 0 then
          self.rows = neu
          self.index = math.max(1, math.min(self.index or 1, #neu))
          if type(self.ensureVisible) == "function" then self:ensureVisible() end
        end
      end
      return unpack(erg)
    end
  end

  -- Statusseite 2 (SummaryMenu greenPlacements): getragenes Item auf der Spalte der DE-ROM (Gold/Silber DE 8 statt 6)
  -- und „AP“ als die zwei fetten Kacheln der Status-Grafik wie im Original, nicht als Schrift
  local function statusseite_einhaengen(st)
    if type(st) ~= "table" or not st.item_x then return end
    local okm, SM = G.port_modul("src.ui.gen2.SummaryMenu")
    if not okm or type(SM) ~= "table" or type(SM.greenPlacements) ~= "function"
        or type(SM.drawPlacements) ~= "function" then
      return
    end
    local Strings = require("src.core.Strings")
    local alt_green = SM.greenPlacements
    SM.greenPlacements = function(self, ...)
      local liste = alt_green(self, ...)
      for _, e in ipairs(type(liste) == "table" and liste or {}) do
        if e.x == 6 and e.y == st.item_y then e.x = st.item_x end
        if e.x == 12 and e.text == Strings("PP") then e.ap = true end
      end
      return liste
    end
    local alt_draw = SM.drawPlacements
    SM.drawPlacements = function(self, liste, palette, ...)
      local sheet = type(st.ap) == "table" and type(self.statsTiles) == "function" and self:statsTiles()
      if not (sheet and sheet.quads and sheet.quads[st.ap[1]] and sheet.quads[st.ap[2]]) then
        return alt_draw(self, liste, palette, ...)
      end
      local rest = {}
      for _, e in ipairs(liste or {}) do
        if e.ap then
          self:pageTile(st.ap[1], e.x, e.y, palette)
          self:pageTile(st.ap[2], e.x + 1, e.y, palette)
        else
          rest[#rest + 1] = e
        end
      end
      return alt_draw(self, rest, palette, ...)
    end
  end

  -- Statusbildschirm, Bild oben links (SummaryMenu:drawPicBlock): die ROM setzt den 7×7-Block gespiegelt
  -- (stats_screen.asm: wBoxAlignment = 1 vor PrepMonFrontpic, das POKéMON schaut nach rechts); der Port zeichnet ihn
  -- ungespiegelt (Rezept status_spiegeln)
  local function statusbild_einhaengen(an)
    if an ~= true then return end
    local okm, SM = G.port_modul("src.ui.gen2.SummaryMenu")
    if not okm or type(SM) ~= "table" or type(SM.drawPicBlock) ~= "function" then return end
    local alt = SM.drawPicBlock
    SM.drawPicBlock = function(...)
      local Gr = love.graphics
      Gr.push()
      Gr.translate(7 * 8, 0)
      Gr.scale(-1, 1)
      return danach(function() Gr.pop() end, alt, ...)
    end
  end

  -- Ruhmeshalle: der Port schreibt hinter „<ID>№“ fest den „/“ der EN-ROM (src/ui/gen2/HallOfFame.lua monPlacements/
  -- playerPlacements); die DE-ROM setzt dort „.“ → Zeichen aus der DE-ROM (daten.hof_trenner)
  local function ruhmeshalle_einhaengen(trenner)
    if type(trenner) ~= "string" then return end
    local okh, HoF = G.port_modul("src.ui.gen2.HallOfFame")
    if not okh or type(HoF) ~= "table" then return end
    for _, name in ipairs({ "monPlacements", "playerPlacements" }) do
      local alt = HoF[name]
      if type(alt) == "function" then
        HoF[name] = function(...)
          local out = alt(...)
          for _, e in ipairs(type(out) == "table" and out or {}) do
            if type(e) == "table" and e.text == "<ID>№/" then e.text = "<ID>№" .. trenner end
          end
          return out
        end
      end
    end
  end

  -- ================================================================ 7. Haken: Tastaturen und Brief

  -- Tastaturen nach der DE-ROM (daten.tasten): die Tafeln des Namensbildschirms (src/ui/gen2/NamingScreen.lua
  -- NAME_INPUT_*/BOX_INPUT_*) und des Briefs (src/ui/gen2/MailCompose.lua MAIL_INPUT_*) an Ort und Stelle ersetzen.
  -- Die Umschaltzeile steht in DE an anderen Spalten („klein LÖSCH ENDE“: Wörter ab 0/6/12, EN „lower  DEL   END“
  -- 0/7/13) → Beschriftungen (und beim Brief den Cursor, der eine Spalte links davon steht) umsetzen.
  -- Der Namensbildschirm zählt, löscht und zeichnet Bytes (#self.text); Ä Ö Ü ä ö ü ß sind zwei Bytes, <PK> vier →
  -- nach Zeichen (Font.split) zählen, löschen und zeichnen, wie die DE-ROM je Zeichen ein Byte belegt.  Ebenso der
  -- Brief (Mail.characters zählt UTF-8-Zeichen, <PK>/<MN>/<PO>/<KE> sind dort vier Zeichen).
  local NAME_EN_SPALTEN = { 2, 9, 15 }    -- NamingScreen.lua BOTTOM_LABEL_TX = 2 + EN-Wortanfänge
  local BRIEF_EN_SPALTEN = { 1, 8, 14 }   -- MailCompose.lua BOTTOM_LABEL_TX = 1 + EN-Wortanfänge
  local function tasten_einhaengen(ta)
    if type(ta) ~= "table" then return end
    local Font = require("src.render.Font")
    -- Font.split zerlegt das Makro „#“ in die vier Glyphen von „POKé“ (vier Spannen mit demselben from) → eine Spanne
    -- je Quelltext-Stelle, sonst würde „#“ beim Zählen, Löschen und Kürzen (Mail.trim) vervielfacht
    local function zeichen(text)
      local aus, letzte = {}, nil
      text = text or ""
      for _, sp in ipairs(Font.split(text)) do
        if sp.from ~= letzte then aus[#aus + 1] = text:sub(sp.from, sp.to) end
        letzte = sp.from
      end
      return aus
    end
    local function setze(ziel, quelle)
      if type(ziel) ~= "table" or type(quelle) ~= "table" or type(quelle.zeilen) ~= "table" then return end
      for i = #ziel, 1, -1 do ziel[i] = nil end
      for i, z in ipairs(quelle.zeilen) do ziel[i] = kopie(z) end
    end
    local function umsetzen(en, de, rand)
      local t = {}
      for i = 1, 3 do t[en[i]] = rand + de.spalten[i] end
      return t
    end
    local _, Chrome = G.port_modul("src.ui.gen2.Chrome")
    -- Profilnamen der Mod-Verwaltung gibt der Port über die Gen-1-Tastatur ein (src/ui/NamingScreen.lua): deren
    -- Umschaltzelle „lower case“/„UPPER CASE“ bekommt das Wort der DE-Umschaltzeile („klein“/„GROß“)
    if ta.name_gross and ta.name_klein and (ta.name_gross.wort or "") ~= "" and (ta.name_klein.wort or "") ~= "" then
      G.romliterale_einhaengen({ [G.pruefsumme("lower case")] = ta.name_gross.wort,
        [G.pruefsumme("UPPER CASE")] = ta.name_klein.wort })
    end
    local okn, NS = G.port_modul("src.ui.gen2.NamingScreen")
    if okn and type(NS) == "table" and ta.name_gross and ta.box_gross then
      setze(NS.NAME_INPUT_UPPER, ta.name_gross)
      setze(NS.NAME_INPUT_LOWER, ta.name_klein)
      setze(NS.BOX_INPUT_UPPER, ta.box_gross)
      setze(NS.BOX_INPUT_LOWER, ta.box_klein)
      local gross, klein = umsetzen(NAME_EN_SPALTEN, ta.name_gross, 2), umsetzen(NAME_EN_SPALTEN, ta.name_klein, 2)
      if type(NS.drawPanel) == "function" then
        local alt = NS.drawPanel
        NS.drawPanel = function(self, ...)
          local unten = self:keyboardTop() + self:bottomRow() * 2
          local spalte = self.lower and klein or gross
          local pt = Chrome.printThrough
          Chrome.printThrough = function(text, tx, ty, ...)
            if ty == unten and spalte[tx] then tx = spalte[tx] end
            return pt(text, tx, ty, ...)
          end
          return danach(function() Chrome.printThrough = pt end, alt, self, ...)
        end
      end
      NS.addCharacter = function(self, ch)
        if not ch then return end
        if #zeichen(self.text) >= self.maxLength then return end
        self.text = self.text .. ch
      end
      NS.deleteCharacter = function(self)
        local z = zeichen(self.text)
        if #z == 0 then return end
        self.text = table.concat(z, "", 1, #z - 1)
      end
      if type(NS.update) == "function" then
        -- Nach dem letzten freien Platz springt der Cursor auf ENDE (NamingScreen.update, Byte-Zähler): erst, wenn
        -- wirklich alle Zeichen belegt sind
        local alt = NS.update
        NS.update = function(self, ...)
          local text, zeile, spalte = self.text, self.row, self.col
          local erg = { alt(self, ...) }
          if type(self.text) == "string" and #self.text > #(text or "") and self.row == self:bottomRow()
              and zeile ~= self.row and #zeichen(self.text) < self.maxLength then
            self.row, self.col = zeile, spalte
          end
          return unpack(erg)
        end
      end
      NS.drawEntry = function(self, tx, ty)
        local Gr = love.graphics
        local z = zeichen(self.text)
        local pen = tx * 8
        for i = 1, self.maxLength do
          Gr.setColor(0, 0, 0, 1)
          if z[i] then
            Font.draw(z[i], pen, ty * 8)
          else
            local naechstes = i == #z + 1
            local glyph = naechstes and self.tiles.underLine or self.tiles.middleLine
            if glyph then
              Gr.draw(glyph, pen, ty * 8)
            else
              Gr.rectangle("fill", pen + 1, ty * 8 + (naechstes and 7 or 4), 6, 1)
            end
          end
          pen = pen + 8
        end
        Gr.setColor(1, 1, 1, 1)
      end
    end
    local okm, MC = G.port_modul("src.ui.gen2.MailCompose")
    if okm and type(MC) == "table" and ta.brief_gross and ta.brief_klein then
      setze(MC.MAIL_INPUT_UPPER, ta.brief_gross)
      setze(MC.MAIL_INPUT_LOWER, ta.brief_klein)
      local gross, klein = umsetzen(BRIEF_EN_SPALTEN, ta.brief_gross, 1), umsetzen(BRIEF_EN_SPALTEN, ta.brief_klein, 1)
      local cur_gross, cur_klein = {}, {}
      for en, de in pairs(gross) do cur_gross[en - 1] = de - 1 end
      for en, de in pairs(klein) do cur_klein[en - 1] = de - 1 end
      -- Rahmen-Cursor über NamingScreen:drawCursorBox (eigene Viertel-Quads je Brief-Bildschirm)
      local NS_box
      local okns, NSm = G.port_modul("src.ui.gen2.NamingScreen")
      if okns and type(NSm) == "table" and type(NSm.drawCursorBox) == "function" then
        local stellvertreter = setmetatable({}, { __mode = "k" })
        NS_box = function(self, tx, ty, breite)
          local st = stellvertreter[self]
          if not st then
            st = setmetatable({ tiles = self.tiles }, { __index = NSm })
            stellvertreter[self] = st
          end
          return st:drawCursorBox(tx, ty, breite)
        end
      end
      -- Eingabezeilen: die zweite Zeile steht in der ROM zwei Zeilen tiefer (<NEXT> rückt im Brief um zwei Zeilen
      -- vor, PlaceString ab 2,2), der Port setzt sie direkt unter die erste (MailCompose:drawEntryRow, ENTRY_Y + 1)
      if type(MC.drawEntryRow) == "function" then
        local alt_zeile = MC.drawEntryRow
        MC.drawEntryRow = function(self, chars, first, ty, ...)
          if ty == 3 then ty = 4 end
          return alt_zeile(self, chars, first, ty, ...)
        end
      end
      if type(MC.drawPanel) == "function" then
        local alt = MC.drawPanel
        MC.drawPanel = function(self, ...)
          local spalte = self.lower and klein or gross
          local cur = self.lower and cur_klein or cur_gross
          local unten = self.onBottomRow and self:onBottomRow()
          local unten_y   -- Zeile der Umschaltzeile: die Zeile, in der die erste Beschriftung steht
          local pr, cu, dr = Chrome.print, Chrome.cursor, love.graphics.draw
          Chrome.print = function(text, tx, ty, ...)
            if spalte[tx] and ty >= 17 then unten_y = ty; tx = spalte[tx] end
            return pr(text, tx, ty, ...)
          end
          Chrome.cursor = function(tx, ty, ...)
            if unten and ty == unten_y and cur[tx] then tx = cur[tx] end
            return cu(tx, ty, ...)
          end
          love.graphics.draw = function(d, x, y, ...)
            if unten and unten_y and d == self.tiles.cursor and y == unten_y * 8 and type(x) == "number"
                and cur[x / 8] then
              x = cur[x / 8] * 8
            end
            -- Cursor: in der ROM ein Rahmen um das Zeichen bzw. um das Wort der Umschaltzeile (dieselben Kacheln
            -- wie beim Namensbildschirm, NamingScreen:drawCursorBox), nicht die ganze Kachelvorlage links daneben
            if d == self.tiles.cursor and type(x) == "number" and type(y) == "number" and select("#", ...) == 0
                and NS_box then
              love.graphics.draw = dr
              local ok_box = pcall(NS_box, self, x / 8 + 1, y / 8, unten and 5 or 1)
              love.graphics.draw = dr
              if ok_box then return end
            end
            return dr(d, x, y, ...)
          end
          return danach(function() Chrome.print, Chrome.cursor, love.graphics.draw = pr, cu, dr end, alt, self, ...)
        end
      end
    end
    local okb, Mail = G.port_modul("src.core.gen2.Mail")
    if okb and type(Mail) == "table" and type(Mail.characters) == "function" then
      Mail.characters = function(text) return zeichen(text) end
    end
  end

  -- Brief schreiben (MailCompose): die ROM färbt den Rahmen oben mit der BG-Palette des Diploms (SCGB_DIPLOMA, dieselbe
  -- wie beim Namensbildschirm, NamingScreen:drawBackdrop) und zeigt oben links den Umschlag als OBJ
  -- (daten.briefsymbol); der Port zeichnet den Rahmen ohne Palette und keinen Umschlag
  local function brief_einhaengen(sym)
    local okm, MC = G.port_modul("src.ui.gen2.MailCompose")
    if not okm or type(MC) ~= "table" then return end
    local GbcPalette = require("src.render.GbcPalette")
    local function palette(self)
      local d = self.game and self.game.data and self.game.data.gen2Diploma
      return d and d.bgPalette
    end
    if type(MC.drawBackdrop) == "function" then
      local alt = MC.drawBackdrop
      MC.drawBackdrop = function(self, ...)
        local pal = palette(self)
        if not (pal and self.tiles and self.tiles.border and GbcPalette.available()) then return alt(self, ...) end
        local args = { ... }
        GbcPalette.with(pal, function() alt(self, unpack(args)) end)
      end
    end
    if type(sym) ~= "table" or type(sym.pix) ~= "string" or #sym.pix ~= 256 or type(MC.drawPanel) ~= "function" then
      return
    end
    local bild
    local function umschlag()
      if bild == nil then
        local ok, b = pcall(obj_bild, sym.pix, 16, 16)
        bild = ok and b or false
      end
      return bild or nil
    end
    local alt = MC.drawPanel
    MC.drawPanel = function(self, ...)
      local erg = { alt(self, ...) }
      local img = umschlag()
      if img then
        local Gr = love.graphics
        Gr.setColor(1, 1, 1, 1)
        if type(sym.pal) == "table" and GbcPalette.available() then
          GbcPalette.with(sym.pal, function() Gr.draw(img, 0, 0) end)
        else
          Gr.draw(img, 0, 0)
        end
      end
      return unpack(erg)
    end
  end

  -- ================================================================ 8. Startmenü und Mod-Verwaltung

  -- Startmenü: die ROM hat genau acht Zeilen (… OPTION, ZURÜCK); der Port fügt MODS ein, sobald Mods installiert sind,
  -- und blättert dann mit ▼.  Die Zeile kommt über den Port-Haken ui.start_menu.items weg; die Mod-Verwaltung bleibt
  -- über OPTION → MODS (optionen_mods_einhaengen) und im Launcher unter MODS erreichbar.
  local function startmenue_einhaengen(ende_text)
    local oks, StartMenu = G.port_modul("src.ui.gen2.StartMenu")
    if not oks or type(StartMenu) ~= "table" or type(StartMenu.update) ~= "function" then return end
    -- Die letzte Zeile heißt in der ROM „ZURÜCK“ (StartMenu .ExitString); „FERTIG“ ist die Zeile zum Beenden des
    -- Käferwettbewerbs.  Im Port tragen beide denselben Quelltext „QUIT“ im selben Kontext, die Zuordnung trifft daher
    -- nur einen → die normale Zeile bekommt den Text von „EXIT“ (Rezept: .ExitString der DE-ROM) und die
    -- Beschreibung .ExitDesc (daten.startmenue_ende)
    local Strings = require("src.core.Strings")
    local function ohne_mods(items)
      if type(items) ~= "table" then return items end
      local aus = {}
      for _, it in ipairs(items) do
        if not (type(it) == "table" and it.value == "mods") then
          if type(it) == "table" and it.value == "quit" and it.translateLabel then
            local ok, t = pcall(Strings, "EXIT")
            if ok and type(t) == "string" and t ~= "EXIT" then it.label, it.translateLabel = t, false end
            if type(ende_text) == "string" and ende_text ~= "" then it.desc, it.translateDesc = ende_text, true end
          end
          aus[#aus + 1] = it
        end
      end
      return aus
    end
    assert(type(mod.hooks) == "table" and type(mod.hooks.wrap) == "function", "mod.hooks:wrap fehlt")
    mod.hooks:wrap("ui.start_menu.items", function(weiter, game, items, ...)
      return ohne_mods(weiter(game, items, ...))
    end)
  end

  -- OPTION → MODS: wie in Gen 1 (src/ui/OptionsMenu.lua „mods“) und Gen 3 (src/ui/game3/option_rows.lua) eine Zeile,
  -- die die Mod-Verwaltung öffnet – derselbe Bildschirm wie der Port-Startmenüeintrag MODS (src/core/Game2.lua
  -- onChoose „mods“ → Screens.push(game, "ManagerState")).  Über den Haken ui.options.rows (src/ui/gen2/
  -- OptionsMenu.lua OptionsMenu.new); eine Zeile ohne Gruppe landet in groupView hinter den ORDER-Einträgen in der
  -- Reihenfolge der Liste → an den Anfang gesetzt steht sie unmittelbar nach EXTRAS, vor STEUERUNG, MENÜ-KONTO und
  -- ZURÜCK.  Ohne Wert (die Wertspalte hat nur acht Zeichen).  Doppelt eingehängt wird nichts: ein früherer Haken
  -- (erneuter Spielstart lädt die Mods neu) wird vorher entfernt, und eine schon vorhandene Zeile „mods“ bleibt allein.
  local function optionen_mods_einhaengen()
    assert(type(mod.hooks) == "table" and type(mod.hooks.wrap) == "function", "mod.hooks:wrap fehlt")
    local oko, OM = G.port_modul("src.ui.gen2.OptionsMenu")
    if not oko or type(OM) ~= "table" then error("src.ui.gen2.OptionsMenu nicht ladbar", 0) end
    local alt_weg = rawget(OM, "__dgm_g2_mods_weg")
    if type(alt_weg) == "function" then pcall(alt_weg) end
    local weg = mod.hooks:wrap("ui.options.rows", function(weiter, game, rows, ...)
      local erg = weiter(game, rows, ...)
      if type(erg) ~= "table" then return erg end
      for _, row in ipairs(erg) do
        if type(row) == "table" and row.id == "mods" then return erg end
      end
      table.insert(erg, 1, { id = "mods", label = "MODS", port = true,
        activate = function(g)
          local oks, Screens = G.port_modul("src.ui.Screens")
          if oks and type(Screens) == "table" and type(Screens.push) == "function" then
            Screens.push(g, "ManagerState")
          end
        end })
      return erg
    end)
    rawset(OM, "__dgm_g2_mods_weg", type(weg) == "function" and weg or nil)
  end

  -- Mod-Verwaltung (src/mods/ManagerState.lua, wie in Definitiv German Gen 1): ManagerState kürzt Zeilen vor dem
  -- Zeichnen auf 15 bzw. 17 Zeichen (drawTruncated); der Literaltausch beim Kodieren (zusatz.l) sähe dann nur den
  -- gekürzten englischen Text.  Deshalb hier schon Zeilenmodelle, Hinweise und Rückfragen übersetzen (dieselbe
  -- Tabelle) und Status-/Kategoriezeile der Detailseite aus den Angaben des Mods deutsch setzen.
  local DATEI_MV = "src/mods/ManagerState.lua"
  local PROFIL = { content = "INHALT", overhaul = "UMBAU", total_conversion = "KOMPLETT" }
  local function zeichenzahl(t) return #(t:gsub("[\128-\191]", "")) end
  local function kuerzen(t, n)
    local aus, i = {}, 0
    for z in t:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      i = i + 1
      if i > n then break end
      aus[i] = z
    end
    return table.concat(aus)
  end
  local function verwaltung_einhaengen()
    local ok, MS = G.port_modul("src.mods.ManagerState")
    if not ok or type(MS) ~= "table" or type(MS.rowsForScreen) ~= "function" then
      error("src.mods.ManagerState nicht ladbar", 0)
    end
    -- erneuter Spielstart lädt die Mods neu, das Port-Modul bleibt: immer von den Port-Funktionen aus einhängen
    local orig = rawget(MS, "__dgm_g2_mv_orig")
    if type(orig) ~= "table" then
      orig = {}
      for _, n in ipairs({ "rowsForScreen", "orderRows", "notify", "drawOverlay", "drawDetail" }) do
        orig[n] = MS[n]
      end
      rawset(MS, "__dgm_g2_mv_orig", orig)
    end
    local Font = require("src.render.Font")
    local function de(t)
      local e = G.literale and G.literale[DATEI_MV]
      if type(t) ~= "string" or not (e and G.tauschen) then return t end
      return G.tauschen(t, e)
    end
    -- Kategorien schreiben die Manifeste verschieden („Translation“, „GRAPHICS“): auch in Großbuchstaben nachschlagen
    local function kategorie(t)
      if type(t) ~= "string" then return t end
      local w = de(t)
      if w == t and de(t:upper()) ~= t:upper() then w = de(t:upper()) end
      return w
    end
    local alt_rows = orig.rowsForScreen
    MS.rowsForScreen = function(self, ...)
      local rows = alt_rows(self, ...)
      if type(rows) ~= "table" then return rows end
      for _, r in ipairs(rows) do
        if type(r) == "table" and type(r.label) == "string" and not r.mod and not r.profile then
          if r.header and self.screen == "list" and self.tab == 1 then
            r.label = kategorie(r.label)
          else
            r.label = de(r.label)
          end
        end
      end
      return rows
    end
    -- Ladereihenfolge („< LOAD #2/4 >“, „LOAD #1 OF 1“): Zahlen aus der Zeile, Text deutsch
    if type(orig.orderRows) == "function" then
      local alt_order = orig.orderRows
      MS.orderRows = function(self, m, ...)
        local rows = alt_order(self, m, ...)
        for _, r in ipairs(type(rows) == "table" and rows or {}) do
          local a, n
          if type(r.label) == "string" then a, n = r.label:match("(%d+)%D+(%d+)") end
          if a then r.label = r.adjust and ("PLATZ %s/%s"):format(a, n) or ("PLATZ %s VON %s"):format(a, n) end
        end
        return rows
      end
    end
    if type(orig.notify) == "function" then
      local alt_notify = orig.notify
      MS.notify = function(self, text, ...) return alt_notify(self, de(text), ...) end
    end
    if type(orig.drawOverlay) == "function" then
      local alt_overlay = orig.drawOverlay
      MS.drawOverlay = function(self, ...)
        local o = self.overlay
        if type(o) ~= "table" or type(o.lines) ~= "table" then return alt_overlay(self, ...) end
        local alt_lines, neu = o.lines, {}
        for i, z in ipairs(alt_lines) do neu[i] = de(z) end
        o.lines = neu
        danach(function() o.lines = alt_lines end, alt_overlay, self, ...)
      end
    end
    if type(orig.drawDetail) == "function" then
      local alt_detail = orig.drawDetail
      MS.drawDetail = function(self, ...)
        local m = self.currentMod
        if type(m) ~= "table" then return alt_detail(self, ...) end
        local status = m.enabled and "AN" or "AUS"
        local okr, hier = pcall(self.runsHere, self, m)
        if m.state == "wrong_generation" or (okr and not hier) then
          status = status .. " (NICHT HIER)"
        elseif m.state == "blocked_dependency" then
          status = status .. " ?"
        elseif m.error then
          status = status .. " !"
        end
        local oks, vorgemerkt = pcall(self.isStaged, self, m)
        if oks and vorgemerkt then status = status .. " (VORGEMERKT)" end
        local kat, prof = kategorie(m.category or "OTHER"), PROFIL[m.profile or "content"] or tostring(m.profile)
        local zeile = kat .. " / " .. prof
        if zeichenzahl(zeile) > 17 then zeile = kat .. "/" .. prof end
        if zeichenzahl(zeile) > 17 then zeile = kat end
        local fd = Font.draw
        Font.draw = function(text, x, y, ...)
          if x == 16 and y == 24 then text = kuerzen(status, 17)
          elseif x == 16 and y == 32 then text = kuerzen(zeile, 17) end
          return fd(text, x, y, ...)
        end
        danach(function() Font.draw = fd end, alt_detail, self, ...)
      end
    end
  end

  -- ================================================================ Start
  function K.start()
    local edition = GameVersion.get()
    local id = IMPORT[edition]
    if not id then return end
    local info, err = mod.imports:info(id)
    if not info then
      mod.log:warn("Definitiv German: deutsche ROM für %s nicht importiert (%s) – das Spiel bleibt englisch. "
        .. "Im Launcher unter MODS die deutsche ROM importieren.", edition, tostring(err))
      return
    end
    local Z = assert(G.datei("zeichen.lua"))
    local rezept, rerr = G.datei("rezept_" .. edition .. ".lua")
    if not rezept then
      mod.log:warn("Definitiv German: Rezept fehlt: %s", tostring(rerr))
      return
    end
    local rezept_text = mod:read("rezept_" .. edition .. ".lua") or ""
    -- Cache gilt nur für genau diesen Mod-Stand: Rezept, Kern und gemeinsame Bausteine über ihre Prüfsumme
    local stand = G.pruefsumme(rezept_text .. (mod:read("kern.lua") or "") .. (mod:read("gemeinsam.lua") or ""))
    local schluessel = ("v1/%s/%s/%s-%s/%s-%s"):format(edition, info.md5 or "?", MODVERSION, stand:sub(2),
      Version.engine or "?", Version.cache or "?")
    local bericht = {}
    local daten, bilder = G.cache_lesen(schluessel)
    if daten then
      bericht.quelle = "Cache"
    else
      local rom, rerr2 = mod.imports:read(id, 0, info.size)
      if not rom then
        mod.log:warn("Definitiv German: deutsche ROM nicht lesbar: %s", tostring(rerr2))
        return
      end
      local t0 = love.timer and love.timer.getTime() or 0
      local fehler
      daten, bilder, fehler = extrahieren(edition, rom, rezept, Z)
      for _, f in ipairs(fehler) do mod.log:warn("Definitiv German: %s", f) end
      bericht.quelle = ("DE-ROM (%.1f s)"):format((love.timer and love.timer.getTime() or 0) - t0)
      if #fehler == 0 then G.cache_schreiben(schluessel, daten, bilder) end
    end
    registries(daten, bericht)
    puffer_einhaengen(rezept.pf, { _MartBoughtText = function() return verkauf_menge end })
    -- Einhängen mit Meldung: schlägt ein Haken fehl (Port-Stand geändert), steht das im Log statt still zu fehlen.
    -- Die Reihenfolge zählt, wo zwei Haken dieselbe Funktion umhüllen (MailCompose.drawPanel: Tastaturen, dann Brief).
    local function haken(name, f, ...)
      local ok, err2 = pcall(f, ...)
      if not ok then mod.log:warn("Definitiv German: %s: %s", name, tostring(err2)) end
    end
    haken("Verkaufen", verkauf_einhaengen)
    -- Wegwerfen: „{NUM} x {STRBUF} weggeworfen.“ – die Menge kommt aus der Rückfrage davor (Rezept mg)
    haken("Wegwerfen", G.mengen_einhaengen, rezept.mg)
    haken("TM-Tasche", tasche_einhaengen, daten.vm)
    haken("PC-Rückfrage", pc_frage_einhaengen)
    haken("Uhr", uhr_einhaengen, daten.uhr)
    haken("Käferwettbewerb", wettbewerb_einhaengen)
    haken("Geschlechtswahl", geschlecht_einhaengen, daten.geschlecht)
    haken("Münzfenster", muenzen_einhaengen, daten.muenzen)
    haken("Diplom", diplom_einhaengen, daten.diplom)
    haken("Käfertausch", kaefertausch_einhaengen, daten.kaefertausch)
    haken("Tastaturen", tasten_einhaengen, daten.tasten)
    haken("PC-Menüs", pcmenue_einhaengen, daten.pcmenue)
    haken("Laden-Cursor", laden_cursor_einhaengen)
    haken("Pokédex-Suche", dexsuche_einhaengen, daten.dexsuche, daten.suchbild)
    haken("Team-Cursor", team_cursor_einhaengen)
    haken("Kampf-KP", kampf_kp_einhaengen)
    haken("Stachler", stachler_einhaengen, daten.rom_text and daten.rom_text.SpikesText)
    haken("Ruhmeshalle", ruhmeshalle_einhaengen, daten.hof_trenner)
    haken("Artnamen", artname_einhaengen)
    haken("Skriptmenüs", skriptmenue_einhaengen, daten.turmmenue)
    haken("Statusseite", statusseite_einhaengen, daten.statusseite)
    haken("Team-Untermenü", teammenue_einhaengen, daten.teammenue)
    haken("Statusbild", statusbild_einhaengen, rezept.status_spiegeln)
    haken("Geben/Nehmen", geben_einhaengen)
    haken("Brief", brief_einhaengen, daten.briefsymbol)
    haken("Spielautomat", einsatz_einhaengen, daten.einsatz)
    haken("Startmenü", startmenue_einhaengen, daten.startmenue_ende)
    haken("Optionen-MODS", optionen_mods_einhaengen)
    haken("Mod-Verwaltung", verwaltung_einhaengen)
    haken("Pokédex-Optionen", dexoption_einhaengen, rezept.dexoption_oben)
    haken("Pokédex-Liste", dexliste_einhaengen)
    haken("Kampfmenü", kampfmenue_einhaengen, daten.kampfmenue)
    haken("EP-Level", ep_level_einhaengen)
    haken("Namensvorschläge", namen_einhaengen, daten.namen2, edition)
    haken("Pokédex-Modi", dexmodi_einhaengen, daten.dexmodi)
    haken("Spielstand-Fenster", spielstand_einhaengen, rezept.spielstand)
    haken("Box-Menü", boxmenue_einhaengen, rezept.boxmenue)
    haken("JA/NEIN", ja_nein_einhaengen, rezept.ja_nein)
    haken("Beutel-Untermenü", beutel_einhaengen, rezept.beutel_spalte)
    haken("NPC-Namen", npcnamen_einhaengen, daten.npcnamen, rezept.npcnamen)
    bericht.porttexte = G.porttexte_einhaengen(daten.porttexte, daten.portkontexte, daten.rom_text)
    G.romliterale_einhaengen(daten.romliterale)
    haken("Taschennamen", taschennamen_einhaengen)
    haken("Trainerpass", trainerpass_einhaengen, rezept.trainerpass)
    haken("Statuskürzel", statuskuerzel_einhaengen)
    mod.events:on("mods.loaded", function(ev)
      -- Tabellen setzen Port-Module zusammen, die ihrerseits Link-Module nachladen (src.link.Handshake); der Loader
      -- schriebe das dem Mod zu („undeclared network require“) – wie G.port_modul ohne Mod-Zuschreibung laufen lassen
      local ok_rt, Runtime = pcall(require, "src.mods.Runtime")
      local vorher, vorher_r = ok_rt and Runtime.currentMod, ok_rt and Runtime.modRequire
      if ok_rt then Runtime.currentMod, Runtime.modRequire = nil, nil end
      local ok, f = pcall(tabellen, ev and ev.data or {}, daten, bilder, bericht, schluessel)
      if ok_rt then Runtime.currentMod, Runtime.modRequire = vorher, vorher_r end
      if not ok then mod.log:warn("Definitiv German: %s", tostring(f)) end
      mod.log:info("Definitiv German Gen 2 (%s): %d Felder, %d Bilder", edition, bericht.felder or 0,
        bericht.bilder or 0)
    end)
    mod.events:on("game.ready", function(ev)
      if ev and ev.game then pcall(spielobjekt, ev.game, daten) end
    end)
    mod.log:info("Definitiv German Gen 2 (%s): %d Skripttexte, %d Texte, %d Pokémon, %d Port-Texte – aus %s",
      edition, bericht.skripttexte or 0, bericht.texte or 0, bericht.pokemon or 0, bericht.porttexte or 0,
      bericht.quelle)
    K.aktiv = true
    return true
  end

  return K
end
