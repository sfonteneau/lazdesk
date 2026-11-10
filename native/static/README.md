# Archives natives de compilation

`build/build_standalone.py` cree ici un sous-dossier par CPU/OS.
Il contient les archives `.a`, les `.o` intermediaires, les fichiers `.inc`
de liaison et le manifeste du build. Ces fichiers ne vont PAS sur la machine
cible. Ne pas reutiliser une archive d'un autre OS/CPU/compilateur.

Aucune bibliotheque tierce precompilee n'est incluse dans les sources livrees.
Les archives sont generees/copiees sur la machine de compilation depuis les
sources natives du projet et la bibliotheque TurboJPEG choisie.
Une archive d'import `.dll.a` n'est pas une bibliotheque statique autonome.
