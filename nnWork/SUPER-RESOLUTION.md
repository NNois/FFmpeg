# Super-résolution (upscale IA) avec alpha

Deux voies sont intégrées dans le build `build-msys-shared.sh` :

| Voie | Filtre | GPU | Alpha | Qualité | Vitesse |
|------|--------|-----|-------|---------|---------|
| libplacebo + shaders CNN (FSRCNNX, Anime4K, RAVU, NNEDI3) | `libplacebo` | Vulkan, tout vendeur | natif (`yuva420p` → `yuva420p`) | bonne, selon shader | temps réel en 1080p→4K |
| NVIDIA RTX Video Super Resolution (RTX Video SDK) | `sr_rtx` | RTX 20xx+ uniquement | géré par le filtre (2e passe) | la meilleure sur vidéo réelle | quelques dizaines d'i/s (aller-retour RAM↔GPU) |

Les filtres upstream `sr` / `dnn_processing` (TensorFlow, OpenVINO, Torch) sont
laissés désactivés : aucun backend n'est utilisable en MSYS2, les modèles
SRCNN/ESPCN de 2016 sont dépassés, et ils ne traitent ni l'alpha ni la chroma.

## 1. libplacebo + shaders CNN

### Build
```bash
pacman -S mingw-w64-x86_64-libplacebo   # ou ./build-msys-install-dependencies.sh
./build-msys-prepare-shaders.sh          # télécharge les shaders dans thirdparty/shaders/
./build-msys-shared.sh                   # détecte libplacebo → --enable-libplacebo, copie bin/shaders/
```
Vérif : `ffmpeg -filters | grep libplacebo`.

### Shaders livrés (`bin/shaders/`)
| Fichier | Usage | Notes |
|---------|-------|-------|
| `FSRCNNX_x2_16-0-4-1.glsl` | vidéo réelle x2, meilleure qualité | hook LUMA, lourd (16 filtres) |
| `FSRCNNX_x2_8-0-4-1.glsl` | vidéo réelle x2, plus léger | hook LUMA |
| `Anime4K/Anime4K_Upscale_CNN_x2_*.glsl` | graphisme, motion design, cartoon | S/M/L/VL/UL = taille du réseau |
| `Anime4K/Anime4K_Restore_CNN_*.glsl` | à enchaîner avant l'upscale | réduit compression / ringing |
| `ravu-zoom-r3.hook` | ratio quelconque, cheap | pas un CNN, apprentissage local |
| `ravu-r3.hook` / `ravu-lite-r3.hook` | x2 cheap | |
| `nnedi3-nns32-win8x4.hook` | x2 très propre, lent | doubler luma type nnedi3 |

Un shader ne s'applique que dans son ratio natif (x2 pour FSRCNNX/Anime4K/NNEDI3),
libplacebo termine ensuite avec `upscaler` (défaut `spline36`, sinon
`ewa_lanczos`). Pour du x4 : deux passes, ou `ravu-zoom`.

