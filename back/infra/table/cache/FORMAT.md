# Format du cache — version 1

Le cache contient une table déjà importée, rangée **colonne par colonne**, pour être ouverte avec mmap et lue sans décodage.

## Disposition

Un cache est un dossier :

```
ventes.tabl/
  meta.json       métadonnées, écrit en dernier
  0.ends          colonne 0 : positions de fin des valeurs
  0.bytes         colonne 0 : valeurs collées bout à bout
  1.ends
  1.bytes
  …
```

Les colonnes sont numérotées à partir de 0, dans l'ordre de l'en-tête.

## `meta.json`

```json
{
  "format": "tabl-cache",
  "version": 1,
  "rows": 2,
  "source": {
    "path": "/home/alice/ventes.csv",
    "size": 48213377,
    "modified_ns": 1764001234123456789
  },
  "columns": [
    { "name": "ville", "offset_width": 32 },
    { "name": "âge", "offset_width": 32 }
  ]
}
```

| Champ | Type | Sens |
|---|---|---|
| `format` | texte | toujours `"tabl-cache"` : signe que le dossier est bien un cache tabl |
| `version` | entier | version du format, `1` ici |
| `rows` | entier | nombre de lignes, de 0 à 2³² − 1 |
| `source.path` | texte | chemin absolu du fichier importé |
| `source.size` | entier | taille du fichier importé, en octets, au moment de l'import |
| `source.modified_ns` | entier | date de modification du fichier importé, en nanosecondes depuis le 1ᵉʳ janvier 1970, au moment de l'import |
| `columns` | liste | une entrée par colonne, dans l'ordre |
| `columns[].name` | texte | nom de la colonne, en UTF-8 |
| `columns[].offset_width` | entier | largeur des positions de la colonne : `32` ou `64` |

## Une colonne : `N.ends` et `N.bytes`

- **`N.bytes`** : les valeurs de la colonne, collées bout à bout, sans séparateur. Chaque valeur est le texte tel qu'il était dans la cellule, après le retrait des guillemets et le remplacement de `""` par `"`.
- **`N.ends`** : pour chaque ligne, la position de **fin** de sa valeur dans `N.bytes`. Ce sont des entiers non signés, en little-endian, sur 32 ou 64 bits selon `offset_width`. Le fichier contient exactement `rows` entiers.

La valeur de la ligne `i` est :

```
début = 0 si i = 0, sinon ends[i - 1]
fin   = ends[i]
valeur = bytes[début .. fin]
```

Une cellule vide donne une valeur de longueur nulle. La version 1 ne distingue pas une cellule vide d'un texte vide.

### Largeur des positions

- `32` par défaut : une colonne peut contenir jusqu'à 4 Gio de texte.
- `64` seulement quand le texte de la colonne dépasse 4 Gio.

L'écrivain commence en 32 bits. S'il dépasse la limite, il réécrit une fois `N.ends` en 64 bits, puis continue.

### Exemple

Deux lignes, `Paris,31` et `Lyon,45` :

```
0.bytes  "ParisLyon"              (9 octets)
0.ends   05 00 00 00  09 00 00 00  (5, 9 en u32 little-endian)
1.bytes  "3145"
1.ends   02 00 00 00  04 00 00 00  (2, 4)
```

## Écriture

1. Relever la taille et la date de modification du fichier source avant de le lire.
2. Créer le dossier, puis écrire les fichiers `.ends` et `.bytes` en flux, ligne par ligne, avec des tampons de taille fixe.
3. Écrire `meta.json` **en dernier**.

Un dossier sans `meta.json` est un cache incomplet, par exemple après un import interrompu, et doit être refusé.

## Fraîcheur

Le cache est **périmé** quand le fichier `source.path` existe et que sa taille ou sa date de modification diffère de celle notée dans `source`.

- Un cache périmé reste lisible : il n'est pas abîmé, seulement obsolète. C'est à l'appelant de décider s'il prévient ou s'il réimporte.
- Si le fichier source n'existe plus, le cache reste valide et lisible.
- Taille + date ne détecte pas un contenu modifié sans changement de taille ni de date (par exemple une copie qui conserve la date). On accepte ce cas rare ; une empreinte du contenu pourra s'ajouter plus tard.

## Contrôles à l'ouverture

Tout échec refuse le cache avec un message clair.

| Contrôle | Erreur |
|---|---|
| `meta.json` existe | cache incomplet ou introuvable |
| `meta.json` est un JSON valide, avec tous les champs | cache abîmé |
| `format` vaut `"tabl-cache"` | pas un cache tabl |
| `version` vaut `1` | version non prise en charge (cache créé par une autre version de tabl) |
| `offset_width` vaut `32` ou `64` | cache abîmé |
| `source.path` est un chemin absolu | cache abîmé |
| chaque colonne a ses deux fichiers | cache abîmé |
| taille de `N.ends` = `rows` × `offset_width` / 8 | cache abîmé |
| positions croissantes (chacune ≥ la précédente) | cache abîmé |
| dernière position = taille de `N.bytes` (0 si `rows` = 0) | cache abîmé |

Vérifier que les positions sont croissantes oblige à lire tout `N.ends` à l'ouverture. En version 1, on accepte ce coût. On le mesurera, et on rendra ce contrôle paresseux s'il devient gênant.

## Évolution

- Tout changement du format augmente `version`.
- Un lecteur n'accepte que les versions qu'il connaît. Il n'y a pas de compatibilité ascendante implicite.
- Évolutions prévues :

| Version | Ajout | PR |
|---|---|---|
| 2 | types (`i64`, `f64`, dates) et masque des valeurs vides | 5 |
| 3 | min et max par bloc de lignes | 6 |
| 4 | dictionnaire pour les valeurs répétées | 7 |
