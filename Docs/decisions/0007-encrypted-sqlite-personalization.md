# ADR-0007 — SQLite chiffré pour la personnalisation

- Statut : acceptée
- Date : 2026-07-22

## Contexte

Le dictionnaire, les snippets et les règles par application peuvent contenir des noms, des URL ou
du texte sensible. Un fichier JSON lisible ne satisfait pas la politique de rétention minimale.

## Décision

PersonalizationKit stocke ces données dans SQLite avec transactions atomiques et mode WAL. Les
colonnes de contenu et de portée sont chiffrées par AES-GCM avant écriture ; une clé aléatoire de
256 bits est conservée dans le Trousseau avec l'accessibilité
`AfterFirstUnlockThisDeviceOnly`. Les fichiers SQLite ont des permissions `0600`.

L'ancien `personalization.json`, s'il existe, est migré une seule fois vers le schéma chiffré. Le
mode privé empêche toujours l'apprentissage et l'historique, indépendamment de ce stockage.

## Conséquences

Une copie isolée de la base ne révèle pas les termes personnels. Une perte du Trousseau rend la
base irrécupérable, ce qui est préférable à un repli silencieux en clair ; une future fonction
d'export devra donc avoir son propre format chiffré et sa propre phrase de récupération.
