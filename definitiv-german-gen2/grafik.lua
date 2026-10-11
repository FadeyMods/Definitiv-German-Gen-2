-- Bilder aus der DE-ROM: die Grafik-Stufen des Port-Extraktors laufen auf der deutschen ROM (Assets.compose);
-- deutsche Schriftseite.
return function(W)
  local mod, R, rom, T, apply, log, ver = W.mod, W.R, W.rom, W.T, W.apply, W.log, W.ver
  local Assets, CM, info, gfxData = W.Assets, W.CM, W.info, W.gfxData
  local counts, failed, firstErr = W.counts, W.failed, W.firstErr
  local L, umgelegt, K = W.L, W.umgelegt, W.K
  local byte, concat, floor = string.byte, table.concat, math.floor
  -- ------------------------------------------------------------ Grafik
  local SH = { 1, 170 / 255, 85 / 255, 0 }
  local function bit(v, b) return floor(v / 2 ^ b) % 2 end

  local function decodeTiles(off, len, w, h, bpp, transparent)
    local img = love.image.newImageData(w, h)
    local per = w / 8
    local function rb(i) if i < len then return byte(rom, off + i + 1) end return 0 end
    for t = 0, (w / 8) * (h / 8) - 1 do
      local tx, ty = (t % per) * 8, floor(t / per) * 8
      for y = 0, 7 do
        if bpp == 1 then
          local row = rb(t * 8 + y)
          for x = 0, 7 do
            local f = bit(row, 7 - x)
            local v = (f == 1) and 0 or 1
            img:setPixel(tx + x, ty + y, v, v, v, (transparent and f == 0) and 0 or 1)
          end
        else
          local lo, hi = rb(t * 16 + y * 2), rb(t * 16 + y * 2 + 1)
          for x = 0, 7 do
            local s = bit(hi, 7 - x) * 2 + bit(lo, 7 - x)
            local v = SH[s + 1]
            img:setPixel(tx + x, ty + y, v, v, v, (transparent and s == 0) and 0 or 1)
          end
        end
      end
    end
    return img
  end

  Assets._deutschGen2 = Assets._deutschGen2 or {}
  for path in pairs(Assets._deutschGen2) do Assets.compose(path, nil) end
  Assets._deutschGen2 = {}
  local function compose(path, build)
    local cached
    Assets.compose(path, function()
      cached = cached or build()
      return cached
    end)
    Assets._deutschGen2[path] = true
  end


  -- Kristall-Intro, Icognito-Szene: DE-Grafik (lz3) wie CrystalMovie.lua writeSheet (16 Kacheln breit, 32 Kacheln)
  if R.introIcognito then
    compose("assets/generated/intro/crystal_unowns_tiles.png", function()
      local Rom = require("src.import.Rom")
      local IW = require("src.import.ImageWriter")
      local raw = Rom.decompressLz3(rom:sub(R.introIcognito.gfx + 1, R.introIcognito.gfx + 0x4000))
      while #raw > 32 * 16 do table.remove(raw) end
      while #raw < 32 * 16 do raw[#raw + 1] = 0 end
      return IW.decode2bpp(raw, 128, 16, true)
    end)
  end

  -- ------------------------------------------------------------ Schrift
  if R.font then
    local path = "definitiv-german-gen2/schrift_" .. ver .. ".png"
    compose(path, function() return decodeTiles(R.font.off, 128 * 8, 128, 64, 1, true) end)
    local page = { image = path, base = 0x100, glyphsPerRow = 16, charmap = {} }
    for seq, code in pairs(R.font.chars) do page.charmap[#page.charmap + 1] = { seq = seq, code = code } end
    local ok, e = pcall(function() mod.content.font:register("deutsch", page) end)
    if not ok then log:warn("Deutsch Gen 2: Schrift: %s", tostring(e)) end
  end

  -- ------------------------------------------------------------ Grafiken
  -- Die Grafik-Stufen des Engine-Extraktors laufen auf DEINER deutschen ROM, mit den deutschen
  -- Adressen aus dem Rezept (nur Bank/Adresse je Symbol).  Die Bilder landen per Assets.compose
  -- im Speicher; nichts wird auf die Platte geschrieben.
  local gfxMissing = {}
  if R.gfx then
    local ok, err = pcall(function()
      local Ex = require("src.import.RomExtractorGen2")
      local man = require("src.import.RomManifest").decode(ver)
      local symbols = setmetatable({}, { __index = function(_, name)
        -- nur echte Luecken melden (Symbol gibt es in dieser Edition)
        if man.symbols and man.symbols[name] then gfxMissing[#gfxMissing + 1] = name end
        return nil
      end })
      for name, loc in pairs(R.gfx.symbols) do symbols[name] = { loc[1], loc[2] } end
      local m2 = setmetatable({ symbols = symbols }, { __index = man })
      local ex = Ex.new(rom, m2, nil, nil)
      ex.symbols = symbols
      local images = {}
      ex.save = function(_, image, relative) images["assets/generated/" .. relative] = image end
      ex.write = function(_, name, value) gfxData[name] = value end
      -- DE-Grafiken sind teils anders lang komprimiert: auf die Bildgroesse kuerzen/auffuellen
      local origW2 = ex.write2bpp
      ex.write2bpp = function(self, raw, width, height, relative, transparent)
        local want = width * height / 4
        if type(raw) == "table" then
          -- Luecken mit 0 fuellen (Slots2LZ: nach ImageWriter.deinterleave fehlen in DE einzelne Bytes,
          -- sonst bricht die ganze Stufe extractMenuGfx ab und die folgenden Menuegrafiken bleiben englisch)
          local fehlend = 0
          for i = 1, want do
            if raw[i] == nil then raw[i] = 0; fehlend = fehlend + 1 end
          end
          for i = #raw, want + 1, -1 do raw[i] = nil end
          if fehlend > 0 then
            log:info("Deutsch Gen 2: %s: %d Bytes aufgefuellt", tostring(relative), fehlend)
          end
        end
        return origW2(self, raw, width, height, relative, transparent)
      end
      ex.beginStage = function() end
      ex.tick = function() end
      local IW = require("src.import.ImageWriter")
      local origSave = IW.save
      IW.save = function(image, path) images[path] = image end
      for _, stage in ipairs(R.gfx.stages) do
        local okS, e = pcall(ex[stage], ex)
        if not okS then log:warn("Deutsch Gen 2: Grafikstufe %s: %s", stage, tostring(e)) end
      end
      IW.save = origSave
      -- Titel: Farbzone des Editions-Schriftzugs. Der Extraktor faerbt fest Zeile 6, Spalten 5-14
      -- (EN FillTitleScreenPals: 10 Spalten); die DE-ROM setzt dort 11 Spalten -> die Zone aus
      -- der DE-ROM lesen und ueberzaehlige Kacheln mit denselben Farben wie die Zone einfaerben
      local ts = images["assets/generated/title/title_screen.png"]
      local tg = images["assets/generated/title/title_screen_gray.png"]
      if ts and tg and (ver == "gold" or ver == "silver") then
        pcall(function()
          local s, _, lo, hi, cols = rom:find("!(.)(.)\1(.)\1>\3\205")
          if not s then return end
          local off = (lo:byte() + hi:byte() * 256) % 1024
          local c0, row, n = off % 32, math.floor(off / 32), cols:byte()
          if row ~= 6 or (c0 == 5 and n == 10) then return end
          local map = {}
          for y = 48, 55 do
            for x = 40, 119 do
              local g = tg:getPixel(x, y)
              map[math.floor(g * 255 + 0.5)] = { ts:getPixel(x, y) }
            end
          end
          for c = c0, c0 + n - 1 do
            if c < 5 or c > 14 then
              for y = row * 8, row * 8 + 7 do
                for x = c * 8, c * 8 + 7 do
                  local _, _, _, a = ts:getPixel(x, y)
                  local col = map[math.floor(tg:getPixel(x, y) * 255 + 0.5)]
                  if col and a > 0 then ts:setPixel(x, y, col[1], col[2], col[3], col[4]) end
                end
              end
            end
          end
          log:info("Deutsch Gen 2: Titel-Farbzone Zeile %d, Spalten %d-%d", row, c0, c0 + n - 1)
        end)
      end
      local n = 0
      for path, img in pairs(images) do
        local skip = false
        for _, frag in ipairs(R.gfx.skip or {}) do
          if path:find(frag, 1, true) then skip = true end
        end
        if not skip then
          compose(path, function() return img end)
          n = n + 1
        end
      end
      counts.gfx = n
    end)
    if not ok then log:warn("Deutsch Gen 2: Grafiken: %s", tostring(err)) end
    if #gfxMissing > 0 then log:warn("Deutsch Gen 2: Symbole ohne DE-Adresse: %s", concat(gfxMissing, ", ")) end
  end

end
