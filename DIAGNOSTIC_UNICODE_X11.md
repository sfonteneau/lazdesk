# Clavier Windows -> serveur Linux X11 : AltGr et texte Unicode

Correctif complementaire (10 novembre 2026), apres la verification que le serveur Linux utilise **X11** (`echo $XDG_SESSION_TYPE` donne `x11`).

## Symptomes rapportes

- Les fleches fonctionnent.
- `AltGr` fonctionne quand la cible est un serveur Windows, pas lorsqu'elle est Linux.
- Les caracteres `@`, `#`, `|` n'arrivent pas sous Linux.
- La commande **Control > Type / paste Unicode text...** peut aussi ne pas inserer `@` ou `|`.

Le dernier point montre que la correction ne doit pas se limiter a la capture de AltGr dans le client Windows. Le trajet `U/X` de texte Unicode du serveur Linux passe aussi par **XKB + XTest** (ce n'est pas un collage X11 via le presse-papiers).

## Correction ajoutee par rapport au precedent ZIP AltGr

- `server/kvm_inject_x11.pas` : au moment de `InjectText`, relever les touches de modification actuellement pressees dans X11 via `XQueryKeymap`, liberer temporairement les modificateurs *qui affectent la saisie de texte* (Ctrl, Shift, Alt, Meta, Super, AltGr, Mode_switch), injecter exactement le symbole recherche dans la disposition XKB active, puis restaurer tous les modificateurs qui etaient presses. La restauration est tentee egalement si l'injection echoue.
- Le statut verrouille de CapsLock est restaure. Le serveur ne modifie **ni la disposition XKB globale ni le presse-papiers**.
- `server/kvm_server.pas` : si le symbole n'existe pas dans le groupe XKB actif, afficher dans les journaux une cause explicite sans divulguer le texte ni le caractere saisi.
- `tools/diagnose_keyboard_x11.py` : diagnostic **lecture seule** du clavier de la session serveur, ne simule aucune touche. Il indique la presence de XTest, le groupe XKB, l'etat des modificateurs et l'emplacement des caracteres `@`, `#`, `|`, `!`.

Les corrections precedentes (normalisation de l'Alt droit du client Windows, suspension du Ctrl artificiel en mode physique Linux et correction XKB des touches OEM) restent incluses dans le projet complet. Le chemin d'injection du **serveur Windows est inchange**.

## Validations effectuees

- `python3 tests/test_x11_unicode_modifier_isolation.py` : **56 injections XTest/XKB** d'`@`, `#`, `|`, `!`, en `fr` et `us`, sans modificateur et avec Ctrl, Ctrl+Alt, Shift+Ctrl, AltGr, Ctrl+AltGr et Super. Les symboles sont observes par `XLookupString`, puis l'etat des touches est compare a l'etat initial. Le test lance aussi l'outil de diagnostic.
- `python3 tests/test_keyboard_x11_symbols.py` : **23 autres injections** XTest/XKB de ponctuation en `fr` et `us`.
- `python3 tests/test_altgr_windows_linux.py` : **3 tests AltGr** avec un Ctrl artificiel.
- Suite des scripts Python : **38 reussis sur 43** ; les 5 scripts non passes demandent des fichiers deja absents du projet (`kvm_ws`, `summarize_metrics`, `tools/fix_mormot_msi_import.py`).

**Limites importantes :** ces tests utilisent un affichage X11 virtuel Xvfb et la bibliotheque native via Python. Le projet Pascal complet **n'a pas ete compile**, et le comportement exact de la machine Debian/Trixie de l'utilisateur n'a pas ete observe. L'absence de `@` et `|` dans la disposition XKB active ou un probleme de focus peuvent encore empecher leur saisie. Le protocole de texte n'est pas un collage universel d'Unicode : il requiert que le symbole existe dans le clavier XKB actif.

## Installation et test sur le poste reel

1. Utiliser le **ZIP complet** du correctif. Recompiler le **serveur Linux X11**. Recompiler aussi le client Windows si l'ancien correctif AltGr n'a pas encore ete installe.
2. Se connecter, prendre le controle, cliquer dans un editeur de texte sur l'ecran Linux.
3. Choisir **Control > Keyboard mode > Automatic: Unicode text + shortcuts**. Essayer `@ # | !` sur le clavier local.
4. Tester ensuite **Control > Type / paste Unicode text...**, saisir `@#|!`, puis valider.
5. Observer le statut du client : si une notification indique *Input rejected/partial*, examiner les journaux du serveur ; la cause *symbol absent from current XKB group* indique que la disposition n'expose pas le caractere.
6. En cas de persistance, sur le Linux cible, dans la **meme session graphique et avec le meme DISPLAY/XAUTHORITY que le serveur**, lancer :

   ```bash
   echo "session=$XDG_SESSION_TYPE display=$DISPLAY"
   setxkbmap -query
   python3 tools/diagnose_keyboard_x11.py
   ```

   L'outil ne modifie rien et ne lit aucune frappe. Si `DISPLAY` ou l'autorisation X11 sont absents (par exemple si le processus LazDesk tourne comme service root hors session), le diagnostic affiche une erreur de connexion. Dans ce cas, le relancer avec l'utilisateur de la session graphique.

