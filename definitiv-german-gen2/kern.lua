-- Definitiv German Gen 2 – Kern: deutsche ROM lesen, mit dem Gen-2-Extraktor des Ports auslesen, Anzeigeinhalte
-- übernehmen.
--
-- Wie bei Gen 1: Das Rezept der Edition enthält die Port-Symbole mit ihren Adressen in der DEUTSCHEN ROM; der
-- unveränderte Extraktor des Ports läuft damit über die deutsche ROM des Spielers.  Übernommen werden nur
-- Anzeigeinhalte (Texte, Namen, Beschreibungen, Pokédex, Orts- und Stockwerksnamen, Schrift, Bilder mit Schrift);
-- Spieldaten bleiben, wie sie sind.
--
-- Skripttexte (Data.gen2Text) sind im Port nach der Adresse in der EN-ROM benannt („bank:addr“); das Rezept
-- ordnet jedem EN-Schlüssel die DE-Adresse zu (Gleichschritt-Paarung der Skriptgraphen, Test/werkzeug/
-- gen2_texte_paaren.py).
return function(mod, MODVERSION)
  local GameVersion = require("src.core.GameVersion")
  local RomExtractorGen2 = require("src.import.RomExtractorGen2")
  local Version = require("src.core.Version")
  local Opcodes = require("src.script.gen2.Opcodes")

  local G = assert(load(mod:read("gemeinsam.lua"), "@gemeinsam.lua"))()(mod)
  local K = { G = G }
  local kopie = G.kopie

  local IMPORT = { gold = "gold_de", silver = "silber_de", crystal = "kristall_de" }

  -- ---------------------------------------------------------------- deutsches Manifest
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
    -- Titelbild Gold/Silber: der Untertitel „GOLDENE EDITION“ ist eine Spalte breiter als „GOLD VERSION“; die DE-ROM
    -- färbt den Streifen entsprechend breiter (Rezept titel_streifen), der Port-Extraktor nimmt die EN-Breite fest →
    -- zusätzliche Kacheln nachfärben: Schatten je Pixel aus dem grauen Bild, Farbe je Schatten aus dem Streifen selbst
    local ts = rezept.titel_streifen
    if type(ts) == "table" and ts.de_w and ts.en_w and ts.de_w > ts.en_w then
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
    for rel, bild in pairs(bilder) do
      if not G.anders_als_en(rel, bild) then bilder[rel] = nil end
    end
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
    -- Port-Texte (Menüs, Statuswerte, Engine-Meldungen …), deren Vorlage in der ROM steht
    local ok, p, pk = pcall(G.porttexte_lesen, ex, rezept, m.charmap, { text = daten.rom_text or {},
      pokemon = daten.pokemon, moves = daten.moves, items = daten.items })
    if ok then
      daten.porttexte, daten.portkontexte = p, pk
    else
      fehler[#fehler + 1] = "Port-Texte: " .. tostring(p)
    end
    -- Pokédex-Modi: zwei Zeilen Beschreibung je Modus (die DE-Fassung formuliert die erste Zeile je Modus anders)
    if rezept.dexmodi then
      local dm = {}
      for i, ort in ipairs(rezept.dexmodi) do
        local okd, t = pcall(G.romtext, ex, m.charmap, ort[1], ort[2], 1, 0, 0)
        if okd and t then dm[i] = t end
      end
      daten.dexmodi = dm
    end
    -- Radiosender: Namen aus der DE-ROM (Rezept sender, Station → Bank/Adresse)
    if rezept.sender then
      local s = {}
      for id, ort in pairs(rezept.sender) do
        local oks, t = pcall(G.romtext, ex, m.charmap, ort[1], ort[2], 1, 0, 0)
        if oks and t then s[id] = t end
      end
      daten.sender = s
    end
    -- Dekorationsnamen: DecorationNames der DE-ROM (26 @-Einträge), Zuordnung über die Prüfsummen der EN-Einträge
    if rezept.deko then
      local b, a, liste = rezept.deko[1], rezept.deko[2], {}
      for i = 1, #rezept.deko[3] do
        local okr, t, n = pcall(ex.rom.readString, ex.rom, b, a, m.charmap, 0x50, 40)
        if not okr then break end
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
          local okr, t, n = pcall(ex.rom.readString, ex.rom, ort[1], a, m.charmap, 0x50, 12)
          if not okr or type(t) ~= "string" then break end
          l[i] = t
          a = a + n
        end
        if #l == 5 then daten.namen2[wer] = l end
      end
    end
    -- Feste NPC-Namen (Rezept npcnamen, gen2_npcnamen.py): Telefonliste NonTrainerCallerNames (vier @-Namen nach
    -- „----------“, Kristall mit „:“) und der Name im Fang-Tutorial (CatchTutorial .Dude)
    if rezept.npcnamen then
      local nn, t = {}, rezept.npcnamen.telefon
      if type(t) == "table" then
        local a, tel = t[2], {}
        for i = 1, #t[3] do
          local okr, s, n = pcall(ex.rom.readString, ex.rom, t[1], a, m.charmap, 0x50, 20)
          if not okr or type(s) ~= "string" then break end
          if t[4] then s = s:gsub(":$", "") end
          tel[t[3][i]] = s
          a = a + n
        end
        nn.telefon = tel
      end
      local k = rezept.npcnamen.kumpel
      if type(k) == "table" then
        local okr, s = pcall(ex.rom.readString, ex.rom, k[1], k[2], m.charmap, 0x50, 12)
        if okr and type(s) == "string" and s ~= "" then nn.kumpel = { [k[3]] = s } end
      end
      daten.npcnamen = nn
    end
    -- ROM-Literale (Rezept pl): Überschriften des Port-Abspanns, die die DE-ROM im eigenen Abspann führt
    daten.romliterale = G.romliterale_lesen(ex, rezept, m.charmap)
    -- Skripttexte: unter dem EN-Schlüssel, den das Rezept zuordnet
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
    -- Skripte mit Anzeige-Zeichenketten: nur diese Teile, unter dem EN-Schlüssel
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

  -- ---------------------------------------------------------------- Übernehmen
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

  -- Trainer: Namen, Klassennamen, Kampfturm-Sprüche (Texte); Kampfturm-Rohnamen (Bytes, aus denen der Port den
  -- Namen setzt) mit
  local function trainer_erlaubt(p, alt, neu)
    if type(neu) == "string" then return nur_texte(p, alt, neu) end
    return p:match("%.nameRaw%.%d+$") ~= nil
  end

  -- Vor dem Zusammenführen (Registries): Texte, Namen, Beschreibungen, Pokédex-Einträge
  local function registries(daten, bericht)
    local c = mod.content
    local n = 0
    for en, t in pairs(daten.skripttext or {}) do
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
    for id, it in pairs(daten.items or {}) do
      if type(it) == "table" and type(it.name) == "string" then
        c.items:patch(id, { name = it.name, description = it.description })
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
    local skripte = data.gen2Scripts or {}
    local landmarke_nach_nummer = {}
    for _, l in pairs(data.gen2Landmarks and data.gen2Landmarks.landmarks or {}) do
      if type(l) == "table" and type(l.index) == "number" and type(l.name) == "string" then
        landmarke_nach_nummer[l.index] = l.name
      end
    end
    for en, teile in pairs(daten.skriptanzeige or {}) do
      local befehle = skripte[en]
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

  -- Platzhalter-Reihenfolge: Der Port füllt {STRBUF}/{NUM} der Reihe nach mit den Werten in englischer
  -- Reihenfolge (z. B. HeldItemMenu: Meldung beim Tauschen des getragenen Items, drei Puffer).  Wo der deutsche Text die Puffer
  -- anders ordnet (Rezept pf, belegt durch gen2_puffer.py), werden die Werte für dieses Label umgestellt.
  local function puffer_einhaengen(pf)
    if type(pf) ~= "table" or not next(pf) then return end
    local CommonText = require("src.core.gen2.CommonText")
    local folge_von = setmetatable({}, { __mode = "k" })
    local fill = CommonText.fill
    CommonText.fill = function(pages, values)
      local folge = pages and folge_von[pages]
      if folge and type(values) == "table" then
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
      if values then return CommonText.fill(pages, values) end
      return pages
    end
  end

  -- EP-Balken über mehrere Level: Zwischenstufen setzt der Port als Literal „<Name> grew to level N!“ zusammen
  -- (BattleState:expLevelLine, pokecrystal data/text/battle.asm:343); nur die letzte Stufe trägt den Text aus
  -- Battle.lua (Strings()-Vorlage der Level-Meldung).  Die Zwischenstufen nehmen dieselbe Vorlage, also den DE-ROM-Text.
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

  -- Kampfmenü nach dem DE-Layout: der Port setzt den Kasten fest an Spalte 8 (Wettbewerb 2) mit Abstand 6 (12);
  -- die DE-ROM an Spalte 4 mit Abstand 7 (Wettbewerb 3 / 8), sonst überlappen „BEUTEL“ und „FLUCHT“.  Während
  -- drawBottom im Menü werden Kasten, Cursor und Beschriftungen auf die DE-Spalten umgesetzt.
  -- Namensvorschläge (NamePick): der Port führt die englischen Listen (NamePick.PRESETS/PRESETS_FEMALE) und
  -- „NEW NAME“; die DE-ROM hat eigene Namen und als ersten Punkt „NAME“.  Listen an Ort und Stelle ersetzen
  -- (presetsFor liest dieselben Tabellen), dazu die Startvorgabe field.boot.namePresets.player, falls der Port sie
  -- für Gen 2 aus Gen-1-Vorgaben füllt.
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
  end

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
      local ok2, err = pcall(original, self, ox, ...)
      Chrome.box, Chrome.cursorThrough, Chrome.printThrough = box, cur, pr
      if not ok2 then error(err, 0) end
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
        local erg = { pcall(f, ...) }
        Chrome.box, Chrome.print = box, print_
        if not erg[1] then error(erg[2], 0) end
        return (table.unpack or unpack)(erg, 2)
      end
    end
    local okS, SaveMenu = G.port_modul("src.ui.gen2.SaveMenu")
    if okS and type(SaveMenu.drawPanel) == "function" then SaveMenu.drawPanel = umsetzen(SaveMenu.drawPanel) end
    local okM, MainMenu = G.port_modul("src.ui.gen2.MainMenu")
    if okM and type(MainMenu.drawSavePanel) == "function" then
      MainMenu.drawSavePanel = umsetzen(MainMenu.drawSavePanel)
    end
  end

  -- JA/NEIN-Fenster (home/menu.asm _YesNoBox): die DE-Fassung macht es eine Kachel breiter und rückt das Standard-
  -- fenster (x 14) eine Spalte nach links, sonst ragt „NEIN“ hinaus (Tafel gold center_05: „NEII“).  Der Port hat
  -- die EN-Maße fest – im Theme (ChoiceBox der Skripte) und in den Menüs (Chrome-Kasten 6×5, JA/NEIN bei x+2,
  -- Cursor bei x+1).  Kasten umsetzen, Wörter und Cursor in seinen beiden Zeilen mitnehmen (Rezept ja_nein).
  -- Dazu Aufrufe mit eigener, in DE tieferer Lage: Sichern (SaveMenu/StartMenu, Kasten 0,7 – nur dort) und der
  -- Käferwettbewerb (ContestMenu:drawYesNo, Kasten 14,7 wie viele andere → nur während dieser Zeichenfunktion).
  local function ja_nein_einhaengen(jn)
    if type(jn) ~= "table" or not jn.de_w then return end
    local function lage(x) return x == jn.en_x and jn.de_x or x end
    local _, Theme = G.port_modul("src.ui.Theme")
    local cb = type(Theme) == "table" and Theme.choiceBox
    if type(cb) == "table" and cb.tw == jn.en_w then cb.tx, cb.tw = lage(cb.tx), jn.de_w end
    local _, Chrome = G.port_modul("src.ui.gen2.Chrome")
    local kasten   -- zuletzt gezeichnetes JA/NEIN-Fenster { x EN, x DE, y EN, y DE }
    local innen = false   -- print → printThrough, cursor → cursorThrough: nur einmal umsetzen
    local im_wettbewerb = false
    local pb = Chrome.paletteBox
    Chrome.paletteBox = function(tx, ty, tw, th, ...)
      if tw == jn.en_w and th == 5 then
        local l = jn.sichern
        if not (l and tx == l[1] and ty == l[2]) then l = im_wettbewerb and jn.wettbewerb or nil end
        if l and not (tx == l[1] and ty == l[2]) then l = nil end
        kasten = { tx, lage(l and l[3] or tx), ty, l and l[4] or ty }
        return pb(kasten[2], kasten[4], jn.de_w, th, ...)
      end
      kasten = nil
      return pb(tx, ty, tw, th, ...)
    end
    local function versetzt(tx, ty, abstand)
      if kasten and tx == kasten[1] + abstand and (ty == kasten[3] + 1 or ty == kasten[3] + 3) then
        return kasten[2] + abstand, ty + kasten[4] - kasten[3]
      end
      return tx, ty
    end
    if jn.wettbewerb then
      local okC, ContestMenu = G.port_modul("src.ui.gen2.ContestMenu")
      if okC and type(ContestMenu.drawYesNo) == "function" then
        local alt = ContestMenu.drawYesNo
        ContestMenu.drawYesNo = function(...)
          im_wettbewerb = true
          local erg = { pcall(alt, ...) }
          im_wettbewerb = false
          if not erg[1] then error(erg[2], 0) end
          return (table.unpack or unpack)(erg, 2)
        end
      end
    end
    local function einmal(f, ...)
      innen = true
      local erg = { pcall(f, ...) }
      innen = false
      if not erg[1] then error(erg[2], 0) end
      return (table.unpack or unpack)(erg, 2)
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
      local erg = { pcall(alt, ...) }
      Chrome.box, Chrome.cursor, Chrome.print = box, cur, pr
      if not erg[1] then error(erg[2], 0) end
      return (table.unpack or unpack)(erg, 2)
    end
  end

  -- Pokédex-Optionen: Beschreibung unter jedem Modus (PokedexMenu.OPTION_MODES[i].lines) aus der DE-ROM
  local function dexmodi_einhaengen(dm)
    local _, PM = G.port_modul("src.ui.gen2.PokedexMenu")
    -- Fensterköpfe „ OPTIONEN “ / „ SUCHE “: im DE-Code läuft der Text bis zur Abschluss-Kachel $3C durch; der
    -- Port setzt $3C fest auf Spalte 9 (Länge des englischen „ OPTION “) → hinter den tatsächlichen Text setzen
    local kopf_ende
    local alt_text, alt_tile = PM.text, PM.tile
    PM.text = function(self, str, tx, ty, ...)
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

  local function spielobjekt(game, daten)
    if type(game.oakSpeechData) == "table" then
      einmischen(game.oakSpeechData, daten.oak_speech, nur_texte, "", { n = 0 })
    end
    if type(game.titleData) == "table" then
      einmischen(game.titleData, daten.title, alles, "", { n = 0 })
    end
  end

  -- ---------------------------------------------------------------- Start
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
    puffer_einhaengen(rezept.pf)
    kampfmenue_einhaengen(daten.kampfmenue)
    ep_level_einhaengen()
    namen_einhaengen(daten.namen2, edition)
    pcall(dexmodi_einhaengen, daten.dexmodi)
    pcall(spielstand_einhaengen, rezept.spielstand)
    pcall(boxmenue_einhaengen, rezept.boxmenue)
    pcall(ja_nein_einhaengen, rezept.ja_nein)
    -- Beutel-Untermenü: DE-Gold/-Silber setzen es rechts (x 13) wie Kristall, EN-Gold/-Silber links (Tafel gold
    -- menue_14); der Port wählt die Spalte nach Edition (PackMenu:submenuColumn) → Spalte der DE-ROM
    if type(rezept.beutel_spalte) == "number" then
      pcall(function()
        local _, PackMenu = G.port_modul("src.ui.gen2.PackMenu")
        local spalte = rezept.beutel_spalte
        PackMenu.submenuColumn = function() return spalte end
      end)
    end
    -- Telefon (PokéCom-Liste, Anruffenster): die Namen der Nicht-Trainer führt der Port fest englisch
    -- (src/core/gen2/Phone.lua NON_TRAINER_NAMES und CONTACTS[n].name, Detektor gold_bot „☎ MOM:“) → DE-ROM;
    -- Fang-Tutorial: Spielername im Kampf (src/core/gen2/CatchTutorial.lua DUDE_NAME) → DE-ROM
    if type(daten.npcnamen) == "table" then
      pcall(function()
        local tel = daten.npcnamen.telefon
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
                for _, r in pairs(type(data) == "table" and type(data.gen2PhoneContacts) == "table"
                    and data.gen2PhoneContacts or {}) do
                  local d = type(r) == "table" and de(r.name)
                  if d then r.name = d end
                end
              end)
              local r = alt_use(data, ...)
              pcall(zeilen)
              return r
            end
          end
        end
        local ku = daten.npcnamen.kumpel
        local okc, Tut = G.port_modul("src.core.gen2.CatchTutorial")
        if okc and type(Tut) == "table" and type(ku) == "table" then
          local d = ku[G.pruefsumme(tostring(Tut.DUDE_NAME))]
          if d then Tut.DUDE_NAME = d end
        end
      end)
    end
    bericht.porttexte = G.porttexte_einhaengen(daten.porttexte, daten.portkontexte, daten.rom_text)
    G.romliterale_einhaengen(daten.romliterale)
    -- Taschennamen in „… in die <TASCHE> gesteckt“ (src/script/gen2/Vm.lua POCKET_NAMES über Vm:pocketName): die
    -- Namen setzt der Port per Strings-Platzhalter ein, am Kodierpunkt ist das Wort nicht mehr allein → hier tauschen
    -- (DE-ROM ItemPocketNames, Rezept pl, gen2_taschen.py)
    pcall(function()
      local okv, Vm = G.port_modul("src.script.gen2.Vm")
      if not okv or type(Vm) ~= "table" or type(Vm.pocketName) ~= "function" then return end
      local alt = Vm.pocketName
      Vm.pocketName = function(...)
        local en = alt(...)
        return type(en) == "string" and G.literale_global[G.pruefsumme(en)] or en
      end
    end)
    -- Trainerpass: die DE-ROM setzt den Spielernamen auf Spalte 2 (ihr „NAME/“ ist leer), der Port fest auf
    -- Spalte 7 (src/ui/gen2/TrainerCard.lua drawTopHalf) → in der Zeile 2 die Spalte umsetzen (Rezept trainerpass)
    if type(rezept.trainerpass) == "table" then
      pcall(function()
        local okt, TC = G.port_modul("src.ui.gen2.TrainerCard")
        if not okt or type(TC) ~= "table" or type(TC.print) ~= "function" then return end
        local alt, en_x, de_x = TC.print, rezept.trainerpass.en_x, rezept.trainerpass.de_x
        TC.print = function(self, text, tx, ty, ...)
          if ty == 2 and tx == en_x then tx = de_x end
          return alt(self, text, tx, ty, ...)
        end
      end)
    end
    -- Statuskürzel im Kampf-HUD (src/ui/gen2/BattleState.lua statusTag): ist der Status-Eintrag nach dem Laden der
    -- Mods eine Kopie (nicht mehr dieselbe Tabelle wie Battle.STATUSES), gibt der Port das Label roh zurück, ohne
    -- Strings() → hier nachholen (Katalog: DE-ROM SLF/BRT/PAR/GIF/GFR); Team und Status rufen Strings() selbst auf
    pcall(function()
      local okb, BS = G.port_modul("src.ui.gen2.BattleState")
      if not okb or type(BS) ~= "table" or type(BS.statusTag) ~= "function" then return end
      local S = require("src.core.Strings")
      local alt = BS.statusTag
      BS.statusTag = function(...)
        local r = alt(...)
        if type(r) == "string" then return S(r) end
        return r
      end
    end)
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
    K.daten = daten
    K.aktiv = true
    return true
  end

  return K
end
