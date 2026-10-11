-- 📀🇩🇪 Definitiv German 💬✅ Gen 2  (Gold, Silber, Kristall)
--
-- Dieser Mod enthaelt KEINE Texte oder Grafiken der Spiele.  Er bringt nur Rezepte mit
-- (Adressen in der deutschen ROM) und liest beim Start die deutsche ROM der laufenden Edition,
-- die du im Launcher importiert hast -- immer genau das Gegenstueck:
--   Gold -> Goldene Edition, Silber -> Silberne Edition, Kristall -> Kristall-Edition.
--
-- Aufbau (jeder Baustein hat sein eigenes Rezept rezept_<edition>_<baustein>.lua):
--   werkzeug.lua    Edition, deutsche ROM, alle Rezepte, gemeinsame Helfer
--   zeichen.lua     Zeichentabelle der DE-ROM
--   grafik.lua      Bilder (Grafik-Extraktor des Ports auf der DE-ROM) und Schrift
--   dialoge.lua     alle Dialogtexte und ROM-Texte                    (mod.content.text / rom_text)
--   daten.lua       Namen und Daten in den Importdaten, Pokedex, Ereignistabellen, Skript-Menues, Dekorationen
--   port_texte.lua  feste Texte des Ports (mod.content.strings) und Menues
--   layout.lua      Kaesten und Positionen wie in der DE-ROM (mit den Texten, die nur dort stehen)
return function(mod)
  local quelle = mod:read("werkzeug.lua")
  local chunk, err = (loadstring or load)(quelle or "", "@werkzeug.lua")
  if not chunk then
    mod.log:warn("Deutsch Gen 2: werkzeug.lua fehlerhaft: %s", tostring(err))
    return
  end
  local W = chunk()(mod)
  if not W then return end
  for _, baustein in ipairs({ "zeichen", "grafik", "dialoge", "daten", "port_texte", "layout" }) do
    W.baustein(baustein)
  end
end
