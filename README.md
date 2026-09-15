# install-plex.sh

Script bash d'installation de **Plex Media Server** sur Ubuntu/Debian, via le dépôt APT officiel (`repo.plex.tv`), avec vérification cryptographique de la clé de signature et un mode simulation (`--dry-run`).

Testé avec succès sur **Ubuntu 26.04.1 LTS** (fresh install) et **Ubuntu 24.04 LTS**.

## Pourquoi ce script plutôt qu'un `snap install` ou un tuto au hasard

- Utilise le **dépôt APT officiel actuel** (`repo.plex.tv/deb`, format DEB822) — pas l'ancienne URL `downloads.plex.tv` dépréciée depuis Plex 1.43, qu'on trouve encore dans beaucoup de tutoriels obsolètes.
- **Vérifie l'empreinte GPG** de la clé de signature avant de l'installer dans le trousseau système. Si elle ne correspond pas à l'empreinte officielle Plex, le script s'arrête — il n'installe jamais une clé à l'aveugle.
- Refuse de s'exécuter si Plex est déjà installé via **snap**, pour éviter un système avec deux installations qui se marchent dessus.
- **Idempotent** : peut être relancé sans casser une installation existante.
- **Mode simulation** (`--dry-run`) : exécute réellement toutes les vérifications (réseau, distribution, architecture, empreinte de clé) et affiche sans les exécuter toutes les commandes qui modifieraient le système.

## Ce que fait le script

1. Vérifie l'OS, l'architecture, l'absence de conflit avec une install snap, et l'accès réseau à Plex.
2. Installe les dépendances (`curl`, `gnupg2`, `ca-certificates`, `acl`).
3. Nettoie d'éventuels anciens dépôts Plex.
4. Télécharge la clé de signature Plex et vérifie son empreinte.
5. Déclare le dépôt APT officiel et installe `plexmediaserver`.
6. Active le service systemd et attend que le serveur réponde sur le port 32400.
7. Ouvre les ports nécessaires dans UFW, **seulement si UFW est déjà actif**.
8. Crée une arborescence de dossiers médias (`films`, `series`, `musique`, `photos`) avec des ACL en lecture pour l'utilisateur `plex`, sans toucher au propriétaire des fichiers.
9. Configure en option `unattended-upgrades` pour le dépôt Plex.

## Usage

```bash
chmod +x install-plex.sh

# Simulation : rien n'est modifié, tout est affiché
sudo ./install-plex.sh --dry-run

# Installation réelle
sudo ./install-plex.sh
```

### Options

| Option | Effet |
|---|---|
| `--media-dir <chemin>` | Change le dossier médias (défaut `/srv/medias`) |
| `--no-media-dir` | Ne crée pas de dossier médias |
| `--no-firewall` | Ne touche pas à UFW |
| `--no-auto-updates` | N'installe pas `unattended-upgrades` pour Plex |
| `--dry-run` / `-n` | Simulation, aucune modification |

## Après l'installation

Plex n'autorise l'assistant de configuration initial que depuis `localhost` :

- **Serveur avec interface graphique** : ouvrez directement `http://127.0.0.1:32400/web`.
- **Serveur sans interface** (SSH) : `ssh -L 32400:127.0.0.1:32400 user@ip-serveur`, puis ouvrez `http://127.0.0.1:32400/web` sur votre poste.

## Limites connues

- La configuration `unattended-upgrades` pour l'origine Plex (`origin=Plex*`) n'a pas été validée de façon exhaustive sur toutes les versions du paquet Plex — vérifiez après coup avec `apt-cache policy plexmediaserver`, ou utilisez `--no-auto-updates` et mettez à jour manuellement.
- Le script installe la dernière version **publique** de Plex ; les builds Plex Pass en beta ne passent pas par ce dépôt.
- Testé sur Ubuntu 24.04 / 26.04. Devrait fonctionner sur toute distribution basée Debian avec `apt`, sans garantie au-delà de ce qui a été testé.

## Licence

MIT
