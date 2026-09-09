# Contribuer

Deux regles, pas plus.

## 1. Signer ses commits (`Signed-off-by`)

Chaque commit doit porter la ligne :

```
Signed-off-by: Prenom Nom <adresse@example.com>
```

`git commit -s` l'ajoute pour vous.

C'est le [Developer Certificate of Origin](https://developercertificate.org/) :
vous attestez avoir le droit de soumettre ce code sous la licence du depot.
Sans cette ligne une contribution ne peut pas etre integree -- le depot ne
pourrait plus etre distribue sous d'autres termes sans retrouver chaque auteur
un par un.

## 2. La CI doit etre verte

Elle n'est pas une formalite de fin de course : c'est elle qui decide. Elle
verifie le lint, les tests unitaires du binaire Go, les tests fonctionnels sur
l'image construite, l'inventaire de son contenu, la cloture de ses dependances,
et scanne les paquets du stage de preparation.

Une porte rouge est presque toujours un vrai defaut. Avant d'ouvrir une pull
request, construisez l'image et rejouez les tests en local : c'est plus rapide
que d'attendre le retour de la chaine.

## Ce qui rend une pull request facile a integrer

- **Un sujet par pull request.** Un correctif et une montee de version dans le
  meme diff se relisent deux fois plus mal.
- **Dire ce qui a ete verifie**, et comment. « CI verte » n'est pas une
  verification, c'est un resultat.
- **Aucune version recopiee.** Les versions vivent dans `versions.json`, jamais
  dans le README ni dans la prose -- il n'existe qu'une source de verite.
