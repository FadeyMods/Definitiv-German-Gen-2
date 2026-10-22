-- Definitiv German Gen 2  (Gold, Silber, Kristall)
--
-- Dieser Mod enthält keine Texte oder Grafiken der Spiele und keine englischen Texte als Suchschlüssel.  Er bringt
-- nur Rezepte mit (Adressen in der deutschen ROM, Texte des Ports nur als Prüfsumme) und liest beim Start die
-- deutsche ROM der laufenden Edition, die im Launcher unter MODS importiert wurde.
--
--   kern.lua          deutsche ROM → Gen-2-Extraktor des Ports → Texte, Namen, Pokédex, Schrift, Bilder
--   zeichen.lua       Zeichensatz der deutschen Editionen (welcher Code welches Zeichen ist)
--   rezept_<ed>.lua   DE-Adressen der Port-Symbole und der Skripttexte je Edition (Test/werkzeug/rezept_gen2.py)
--   zusatz.lua        Port-Zusätze (eigene deutsche Texte für Port-Texte ohne ROM-Gegenstück)
local VERSION = "1.0.3"

return function(mod)
  local quelle = mod:read("kern.lua")
  local chunk, err = (loadstring or load)(quelle or "", "@kern.lua")
  if not chunk then
    mod.log:warn("Definitiv German: kern.lua fehlerhaft: %s", tostring(err))
    return
  end
  local K = chunk()(mod, VERSION)
  pcall(function()
    mod.exports = mod.exports or {}
    mod.exports.deutsch = function() return K.aktiv == true end
  end)
  local ok, fehler = pcall(K.start)
  if not ok then mod.log:warn("Definitiv German: %s", tostring(fehler)) end
end
