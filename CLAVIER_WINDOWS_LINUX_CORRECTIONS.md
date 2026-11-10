# Correctifs clavier Windows -> Linux (10 novembre 2026)

## Complement X11 : saisie Unicode et modificateurs (10 novembre 2026)

Le serveur Linux du cas utilisateur fonctionne sous X11. Le constat que
**"Type / paste Unicode text..." echoue aussi pour `@` et `|`** indique que
la seule correction AltGr / VK_RMENU ne suffisait pas.

Dans `server/kvm_inject_x11.pas`, `InjectText` isole desormais la frappe
Unicode des modificateurs deja maintenus dans le serveur X (Ctrl, Alt, AltGr,
Shift, Meta/Super) puis restaure leur etat initial, y compris en cas d'erreur.
Cela protege egalement l'injection de texte lorsque des evenements clavier
anterieurs ont laisse une touche de modification enfoncee. Un nouvel outil
`tools/diagnose_keyboard_x11.py` permet de verifier sans modifier l'etat du
clavier si `@`, `#`, `|` et `!` sont presents dans le groupe XKB actif.

Voir `DIAGNOSTIC_UNICODE_X11.md` pour les essais et limites. Validation native :
**56 injections avec modificateurs** + **23 injections de ponctuation** sur
Xvfb US/FR. Suite Python : **38/43** (les 5 dependances absentes subsistent).
La validation sur le vrai serveur Debian X11 et la compilation Lazarus restent
a effectuer. Aucun collage via presse-papiers n'a ete ajoute ; la commande
"paste Unicode" demeure une simulation de touches Unicode en X11.

---


## Correctif complementaire : AltGr (@, #, |)

Une verification ulterieure a confirme que **AltGr fonctionne vers un serveur
Windows, mais pas necessairement vers Linux**. Windows genere typiquement un
evenement Ctrl artificiel juste avant l'Alt droit. Sous X11, `Ctrl+AltGr+@`
est interprete comme une combinaison de controle, alors que `AltGr+@`
produit bien le caractere `@`.

Correctif ajoute dans cette archive :

- `client/kvm_view_form.pas` : identifier l'Alt droit physique via
  `GetKeyState(VK_RMENU)` et transmettre `VK_RMENU` ($A5) meme lorsque
  Lazarus signale le code generique `VK_MENU` ($12). Memoriser le VK
  effectivement envoye afin de relacher exactement la meme touche.
- `server/kvm_desktop.pas` (**Linux seulement**) : lorsque `VK_RMENU` arrive,
  suspendre le Ctrl deja transmis, activer AltGr, puis retablir Ctrl a la
  liberation d'AltGr s'il est toujours logiquement presse. Gerer egalement
  les liberations de Ctrl pendant AltGr et les erreurs d'injection.
- `server/kvm_inject_x11.pas` : mapper en priorite `VK_RMENU` vers le keysym
  `ISO_Level3_Shift` (AltGr / Mod5), avec repli vers `Alt_R`.
- `server/kvm_wayland.pas` : transmettre `ISO_Level3_Shift` au portail pour
  `VK_RMENU`. La validation Wayland en session reelle reste a faire.

L'injection cote **serveur Windows** (`server/kvm_inject_win.pas`) est inchangee.
Le client Windows est toutefois modifie pour envoyer correctement l'Alt droit,
donc le trajet Windows vers Windows doit aussi etre revalide en application.
Un vrai raccourci **Ctrl+Alt gauche** continue a passer par le chemin normal ;
Ctrl+Alt droit est traite comme AltGr sous Linux.

Le nouveau `tests/test_altgr_windows_linux.py` reproduit sous Xvfb FR le
Ctrl artificiel et valide une sequence corrigee pour `@`, `#` et `|`, ainsi
que l'absence de touches bloquees. Il verifie aussi par inspection les quatre
sources modifiees. Tests du projet : **37/42** reussis ; les cinq echecs sont
identiques a ceux de l'archive initiale (dependances absentes). Ni le client
Windows compile ni une session Linux Wayland reelle n'ont ete testes ici.

**Test sur machine :** recompiler le client Windows **et** le serveur Linux,
choisir le mode Unicode automatique, cliquer dans un champ de texte distant,
puis essayer `@ # |` avec AltGr. Refaire l'essai en mode physique lorsque
Windows et Linux utilisent la meme disposition de clavier. Verifier egalement
Ctrl+C, Ctrl+Alt gauche+une touche et Windows vers Windows.

Correctifs appliqués à l'archive LazDesk initiale `lazdesk-main(2).zip`.
Ils privilégient l'envoi de caractères Unicode dans le mode automatique ; ils
ne modifient pas le format du protocole réseau.

