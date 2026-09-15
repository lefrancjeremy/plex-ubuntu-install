#!/usr/bin/env bash
#
# install-plex.sh — Installation de Plex Media Server sur Ubuntu (24.04 / 26.04 LTS)
# Dépôt officiel repo.plex.tv (v2), clé vérifiée par empreinte, mises à jour via apt.
#
# Usage :
#   sudo ./install-plex.sh
#   sudo ./install-plex.sh --media-dir /srv/medias
#   sudo ./install-plex.sh --no-firewall --no-media-dir
#   sudo ./install-plex.sh --dry-run          (simulation : n'écrit rien)
#
# Le script est idempotent : on peut le relancer sans casser une install existante.

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Paramètres
# ----------------------------------------------------------------------------
MEDIA_DIR="/srv/medias"
CONFIGURE_FIREWALL=1
CREATE_MEDIA_DIR=1
ENABLE_AUTO_UPDATES=1
DRY_RUN=0

PLEX_KEY_URL="https://downloads.plex.tv/plex-keys/PlexSign.v2.key"
PLEX_KEY_FPR="6EFFEB478A6559D75C7C4FE706C521790B9CFFDE"
PLEX_REPO_URL="https://repo.plex.tv/deb/"
KEYRING="/etc/apt/keyrings/plexmediaserver.v2.gpg"
SOURCES_FILE="/etc/apt/sources.list.d/plexmediaserver.sources"

TMPDIR_KEY=""

# ----------------------------------------------------------------------------
# Utilitaires d'affichage
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_OK=$'\033[0;32m'; C_ERR=$'\033[0;31m'; C_WARN=$'\033[0;33m'
  C_INFO=$'\033[0;36m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_ERR=""; C_WARN=""; C_INFO=""; C_OFF=""
fi

info()  { printf '%s==>%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
ok()    { printf '%s [OK]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()   { trap - ERR; printf '%s[ERREUR]%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

dry()   { printf '%s[dry-run]%s %s\n' "$C_WARN" "$C_OFF" "$*"; }

# run <commande...> : exécute, ou affiche seulement si --dry-run
run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "$*"
  else
    "$@"
  fi
}

# write_file <chemin> <<< contenu (via stdin) : écrit, ou affiche seulement
write_file() {
  local path="$1" content
  content="$(cat)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "écriture de $path :"
    printf '%s\n' "$content" | sed 's/^/           | /'
  else
    printf '%s\n' "$content" > "$path"
  fi
}

cleanup() {
  [[ -n "$TMPDIR_KEY" && -d "$TMPDIR_KEY" ]] && rm -rf -- "$TMPDIR_KEY"
}
trap cleanup EXIT
trap 'die "Échec à la ligne $LINENO (commande : $BASH_COMMAND)"' ERR

# ----------------------------------------------------------------------------
# Arguments
# ----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --media-dir)     MEDIA_DIR="${2:?chemin manquant après --media-dir}"; shift 2 ;;
    --no-media-dir)  CREATE_MEDIA_DIR=0; shift ;;
    --no-firewall)   CONFIGURE_FIREWALL=0; shift ;;
    --no-auto-updates) ENABLE_AUTO_UPDATES=0; shift ;;
    -n|--dry-run)    DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Option inconnue : $1 (voir --help)" ;;
  esac
done

# ----------------------------------------------------------------------------
# 1. Vérifications préalables
# ----------------------------------------------------------------------------
if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%s╔══════════════════════════════════════════════════════════╗%s\n' "$C_WARN" "$C_OFF"
  printf '%s║  MODE SIMULATION — aucune modification ne sera écrite     ║%s\n' "$C_WARN" "$C_OFF"
  printf '%s╚══════════════════════════════════════════════════════════╝%s\n' "$C_WARN" "$C_OFF"
fi

info "Vérifications préalables"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  [[ "$DRY_RUN" -eq 1 ]] \
    && warn "Pas root : certaines vérifications (snap, apt) peuvent être limitées." \
    || die "Ce script doit être lancé en root : sudo $0"
fi

[[ -r /etc/os-release ]] || die "/etc/os-release introuvable : distribution non identifiable."
# shellcheck disable=SC1091
. /etc/os-release

if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *debian* ]]; then
  die "Distribution non supportée : ${PRETTY_NAME:-inconnue}. Ce script vise Ubuntu/Debian."
fi
ok "Système : ${PRETTY_NAME:-$ID $VERSION_ID}"

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64|arm64|armhf) ok "Architecture : $ARCH" ;;
  *) die "Architecture non supportée par Plex : $ARCH" ;;
esac

# Conflit snap : on refuse de mélanger snap et .deb
if command -v snap >/dev/null 2>&1 && snap list plexmediaserver >/dev/null 2>&1; then
  die "Plex est déjà installé via snap. Retirez-le d'abord :
      sudo snap remove plexmediaserver
   (sauvegardez /var/snap/plexmediaserver si vous avez déjà une bibliothèque)"
fi