Chaîner plusieurs shaders : `custom_shader_path` n'accepte qu'un fichier, donc
concaténer (format mpv .hook, l'ordre = l'ordre d'application) :
```bash
cat shaders/Anime4K/Anime4K_Clamp_Highlights.glsl \
    shaders/Anime4K/Anime4K_Restore_CNN_M.glsl \
    shaders/Anime4K/Anime4K_Upscale_CNN_x2_M.glsl > shaders/anime4k_modeA.glsl
```

### Usage avec alpha
libplacebo gère l'alpha nativement : entrée `yuva420p`, sortie identique si
`format` n'est pas forcé. Les shaders travaillent sur LUMA/CHROMA, le plan
alpha est redimensionné avec `upscaler`.
```bash
# x2, vidéo réelle, alpha conservé, sortie ProRes 4444
ffmpeg -i in_yuva420p.mov \
  -vf "libplacebo=w=iw*2:h=ih*2:custom_shader_path=shaders/FSRCNNX_x2_16-0-4-1.glsl:upscaler=ewa_lanczos:format=yuva444p10le" \
  -c:v prores_ks -profile:v 4444 out.mov

# x2 motion design (Anime4K), alpha conservé, sortie HEVC alpha
ffmpeg -i in.mov \
  -vf "libplacebo=w=iw*2:h=ih*2:custom_shader_path=shaders/anime4k_modeA.glsl:format=yuva420p" \
  -c:v libx265 -x265-params alpha=1 out.mov

# ratio libre (1080p → 1440p) avec RAVU zoom
ffmpeg -i in.mov -vf "libplacebo=w=2560:h=1440:custom_shader_path=shaders/ravu-zoom-r3.hook" out.mov
```
Options utiles : `alpha_mode=straight|premultiplied` (force le mode de
sortie), `deband=1`, `dithering=none` pour garder un alpha propre, `format=`
pour le pixfmt de sortie. Détail des options : `ffmpeg -h filter=libplacebo`.

Chemin des shaders : relatif au répertoire courant, ou absolu.

## 2. RTX Video Super Resolution (`sr_rtx`)

### Pourquoi un shim DLL
Le SDK ne fournit qu'une lib statique MSVC (`nvsdk_ngx_s.lib`, runtime C++
MSVC) impossible à linker en MinGW. `thirdparty/rtxvsr/rtxvsr.cpp` est donc
compilé en MSVC en une petite DLL à API C plate (`rtxvsr.dll`), et le filtre
`libavfilter/vf_sr_rtx.c` la charge en `LoadLibrary`. FFmpeg ne linke rien
de NVIDIA ; sans les DLL le filtre existe mais échoue proprement à l'init.

### Prérequis
- RTX Video SDK 1.1 décompressé dans `thirdparty/rtxvideosdk/` (ignoré par git,
  contenu NVIDIA non redistribuable — projet interne OK).
- CUDA Toolkit 12.8+ (headers + `cuda.lib`), Visual Studio 2022 C++ x64.
- Runtime : GPU RTX 20xx ou plus, driver NVIDIA ≥ 550.58 (R570+ conseillé pour
  la voie CUDA), `nvngx_vsr.dll` et `rtxvsr.dll` à côté de l'**exécutable hôte**
  (le build les copie dans `bin/` pour ffmpeg.exe ; si le filtre tourne dans
  mpv ou un plugin, les deux DLL doivent être à côté de cet exe-là, pas de
  `avfilter-*.dll`).
- Erreur SDK (feature absente, driver trop vieux) : le sample NVIDIA fait
  `getchar(); exit()` ; `rtx_sdk_glue.cpp` le transforme en exception que le
  shim renvoie comme message d'erreur au filtre.

### Build
```bash
./build-msys-prepare-rtxvideosdk.sh   # cl.exe via vswhere/vcvars64 → thirdparty/rtxvsr/build_mingw/rtxvsr.dll
./build-msys-shared.sh                # détecte le shim → --enable-librtxvsr, bundle les 2 DLL
```
Vérif : `ffmpeg -filters | grep sr_rtx`, puis `ffmpeg -h filter=sr_rtx`.

### Fonctionnement du filtre
- Formats : `rgba` (avec alpha) ou `rgb0` ; FFmpeg convertit automatiquement
  depuis `yuva420p` etc. Le SDK attend du R8G8B8A8 8 bits, donc pas de 10 bits
  en entrée de VSR (la conversion se fait autour).
