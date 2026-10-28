-- Zeichensatz der deutschen Editionen Gold, Silber, Kristall.
--
-- Der deutsche Font belegt einige Codes anders als der englische (geprüft am Font der DE-ROM): wo das Englische
-- japanische Restzeichen und die Ligaturen 'd 'l 'm 'r 's 't 'v hat, stehen Akzentbuchstaben, ß und Apostroph-
-- Folgen; é liegt auf $BC statt $EA, $E4 ist „+“.
-- Diese Tabelle sagt nur, welcher Code welches Zeichen ist – die Glyphen kommen aus der ROM des Spielers.
local Z = {}

Z.CODES = {
  [0xBA] = "à", [0xBB] = "è", [0xBC] = "é", [0xBD] = "ù", [0xBE] = "ß", [0xBF] = "ç",
  [0xC0] = "Ä", [0xC1] = "Ö", [0xC2] = "Ü", [0xC3] = "ä", [0xC4] = "ö", [0xC5] = "ü",
  [0xC6] = "ë", [0xC7] = "ï", [0xC8] = "â", [0xC9] = "ô", [0xCA] = "û", [0xCB] = "ê", [0xCC] = "î",
  [0xD4] = "c'", [0xD5] = "d'", [0xD6] = "j'", [0xD7] = "l'", [0xD8] = "m'", [0xD9] = "n'", [0xDA] = "p'",
  [0xDB] = "s'", [0xDC] = "'s", [0xDD] = "t'", [0xDE] = "u'", [0xDF] = "y'",
  [0xE4] = "+",
}

-- Codes, deren englische Belegung im deutschen Font nicht gilt (Ligaturen 'd 'l 'm 'r 's 't 'v auf $D0–$D6,
-- é auf $EA, japanische Restzeichen auf $BA–$BF/$C6–$CF/$D7–$DF)
local FREI = {}
for c = 0xBA, 0xBF do FREI[c] = true end
for c = 0xC6, 0xDF do FREI[c] = true end
FREI[0xE4] = true
FREI[0xEA] = true
Z.FREI = FREI

-- Lesen: $EA bleibt „é“ – der deutsche Font hat dort unverändert ein é (dieselbe Glyphe wie $BC), und Gold/Silber DE
-- benutzen es (Team-Rocket-Eid „Die Pok$EAmon dienen …“).  Geschrieben wird é weiter als $BC (fontCharmap).
local LESEN = { [0xEA] = true }

function Z.anwenden(manifest)
  local cm = {}
  for k, v in pairs(manifest.charmap or {}) do
    if not FREI[tonumber(k)] or LESEN[tonumber(k)] then cm[k] = v end
  end
  for code, z in pairs(Z.CODES) do cm[tostring(code)] = z end
  manifest.charmap = cm
  local neu = {}
  for _, e in ipairs(manifest.fontCharmap or {}) do
    if not FREI[e.code] and e.seq ~= "é" then neu[#neu + 1] = e end
  end
  for code, z in pairs(Z.CODES) do neu[#neu + 1] = { code = code, seq = z } end
  table.sort(neu, function(a, b) if a.code ~= b.code then return a.code < b.code end return a.seq < b.seq end)
  manifest.fontCharmap = neu
end

return Z
