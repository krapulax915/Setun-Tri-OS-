# Setun Tri OS v0.1 — az első modern ternáris operációs rendszer (tervcsomag)

Ez a csomag a **GLM modellnek** szól végrehajtásra. Sorrend:
1. Olvasd el: `GLM_MASTER_PROMPT.md`
2. Majd `docs/01..07` sorrendben.
3. Dolgozz milestone-onként (`docs/07_MILESTONES_TODO.md`), minden milestone végén teszt + commit.

## Alapötlet (röviden)
A ternáris CPU még nem létezik, ezért az OS fejlesztése **virtuális ternáris gépen** (emulátoron)
indul, az ISA-t pedig úgy tervezzük, hogy később a valódi chipre (6-trites ALU, hexagonális
rács, közvetlenül elérhető memória) portolható legyen. Az emulátor közben **lokalitási
statisztikát** is gyűjt, ami a chip-tervezést segíti (milyen helyi a forgalom).

## Fő döntések
- Kiegyensúlyozott ternáris (-1,0,+1), tryte = 6 trit (729 érték), szó = 18 trit.
- Oldal = 729 tryte (3^6); háromszintű laptábla, szintenként 6 trit index = 18 trites cím.
- Mikrokernel, capability-alapú védelem (háromállapotú jogok), szinkron IPC.
- Háromutas összehasonlítás és elágazás (nincs flag-regiszter).
- Referencia-emulátor Python, később opcionális gyors Rust emulátor.
- Lemezkép: 5 trit / bájt csomagolás a hoszt oldalon.