# Connectivité vers les dépôts Plex
if ! curl -fsSI --max-time 15 "$PLEX_KEY_URL" >/dev/null; then
  die "Impossible de joindre $PLEX_KEY_URL — vérifiez DNS / réseau / proxy."
fi
ok "Accès réseau à downloads.plex.tv confirmé"

# ----------------------------------------------------------------------------
# 2. Dépendances
# ----------------------------------------------------------------------------
info "Installation des dépendances (curl, gnupg2, ca-certificates, acl)"
export DEBIAN_FRONTEND=noninteractive
run apt-get update -qq
run apt-get install -y -qq curl gnupg2 ca-certificates apt-transport-https acl
ok "Dépendances en place"

# ----------------------------------------------------------------------------
# 3. Nettoyage des anciens dépôts Plex (pré-v1.43)
# ----------------------------------------------------------------------------
info "Nettoyage d'éventuels anciens dépôts Plex"
shopt -s nullglob
for f in /etc/apt/sources.list.d/plex*.list /etc/apt/sources.list.d/plex*.sources; do
  [[ "$f" == "$SOURCES_FILE" ]] && continue
  run rm -fv -- "$f"
done
shopt -u nullglob
# Ancienne clé apt-key (dépréciée) éventuellement présente
if apt-key list 2>/dev/null | grep -qi plex; then
  warn "Une ancienne clé Plex existe dans le trousseau apt-key hérité (non bloquant)."
fi
ok "Anciens dépôts nettoyés"

# ----------------------------------------------------------------------------
# 4. Clé de signature — téléchargement + vérification d'empreinte
# ----------------------------------------------------------------------------
info "Récupération et vérification de la clé de signature Plex"
TMPDIR_KEY="$(mktemp -d)"
chmod 700 "$TMPDIR_KEY"

curl -fsSL --retry 3 --retry-delay 2 --max-time 60 \
     -o "$TMPDIR_KEY/PlexSign.v2.key" "$PLEX_KEY_URL"

FOUND_FPR="$(gpg --homedir "$TMPDIR_KEY" --batch --with-colons \
                 --show-keys --fingerprint "$TMPDIR_KEY/PlexSign.v2.key" 2>/dev/null \
             | awk -F: '/^fpr:/ {print $10; exit}' || true)"

if [[ "$FOUND_FPR" != "$PLEX_KEY_FPR" ]]; then
  die "Empreinte de clé inattendue !
      attendue : $PLEX_KEY_FPR
      obtenue  : ${FOUND_FPR:-<vide>}
   Installation interrompue par sécurité."
fi
ok "Empreinte vérifiée : $PLEX_KEY_FPR"

run install -d -m 0755 /etc/apt/keyrings
gpg --batch --yes --dearmor -o "$TMPDIR_KEY/plex.gpg" "$TMPDIR_KEY/PlexSign.v2.key"
run install -m 0644 -o root -g root "$TMPDIR_KEY/plex.gpg" "$KEYRING"
[[ "$DRY_RUN" -eq 1 ]] || ok "Trousseau installé : $KEYRING"

# ----------------------------------------------------------------------------
# 5. Dépôt APT (format DEB822)
# ----------------------------------------------------------------------------
info "Configuration du dépôt APT Plex"
write_file "$SOURCES_FILE" <<EOF
Types: deb
URIs: $PLEX_REPO_URL
Suites: public
Components: main
Architectures: $ARCH
Signed-By: $KEYRING
EOF
run chmod 0644 "$SOURCES_FILE"
ok "Dépôt déclaré : $SOURCES_FILE"

# ----------------------------------------------------------------------------
# 6. Installation de Plex Media Server
# ----------------------------------------------------------------------------
info "Installation de plexmediaserver (dernière version publique)"
run apt-get update -qq
run apt-get install -y -o Dpkg::Options::=--force-confdef \
                       -o Dpkg::Options::=--force-confold plexmediaserver

PLEX_VERSION="$(dpkg-query -W -f='${Version}' plexmediaserver 2>/dev/null || echo "non installée")"
[[ "$DRY_RUN" -eq 1 ]] || ok "Plex Media Server installé — version $PLEX_VERSION"

# ----------------------------------------------------------------------------
# 7. Service systemd
# ----------------------------------------------------------------------------
info "Activation du service"
run systemctl daemon-reload
run systemctl enable --now plexmediaserver

# Attente de l'ouverture du port 32400 (60 s max)
READY=0
if [[ "$DRY_RUN" -eq 1 ]]; then
  dry "attente du port 32400 (ignorée en simulation)"
else
info "Attente du démarrage sur le port 32400…"
for _ in $(seq 1 60); do
  if curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:32400/identity"; then
    READY=1; break
  fi
  sleep 1
done
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  :
elif [[ "$READY" -eq 1 ]]; then
  ok "Plex répond sur http://127.0.0.1:32400/web"
else
  warn "Plex ne répond pas encore. Diagnostic :
      systemctl status plexmediaserver
      journalctl -u plexmediaserver -n 80 --no-pager"
fi

