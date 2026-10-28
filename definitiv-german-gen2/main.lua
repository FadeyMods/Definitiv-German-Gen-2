-- Definitiv German Gen 2 (Gold, Silber, Kristall) – Einstieg
--
-- Der Mod enthält keine Texte oder Grafiken der Spiele und keine englischen Texte als Suchschlüssel.  Er bringt nur
-- Rezepte mit (Adressen in der deutschen ROM, Port-Texte nur als Prüfsumme) und liest beim Start die deutsche ROM
-- der laufenden Edition, die im Launcher unter MODS beim Mod abgelegt wurde.
--
--   kern.lua          deutsche ROM lesen (Gen-2-Extraktor des Ports), Inhalte übernehmen, Anzeige anpassen
--   gemeinsam.lua     Bausteine aller drei Definitiv-German-Mods (in Gen 1, 2 und 3 byte-gleich)
--   zeichen.lua       Zeichensatz der deutschen Editionen (welcher Code welches Zeichen ist)
--   rezept_<ed>.lua   DE-Adressen und Zuordnungen je Edition (von Hand gepflegt)
--   zusatz.lua        deutsche Texte für Port-Texte ohne Gegenstück in der ROM (von Hand gepflegt)
local VERSION = "1.0.4"

return function(mod)
  local chunk, err = (loadstring or load)(mod:read("kern.lua") or "", "@kern.lua")
  if not chunk then
    mod.log:warn("Definitiv German: kern.lua fehlerhaft: %s", tostring(err))
    return
  end
  local K = chunk()(mod, VERSION)
  -- exports muss beim Start eine Tabelle sein: gemeinsam.lua trägt dort api und text ein
  pcall(function() mod.exports = mod.exports or {} end)
  local ok, fehler = pcall(K.start)
  if not ok then mod.log:warn("Definitiv German: %s", tostring(fehler)) end
  -- gemeinsam.lua setzt exports.deutsch = true; die Schnittstelle dieses Mods ist eine Funktion
  pcall(function() mod.exports.deutsch = function() return K.aktiv == true end end)
end
