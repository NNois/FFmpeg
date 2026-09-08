# libvpx (VP8 / VP9) — alpha et sélection automatique du pixel format

## Symptôme
adConvert / Flocon, preset VP9 avec la case Pixel Format décochée, source avec
alpha : l'encodage échoue à l'ouverture de l'encodeur.

```
[libvpx-vp9] Pixel format 'gbrap' is not widely supported. Use -strict experimental
to use it anyway, or use 'yuva420p' pixel format instead.
Error while opening encoder - maybe incorrect parameters such as bit_rate, rate, width or height.
```

Le même job passe dès qu'on force `-pix_fmt yuva420p`. H.265 (x265 alpha) n'est
pas touché, VP8 non plus.

## Cause (upstream FFmpeg 8.1, pas le fork)
Commit `33b215d155` "avcodec/libvpxenc: add experimental support for alpha pixel
formats other than YUV 4:2:0" (Marton Balint, fév. 2026) ajoute à la liste
annoncée par `libvpx-vp9` les formats yuva422p, yuva444p, gbrap, yuva420p10,
yuva422p10, yuva444p10, yuva444p12, gbrap10, gbrap12. Mais `vpx_init()` refuse
tout format alpha autre que yuva420p si `strict_std_compliance` n'est pas à
`experimental`.

Quand le pixel format n'est pas imposé, `fftools/ffmpeg_mux_init.c`
(`choose_pixel_fmt`) prend dans cette liste le format le plus proche de la
source. Résultat :

| Source | Format choisi automatiquement | Résultat |
|--------|-------------------------------|----------|
| rgba (sortie de `sr_rtx`, PNG/TGA, HAP Alpha décodé) | gbrap | refusé |
| yuva444p / yuva444p10 (ProRes 4444, HEVC alpha 4:4:4) | yuva444p / yuva444p10 | refusé |
| yuva420p (VP8/VP9 alpha, HEVC alpha 4:2:0) | yuva420p | OK |

C'est le bug "de longue date" avec les sources 4:4:4, rendu systématique par le
filtre `sr_rtx` qui sort en rgba.

## Fix dans le fork
`libavcodec/libvpxenc.c` : `vp9_get_supported_config` renvoie deux listes
`vp9_pix_fmts_*_strict` (sans les formats alpha expérimentaux) tant que
`avctx->strict_std_compliance > FF_COMPLIANCE_EXPERIMENTAL`. L'auto-sélection
retombe donc sur `yuva420p`, comme avant le commit upstream. Avec
`-strict experimental` la liste complète reste disponible et les formats alpha
4:2:2 / 4:4:4 / RGB restent encodables.

Le CLI applique les options d'encodeur (`-strict`) au contexte avant
`new_stream_video` / `ost_bind_filter`, donc le choix est cohérent dans les deux
chemins (pix_fmt explicite et automatique).

## Vérification après build
```bash
# auto-sélection depuis du rgba : doit sortir yuva420p sans erreur
ffmpeg -f lavfi -i "color=red@0.5:size=64x64:rate=25:duration=0.2,format=rgba" -c:v libvpx-vp9 -y /c/tmp/t.webm
ffprobe -v error -select_streams v -show_entries stream=pix_fmt /c/tmp/t.webm   # pix_fmt=yuva420p

# les formats expérimentaux restent accessibles explicitement
ffmpeg -f lavfi -i "color=red@0.5:size=64x64:rate=25:duration=0.2,format=rgba" -strict experimental -pix_fmt gbrap -c:v libvpx-vp9 -y /c/tmp/t2.webm
```

## À ne pas confondre : "Failed to initialize encoder: ABI version mismatch"
Autre erreur libvpx vue le même jour, sans rapport avec le pixel format :
FFmpeg compilé contre libvpx 1.17.0 (paquet MSYS2 upgradé par
`build-msys-install-dependencies.sh`) mais chargeant un vieux `libvpx-1.dll`
1.15.2 resté dans le bundle (`tools/ffmpeg` de nnTools, `libs/ffmpeg` de
Flocon). Corrigé dans `build-msys-shared.sh` et
`build-msys-copy-with-dlls-shared.sh` : `ldd` avec PATH forcé sur
`/mingw64/bin` et remplacement des DLL qui diffèrent. Après tout upgrade pacman :
rebuild puis redéployer les bundles.
