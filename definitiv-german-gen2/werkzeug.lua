-- Gemeinsame Helfer aller Bausteine.  Gibt W zurueck (oder nil, wenn die deutsche ROM fehlt).
--   W.R          Rezept (alle Bausteine zusammen, vor dem ersten Baustein geladen)
--   W.T(teile)   Text aus dem Rezept: Literal (Steuerzeichen, Ziffern) oder {Adresse, Anzahl Bytes} der DE-ROM
--   W.apply      Abschnitt anwenden, Fehler je Eintrag zaehlen
--   W.umgelegt   zeichnet mit umgelegten Chrome-Koordinaten (nur innerhalb eines Aufrufs)
--   W.K          DE-Koordinate einer Textstelle (R.coords)
--   W.gfxData    Daten, die der Grafik-Extraktor auf der DE-ROM liefert (z. B. Diplom-Kachelkarte)
return function(mod)
  local GameVersion = require("src.core.GameVersion")
  local log = mod.log
  local ver = GameVersion.get()
  -- Regel: jede Edition holt alles nur aus ihrem deutschen Gegenstueck
  local IMPORT = { gold = "gold_de", silver = "silber_de", crystal = "kristall_de" }
  local importId = IMPORT[ver]
  if not importId then
    log:warn("Deutsch Gen 2: unbekannte Edition %s", tostring(ver))
    return nil
  end
  local info, ierr = mod.imports:info(importId)
  if not info then
    log:warn("Deutsch Gen 2: deutsche ROM fuer %s fehlt (%s)", ver, tostring(ierr))
    return nil
  end
  -- 2 MiB ROM: in Stuecken lesen (Lesegrenze je Aufruf)
  local chunks, pos = {}, 0
  while pos < info.size do
    local n = math.min(4 * 1024 * 1024, info.size - pos)
    local part, rerr = mod.imports:read(importId, pos, n)
    if not part then
      log:warn("Deutsch Gen 2: ROM nicht lesbar: %s", tostring(rerr))
      return nil
    end
    chunks[#chunks + 1] = part
    pos = pos + #part
    if #part == 0 then break end
  end
  local rom = table.concat(chunks)

  local W = { mod = mod, log = log, ver = ver, rom = rom, info = info, R = {}, gfxData = {},
              Assets = require("src.render.Assets") }
  local byte, concat = string.byte, table.concat

  -- ------------------------------------------------------------ alle Rezepte zuerst
  for _, baustein in ipairs({ "zeichen", "grafik", "dialoge", "daten", "port_texte", "layout" }) do
    local name = "rezept_" .. ver .. "_" .. baustein .. ".lua"
    local src = mod:read(name)
    if src then
      local chunk, cerr = (loadstring or load)(src, "@" .. name)
      if not chunk then
        log:warn("Deutsch Gen 2: Rezept fehlerhaft (%s): %s", name, tostring(cerr))
        return nil
      end
      for k, v in pairs(chunk() or {}) do W.R[k] = v end
    end
  end
  local R = W.R
  W.CM = {}
  W.L = R.layout or {}

  -- ------------------------------------------------------------ Text aus der DE-ROM
  W.T = function(parts)
    local out, CM = {}, W.CM
    for i = 1, #parts do
      local p = parts[i]
      if type(p) == "string" then
        out[#out + 1] = p
      else
        for k = p[1] + 1, p[1] + p[2] do out[#out + 1] = CM[byte(rom, k)] end
      end
    end
    return concat(out)
  end

  -- ------------------------------------------------------------ Abschnitte anwenden, zaehlen
  W.counts, W.failed, W.firstErr = {}, {}, {}
  W.apply = function(section, tbl, fn)
    local n, f = 0, 0
    for k, v in pairs(tbl or {}) do
      local ok, e = pcall(fn, k, v)
      if ok then n = n + 1 else
        f = f + 1
        if not W.firstErr[section] then W.firstErr[section] = tostring(k) .. ": " .. tostring(e) end
      end
    end
    W.counts[section], W.failed[section] = n, f
  end

  -- ------------------------------------------------------------ Anordnung wie in der DE-ROM
  -- Der Port hat Boxlage und Spalten der EN-Menues fest im Code.  umgelegt() setzt Chrome-Aufrufe NUR
  -- waehrend eines Zeichenaufrufs um und stellt danach alles wieder her; Aufrufe, die nicht genau die
  -- EN-Werte treffen, laufen unveraendert durch.
  W.umgelegt = function(regeln, fn, ...)
    -- Regeln: box/textbox/palbox(x, y, w, h) -> x, y, w, h;  zeiger/druck(x, y) -> x[, y]
    -- (text(t, x, y) -> t: nur zusammen mit druck, vor der Verschiebung)
    -- (Chrome.cursor / Chrome.print);  spalte(x, y) -> x[, y] (printThrough, cursorThrough)
    local Chrome = require("src.ui.gen2.Chrome")
    local alt = { box = Chrome.box, textbox = Chrome.textbox, paletteBox = Chrome.paletteBox,
                  cursorThrough = Chrome.cursorThrough, printThrough = Chrome.printThrough,
                  print = Chrome.print, cursor = Chrome.cursor }
    local function xy(f, x, y) local nx, ny = f(x, y); return nx, ny or y end
    if regeln.zeiger then
      Chrome.cursor = function(x, y, ...) local nx, ny = xy(regeln.zeiger, x, y); return alt.cursor(nx, ny, ...) end
    end
    if regeln.druck then
      Chrome.print = function(t, x, y, ...)
        if regeln.text then t = regeln.text(t, x, y) end
        local nx, ny = xy(regeln.druck, x, y)
        return alt.print(t, nx, ny, ...)
      end
    end
    for name, feld in pairs({ box = "box", textbox = "textbox", palbox = "paletteBox" }) do
      if regeln[name] and alt[feld] then
        Chrome[feld] = function(x, y, w, h, ...) x, y, w, h = regeln[name](x, y, w, h); return alt[feld](x, y, w, h, ...) end
      end
    end
    if regeln.spalte then
      Chrome.cursorThrough = function(x, y, ...)
        local nx, ny = xy(regeln.spalte, x + 1, y)
        return alt.cursorThrough(nx - 1, ny, ...)
      end
      Chrome.printThrough = function(t, x, y, ...)
        local nx, ny = xy(regeln.spalte, x, y)
        return alt.printThrough(t, nx, ny, ...)
      end
    end
    local ok, e = pcall(fn, ...)
    for k, v in pairs(alt) do Chrome[k] = v end
    if not ok then error(e, 0) end
    return e
  end

  -- DE-Koordinate einer Textstelle (R.coords: Funktion -> {en = {x, y}, de = {x, y}}) oder nil
  W.K = function(fn, x, y)
    for _, e in ipairs((R.coords or {})[fn] or {}) do
      if e.en[1] == x and e.en[2] == y then return e.de[1], e.de[2] end
    end
    return nil
  end

  -- ------------------------------------------------------------ Bausteine
  -- ------------------------------------------------------------ Pruefsummen statt Spieltext
  -- Der Mod enthaelt keine englischen Spieltexte, auch nicht als Suchschluessel.  Rezepte und Kataloge
  -- fuehren Texte des Ports als Pruefsumme "~" .. FNV-1a-32 (8 Hex) .. Laenge (4 Hex); hier wird die
  -- Pruefsumme des englischen Port-Texts zur Laufzeit gebildet.  Gegenstueck fuer die Werkzeuge:
  -- Test/werkzeug/pruefsumme.py (muss dieselben Werte liefern).
  local bxor, sbyte, sformat = bit.bxor, string.byte, string.format
  local summen = {}
  W.pruefsumme = function(s)
    local h = summen[s]
    if h then return h end
    local x = 2166136261
    for i = 1, #s do
      x = bxor(x, sbyte(s, i)) % 4294967296
      x = (x * 403 + (x % 256) * 16777216) % 4294967296
    end
    h = sformat("~%08x%04x", x, #s % 65536)
    summen[s] = h
    return h
  end
  -- tab[text] ueber die Pruefsumme (Klartext-Schluessel bleiben moeglich: Port-Bezeichner, Labels)
  W.nachText = function(tab, s)
    if type(tab) ~= "table" or type(s) ~= "string" then return nil end
    local v = tab[s]
    if v == nil then v = tab[W.pruefsumme(s)] end
    return v
  end
  -- Uebersetzungs-Katalog des Ports (src/core/Strings.lua liest catalog[quelle]) und data.text: Eintraege
  -- stehen unter der Pruefsumme; ein __index findet sie ueber den englischen Text (auch "kontext|quelle").
  W.katalogMitPruefsummen = function()
    pcall(function()
      local Strings = require("src.core.Strings")
      if Strings._deutschLoad then return end
      Strings._deutschLoad = Strings.load
      -- data.strings (Katalog) und data.text (Gen 1: Klartext-Saetze der Port-Skripte, show_text sucht sie
      -- dort) bekommen denselben Pruefsummen-Zugriff; beide sind nach dem Zusammenfuehren der Mods fertig
      local function mitPruefsummen(t)
        if type(t) ~= "table" or getmetatable(t) then return end
        -- Treffer werden in einer eigenen Tabelle gemerkt, nicht in t (der Port durchlaeuft t mit pairs)
        local fehlt, gefunden = {}, {}
        setmetatable(t, { __index = function(tab, k)
          if type(k) ~= "string" or fehlt[k] or k:sub(1, 1) == "~" then return nil end
          local v = gefunden[k]
          if v ~= nil then return v end
          v = rawget(tab, W.pruefsumme(k))
          if v == nil then fehlt[k] = true else gefunden[k] = v end
          return v
        end })
      end
      Strings.load = function(data, ...)
        if type(data) == "table" then
          mitPruefsummen(data.strings)
          mitPruefsummen(data.text)
        end
        return Strings._deutschLoad(data, ...)
      end
    end)
  end
  W.katalogMitPruefsummen()

  W.baustein = function(name)
    local src = mod:read(name .. ".lua")
    local fn, err = (loadstring or load)(src or "", "@" .. name .. ".lua")
    if not fn then
      log:warn("Deutsch Gen 2: %s fehlerhaft: %s", name, tostring(err))
      return
    end
    local ok, e = pcall(function() fn()(W) end)
    if not ok then log:warn("Deutsch Gen 2: %s: %s", name, tostring(e)) end
  end

  return W
end