- Passe 1 : RGB → VSR (alpha forcé opaque en entrée, l'alpha de sortie du SDK
  n'est jamais utilisé).
- Passe 2 (si alpha) : le plan alpha est upscalé par VSR comme une image grise
  (`alpha=vsr`, défaut, contours cohérents avec la couleur) ou en bicubique
  swscale (`alpha=bicubic`).
- Alpha straight : prémultiplication avant VSR, dé-prémultiplication après
  (`premult=-1` auto d'après `alpha_mode` de la frame, `0`/`1` pour forcer).
  Sans ça VSR accentue les franges des bords transparents.
- Une seule instance `sr_rtx` par process (état global du wrapper NVIDIA), API
  non thread-safe : le filtre appelle le SDK séquentiellement.

### Options
| Option | Défaut | Rôle |
|--------|--------|------|
| `scale` | 2.0 | facteur si `w`/`h` = 0, tout ratio ≥ 1 (1.0 = sharpen/deblock seul) |
| `w`, `h` | 0 | taille de sortie ; un seul des deux garde le ratio |
| `quality` | 4 | 0 = bicubique SDK (référence), 1..4 = VSR, 4 = meilleur/lent |
| `gpu` | 0 | index CUDA |
| `alpha` | `vsr` | `vsr` ou `bicubic` |
| `premult` | -1 | -1 auto, 0 jamais, 1 toujours |

### Exemples
```bash
# x2 HEVC alpha → ProRes 4444 avec alpha
ffmpeg -i in.mov -vf sr_rtx=scale=2 -pix_fmt yuva444p10le -c:v prores_ks -profile:v 4444 out.mov

# 1080p → UHD, qualité 3, sortie HAP Alpha
ffmpeg -i in.mov -vf "sr_rtx=w=3840:h=2160:quality=3" -c:v hap -format hap_alpha out.mov

# comparaison A/B : bicubique SDK vs VSR
ffmpeg -i in.mov -vf sr_rtx=quality=0 ref.mov
```

## 3. Sans support alpha dans le filtre : séparer / fusionner
Pour n'importe quel filtre qui ignore l'alpha (`sr`, `scale_vulkan`, un futur
backend) : extraire l'alpha, traiter les deux flux, refusionner.
```bash
ffmpeg -i in.mov -filter_complex \
 "[0:v]format=yuva420p,split[c][a];
  [a]alphaextract,scale=iw*2:ih*2:flags=lanczos[au];
  [c]format=yuv420p,<filtre_upscale>[cu];
  [cu][au]alphamerge,format=yuva420p[out]" -map "[out]" out.mov
```
`alphaextract` produit du `gray8`, donc le flux alpha peut aussi passer par le
même filtre d'upscale que la couleur.

## Fichiers
| Fichier | Rôle |
|---------|------|
| `build-msys-prepare-shaders.sh` | télécharge FSRCNNX / Anime4K / RAVU / NNEDI3 dans `thirdparty/shaders/` |
| `build-msys-prepare-rtxvideosdk.sh` | compile `rtxvsr.dll` en MSVC, copie `nvngx_vsr.dll` |
| `thirdparty/rtxvsr/rtxvsr.h`, `rtxvsr.cpp` | API C + shim CUDA (arrays + `rtx_video_api_cuda_*` du sample SDK) |
| `thirdparty/rtxvsr/rtx_sdk_glue.cpp` | compile le sample SDK avec `getchar/exit` neutralisés et `APP_PATH` = dossier de la DLL |
| `libavfilter/vf_sr_rtx.c` | filtre `sr_rtx` (RGBA, alpha 2 passes, premult) |
| `configure` | `--enable-librtxvsr`, `sr_rtx_filter_deps` |
| `build-msys-shared.sh` | détection libplacebo / shaders / shim, bundle DLL + `bin/shaders/` |
| `build-msys-copy-with-dlls-shared.sh` | copie `shaders/` dans le bundle |
| `doc/filters.texi` | section `sr_rtx` |

## À valider au premier build (checklist)
- [ ] `build-msys-prepare-rtxvideosdk.sh` : link MSVC de `nvsdk_ngx_s.lib` + `cuda.lib` + `cudart_static.lib` (le sample CUDA du SDK peut demander d'autres libs système, ajouter dans le .bat généré si besoin).
- [ ] `ffmpeg -v verbose -i in.mov -vf sr_rtx -f null -` : log `RTX VSR WxH -> WxH`.
- [ ] Qualité de VSR sur l'alpha en gris (`alpha=vsr` vs `alpha=bicubic`) sur un vrai fichier `puppets_with_alpha_hevc.mov`.
- [ ] Effet de `premult` sur les bords (comparer `premult=0` et `premult=1`).
- [ ] Ratios non entiers (`w=2560:h=1440`) acceptés par le SDK.
- [ ] libplacebo : `custom_shader_path` avec FSRCNNX sur `yuva420p`, alpha intact en sortie.