## Modifications

- `client/kvm_view_form.pas` : le client **Windows** interroge sa disposition
  clavier active via `GetKeyboardLayout` + `MapVirtualKeyExW(MAPVK_VK_TO_CHAR)`
  afin de reconnaître les touches imprimables, y compris les touches OEM de
  dispositions françaises et internationales. La table de repli reconnaît
  désormais `$DF` (VK_OEM_8), `$E2` (VK_OEM_102), `$C1-$C2` (ABNT) et `$E1`
  (OEM_AX). Entrée, Tab, Retour arrière, Échap et Suppr restent des touches
  de navigation/édition et ne sont jamais bloquées en attendant un caractère.
- `client/kvm_view_form.pas` : sous Windows, `GetKeyState(VK_RMENU)` distingue
  l'AltGr physique d'un Ctrl+Alt classique. Le premier peut composer un texte
  via `OnUTF8KeyPress`, tandis que les raccourcis Ctrl+Alt restent des touches
  physiques. Sous les autres OS clients, l'ancienne heuristique est conservée.
- `shared/kvm_keysym.pas` : ajout de VK_OEM_8 (`!` sur AZERTY français) et
  VK_OEM_102 (`<` sur l'ISO français) pour les modes à touches physiques.
- `server/kvm_inject_x11.pas` : recherche XKB factorisée ; sélection du bon
  niveau Shift/AltGr pour les deux nouvelles touches OEM, maintien puis
  relâchement des modificateurs artificiels ; prise en compte du keysym
  historique X11 `EuroSign` (`$20ac`) lorsque `U20AC` est absent.
- `server/kvm_wayland.pas` : les touches non mappées et sessions indisponibles
  produisent une erreur explicite au lieu d'être ignorées silencieusement.

## Mode à utiliser

Pour un **client Windows** et un **serveur Linux**, préférer le mode
**Control > Keyboard mode > Automatic: Unicode text + shortcuts**. C'est aussi
la valeur par défaut de l'option `--keyboard text`.

Le mode **Physical key mode** transmet des touches virtuelles (VK) et dépend
encore de la disposition clavier Linux et des modificateurs physiques. Il ne
peut pas garantir la saisie d'un symbole local identique entre AZERTY et
QWERTY avec le protocole VK-only actuel. Les deux nouvelles touches OEM sont
mieux traitées sous X11, mais `@`, `|` et `#` doivent être testés en mode
Unicode automatique lors de dispositions différentes.

## Vérifications réalisées

- `python3 tests/test_keyboard_x11_symbols.py` : **23 injections natives**
  dans un affichage **Xvfb isolé**, avec dispositions X11 **US et FR** ;
  `!`, `@`, `|` et `#` et d'autres symboles sont obtenus par XTest/XKB ;
  les modificateurs sont relâchés après chaque injection ; fallback EuroSign
  vérifié sous disposition FR.
- Tous les `tests/test_*.py` : **36 réussis sur 41**. Les **5 impossibles**
  faisaient déjà défaut dans l'archive d'origine : `kvm_ws`,
  `summarize_metrics` et `tools/fix_mormot_msi_import.py` manquants.
- `tests/check_project.py` n'est pas exécutable avec l'archive d'origine :
  `docs/CHANGEMENTS_V7.md` y manque.

## À vérifier sur les machines cibles

Cette archive contient du **code source modifié**, pas de binaires compilés.
Le compilateur Free Pascal/Lazarus et un environnement Windows/Wayland complet
n'étaient pas disponibles dans l'environnement d'audit. Les tests X11 valident
les appels natifs utilisés par le code, **pas** l'exécutable Pascal compilé
ni le client Lazarus sous Windows.

Après recompilation **du client Windows et du serveur Linux**, effectuer ce
contrôle dans un éditeur de texte distant :

1. Choisir `Automatic: Unicode text + shortcuts` et cliquer dans l'écran distant.
2. Saisir `! @ | # \\ € [ ] { } < >` en AZERTY Windows vers Linux US, puis FR.
3. Vérifier AltGr+0/3/6, Ctrl+Alt+une lettre (raccourci), Shift et saisie
   d'un caractère accentué, puis les appuis/relâchements après reconnexion.
4. Effectuer un essai séparé en Wayland avec autorisation du portail.

Limites maintenues : la saisie X11 ne peut pas injecter arbitrairement un
caractère Unicode absent de la disposition XKB active (ex. certains caractères
CJK ou emoji) ; un mécanisme IME/presse-papiers distinct serait nécessaire.
