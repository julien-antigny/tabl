# Conventions

## Organisation

```
back/            le moteur
  tabl.zig       API publique : seul point d'entrée pour le front
  core/          domaine et ports, ne dépend de rien
  app/           cas d'usage, dépend de core
  infra/         adaptateurs (csv, cache, fichiers…), dépend de core
front/
  cli/           la ligne de commande
```

- `core` ne dépend ni d'`app` ni d'`infra`. `app` ne dépend pas d'`infra`.
- Les adaptateurs ne sont assemblés qu'à un seul endroit, la racine de composition.
- Le front ne connaît que l'API publique du moteur.

## Vocabulaire

- **Port** : interface déclarée dans `core`, implémentée dans `infra`.
- **Adaptateur** : implémentation d'un port, liée à une technique (mmap, CSV, JSON…).
- **Service** : logique du `core` ou de l'`app`, sans technique.

## Ports

- Chaque port documente son rôle et son contrat : ce que l'appelant peut attendre.
- Un port ne parle jamais d'un détail d'infra. Une méthode qu'on ne peut pas décrire sans parler d'infra n'a rien à faire dans le port.
- Le contrat se vérifie par un test de contrat écrit dans `core`, que chaque adaptateur doit passer.
- Une interface seulement quand il y a plusieurs implémentations ou un besoin de doublure en test. Sinon, un type concret.

## Construction

- Construire un objet ne fait aucune entrée/sortie.
- Un objet adossé à un fichier le lit à la demande, dans ses méthodes, qui peuvent échouer. Pas d'étape d'initialisation à ne pas oublier.

## Erreurs

- Chaque couche a ses propres erreurs.
- Une couche ne laisse pas passer l'erreur d'une autre : elle la traduit dans la sienne, en gardant la cause.
- Les messages pour l'utilisateur vivent dans le front.
