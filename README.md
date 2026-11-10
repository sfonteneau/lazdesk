# LazDesk

LazDesk est une solution légère de contrôle de bureau à distance, avec un **serveur** sur la machine à piloter et un **client** sur la machine de contrôle.

## Fonctionnalités

- Capture d'écran JPEG avec qualité et FPS configurables.
- Multi-écran et résolution native.
- Clavier, souris, curseur distant et presse-papiers texte Unicode.
- **Windows** : capture GDI ou DXGI (multi-écran).
- **Linux** : X11, ou Wayland via portail de capture.
- **macOS** : capture avec ScreenCaptureKit.
- Builds autonomes : un exécutable serveur et un exécutable client, sans DLL LazDesk séparée.

## Compilation

Prérequis : **Free Pascal / Lazarus**, **mORMot2**, **TurboJPEG** et les outils de compilation de la plateforme. Sous Windows, prévoir également **MinGW-w64** et **Python 3**.

### Windows x86 avec DXGI statique

Exemple pour une installation Lazarus / MSYS2 :

```bat
build_standalone_windows.cmd --arch x86 ^
  --fpc "C:\lazarus_4_8\fpc\bin\i386-win32\fpc.exe" ^
  --lazbuild "C:\lazarus_4_8\lazarus\lazbuild.exe" ^
  --toolchain-bin "C:\msys64\mingw32\bin" ^
  --turbojpeg-archive "C:\msys64\mingw32\lib\libturbojpeg.a" ^
  --mormot-dir "C:\tranquilit\mORMot2" ^
  --with-dxgi
```

Pour **x64**, utiliser `--arch x64`, le compilateur FPC x64 et les bibliothèques `mingw64` correspondantes.

Sortie x86 : `dist/i386-win32/`. En mode autonome, DXGI est intégré au serveur : **pas besoin de `lazdesk_dxgi.dll`**.

### Linux / macOS

```sh
sh build/build_standalone.sh --turbojpeg-archive /chemin/vers/libturbojpeg.a
```

Sous Linux, ajouter `--with-portal` pour activer la capture Wayland. Les bibliothèques système de la plateforme restent nécessaires.

## Démarrage rapide

Définir le même jeton sur les deux machines (`LAZDESK_TOKEN`, au moins 16 caractères).

Exemple de serveur Windows avec deux écrans :

```bat
set "LAZDESK_TOKEN=remplacer-par-un-jeton-secret"
dist\i386-win32\LazDeskServer.exe --listen 0.0.0.0 --port 7900 --control --backend dxgi --monitor 0 --fps 30 --quality 100 --no-adaptive
```

Sur le client Windows :

```bat
set "LAZDESK_TOKEN=remplacer-par-un-jeton-secret"
dist\i386-win32\LazDeskClient.exe --host IP_DU_SERVEUR --port 7900 --control
```

`--monitor 0` sélectionne le bureau virtuel complet. Pour forcer la capture GDI, remplacer `dxgi` par `gdi`. En mode `--backend auto`, DXGI conserve un repli GDI en cas d'indisponibilite.

**Sécurité :** éviter d'exposer directement le port de contrôle sur Internet ; utiliser un réseau privé ou un tunnel sécurisé.

## Protocole actuel et nettoyage

- **Client et serveur uniques** : `LazDeskClient` / `LazDeskServer`, sous-protocole WebSocket `lazdesk8`.
- La saisie Unicode sur le reseau utilise uniquement le message `X` avec accuse de reception `I` ; le marqueur `U` reste **interne** a la file de saisie (pas un ancien client).
- La topologie des moniteurs est transmise avec `MONITOR_LAYOUT` uniquement.
- Les fallbacks de capture (DXGI/GDI, X11/Wayland, etc.), de codecs et de securite ne sont pas des versions historiques du client ou du serveur et sont conserves.
- Les tests V7/V8/V9 sont des **tests de regression sur le code actuel**, pas des applications anciennes. Ils restent dans l'archive.

Le depot ne livre plus de bibliotheque Linux precompilee. Pour produire le pont de session en mode dynamique sous Linux :

```sh
sh native/session/build.sh
```
