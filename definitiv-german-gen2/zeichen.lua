-- Zeichentabelle der DE-ROM (Byte -> Zeichen, wie die Schrift des Ports sie kennt).
return function(W)
  for code, zeichen in pairs(W.R.cm or {}) do W.CM[code] = zeichen end
end