# ----------------------------------------------------------------------------
# 8. Pare-feu (UFW) — uniquement s'il est actif
# ----------------------------------------------------------------------------
if [[ "$CONFIGURE_FIREWALL" -eq 1 ]] && command -v ufw >/dev/null 2>&1; then
  if ufw status 2>/dev/null | grep -q "^Status: active"; then
    info "Ouverture des ports Plex dans UFW"
    run ufw allow 32400/tcp       comment 'Plex - acces principal'
    run ufw allow 32469/tcp       comment 'Plex - DLNA'
    run ufw allow 1900/udp        comment 'Plex - DLNA decouverte'
    run ufw allow 5353/udp        comment 'Plex - Bonjour/Avahi'
    run ufw allow 32410/udp       comment 'Plex - decouverte GDM'
    run ufw allow 32412:32414/udp comment 'Plex - decouverte GDM'
    ok "Règles UFW appliquées"
  else
    info "UFW présent mais inactif — aucune règle ajoutée."
  fi
fi

# ----------------------------------------------------------------------------
# 9. Dossier médias + droits (ACL, sans changer le propriétaire)
# ----------------------------------------------------------------------------
if [[ "$CREATE_MEDIA_DIR" -eq 1 ]]; then
  info "Préparation du dossier médias : $MEDIA_DIR"
  run install -d -m 0755 "$MEDIA_DIR"/films "$MEDIA_DIR"/series \
                         "$MEDIA_DIR"/musique "$MEDIA_DIR"/photos

  if id plex >/dev/null 2>&1; then
    # Traversée des dossiers parents
    parent="$MEDIA_DIR"
    while [[ "$parent" != "/" ]]; do
      run setfacl -m u:plex:rx "$parent" 2>/dev/null || true
      parent="$(dirname "$parent")"
    done
    # Lecture récursive + héritage sur les nouveaux fichiers
    run setfacl -R  -m u:plex:rX "$MEDIA_DIR"
    run setfacl -dR -m u:plex:rX "$MEDIA_DIR"
    ok "ACL en lecture accordées à l'utilisateur plex sur $MEDIA_DIR"
  else
    warn "Utilisateur système 'plex' introuvable — ACL non appliquées."
  fi
fi

# ----------------------------------------------------------------------------
# 10. Mises à jour automatiques du paquet Plex (optionnel)
# ----------------------------------------------------------------------------
if [[ "$ENABLE_AUTO_UPDATES" -eq 1 ]]; then
  info "Activation des mises à jour automatiques pour Plex"
  run apt-get install -y -qq unattended-upgrades
  write_file /etc/apt/apt.conf.d/51unattended-upgrades-plex <<'EOF'
// Ajoute le dépôt Plex aux origines mises à jour automatiquement.
Unattended-Upgrade::Origins-Pattern {
    "origin=Plex*";
};
EOF
  run systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
  ok "unattended-upgrades configuré pour le dépôt Plex"
fi

# ----------------------------------------------------------------------------
# Récapitulatif
# ----------------------------------------------------------------------------
IP_LAN="$(hostname -I 2>/dev/null | awk '{print $1}')"
IP_LAN="${IP_LAN:-<ip-du-serveur>}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  cat <<EOF

────────────────────────────────────────────────────────────────
 ${C_WARN}Simulation terminée — rien n'a été modifié${C_OFF}
────────────────────────────────────────────────────────────────
 Tout ce qui précède se serait exécuté réellement.
 Les vérifications réseau, l'empreinte GPG, l'architecture et la
 distribution ont été contrôlées pour de bon.

 Pour lancer l'installation :  sudo $0 ${*:-}
────────────────────────────────────────────────────────────────
EOF
  exit 0
fi

SVC_ACTIVE="$(systemctl is-active plexmediaserver 2>/dev/null || true)"
SVC_ENABLED="$(systemctl is-enabled plexmediaserver 2>/dev/null || true)"

cat <<EOF

────────────────────────────────────────────────────────────────
 ${C_OK}Installation terminée${C_OFF}
────────────────────────────────────────────────────────────────
 Version Plex   : $PLEX_VERSION
 Service        : ${SVC_ACTIVE:-inconnu} / ${SVC_ENABLED:-inconnu}
 Données        : /var/lib/plexmediaserver
 Dossier médias : $([[ "$CREATE_MEDIA_DIR" -eq 1 ]] && echo "$MEDIA_DIR" || echo "non créé")

 ${C_INFO}Première configuration${C_OFF}
 Plex n'autorise l'assistant de configuration que depuis localhost.

 • Serveur avec interface graphique :
     firefox http://127.0.0.1:32400/web

 • Serveur sans interface (SSH depuis votre PC) :
     ssh -L 32400:127.0.0.1:32400 $USER@$IP_LAN
     puis, sur votre PC : http://127.0.0.1:32400/web

 ${C_INFO}Commandes utiles${C_OFF}
   systemctl status plexmediaserver
   journalctl -u plexmediaserver -f
   apt update && apt install --only-upgrade plexmediaserver
────────────────────────────────────────────────────────────────
EOF
