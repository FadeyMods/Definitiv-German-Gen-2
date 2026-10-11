-- Alle Dialogtexte aus der DE-ROM:
--   mod.content.text      Schluessel "bank:adresse" (Skript-Texte, wie der Port sie beim Import ablegt)
--   mod.content.rom_text  Schluessel = Label (Texte, die der Port ueber ihren Namen holt)
return function(W)
  local mod, T = W.mod, W.T
  W.apply("text", W.R.text, function(k, parts) mod.content.text:override(k, T(parts)) end)
  W.apply("rom_text", W.R.rom_text, function(k, parts) mod.content.rom_text:override(k, T(parts)) end)
end
