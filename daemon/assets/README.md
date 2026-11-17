# Fonts of Alero Island

`island-Regular.ttf`, `island-Medium.ttf` and `island-Bold.ttf` are static, Latin-only instances (weights 400, 520
and 700) of **Google Sans Flex** (`app/assets/fonts/GoogleSansFlex.ttf`), copyright 2015 The Google Sans Flex Authors,
licensed under the SIL Open Font License 1.1 (`app/assets/fonts/OFL.txt`). They are modified versions: pinned with
`fonttools varLib.instancer` (opsz=16, wdth=100, ROND=0, slnt=0) and subset with `pyftsubset`:

    fonttools varLib.instancer GoogleSansFlex.ttf wght=400 opsz=16 wdth=100 ROND=0 slnt=0 -o inst.ttf
    pyftsubset inst.ttf --unicodes="U+0020-007E,U+00A0-024F,U+0300-036F,U+2000-206F,U+20A0-20CF,U+2190-21FF,U+2212,U+2022,U+2026,U+00B7" \
      --layout-features='' --no-hinting --desubroutinize --output-file=island-Regular.ttf

Text in other scripts (CJK, emoji, symbols) falls back to the system's fonts at run time.
