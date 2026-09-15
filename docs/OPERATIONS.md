[README](../README.md) · [Architecture](ARCHITECTURE.md) · [Setup](SETUP.md) · **Opérations** · [Client](CLIENT-POSTE.md)

# Exploitation

Procédures courantes une fois le VPS en service ([SETUP.md](SETUP.md)).
Convention : `dev` = utilisateur de travail, `ssh.example.com` = hostname du tunnel.

## Cycle de changement

Tout changement système suit le même chemin, jamais d'installation à la main :

```bash
$EDITOR inventories/prod/group_vars/all/vars.yml   # ou un rôle
just lint && just check     # lint + dry-run : lire le diff
just provision              # apply
git add -A && git commit && git push
```

Le VPS est du bétail, pas un animal de compagnie : son état complet est le repo
(secrets SOPS inclus) + les clés age + les backups.

## Paquets

Trois niveaux, du plus structurant au plus jetable :

1. **Système (Ansible uniquement)** : ajouter à `devtools_packages` dans `vars.yml`
   → `just provision`. Dépôts officiels Fedora exclusivement. L'utilisateur de
   travail n'a pas ce pouvoir, par conception.
2. **Espace utilisateur (sans privilège)** : binaires statiques dans `~/bin`
   (ex. `uv`, qui donne ensuite Python/outils sans toucher au système).
3. **Expérimentation jetable** : `toolbox create && toolbox enter`, un conteneur
   Fedora rootless où l'utilisateur est root *dans le conteneur* (`dnf install`
   libre), l'hôte n'est jamais touché. `podman rm` et il n'a jamais existé.

## Machines clientes et clés SSH

Une clé par machine, jamais partagée. Ajouter une machine : générer la clé dessus,
ajouter la clé publique à `vps_user_pubkeys` (`just private-edit`), `just provision`.
Révoquer une machine (perte, vol, départ) : retirer sa clé de la liste,
`just provision`, effet immédiat. La clé `admin` (machine de contrôle) suit la même
logique via `vps_admin_pubkeys`.

<details><summary>Git / GitHub depuis le VPS</summary>

Une clé SSH **dédiée au VPS** (fichier, générée sur le VPS), déclarée sur GitHub :

```bash
ssh vps
ssh-keygen -t ed25519 -f ~/.ssh/github_ed25519 -C "vps"
cat ~/.ssh/github_ed25519.pub          # → GitHub > Settings > SSH keys (Authentication)
printf 'Host github.com\n  IdentityFile ~/.ssh/github_ed25519\n' >> ~/.ssh/config
git config --global user.email "…@users.noreply.github.com"
ssh -T git@github.com                   # "Hi <user>! You've successfully authenticated"
```

Une clé de sécurité (YubiKey, `ed25519-sk`) n'est **pas** utilisable depuis le VPS :
elle exige le matériel branché sur la machine qui signe, or la YubiKey est sur la
machine de contrôle. L'agent forwarding qui contournerait cela est volontairement
désactivé (`AllowAgentForwarding no`). La protection ici est la clé **dédiée et
révocable** (doctrine « une clé par machine »), et le fait que le VPS n'est
lui-même joignable que par le tunnel doublement authentifié.

</details>

## Secrets et valeurs identifiantes

Deux fichiers **SOPS** committés, chiffrés (valeurs uniquement) vers des clés
**age matérielles**. Aucun secret racine sur disque : le déchiffrement exige une
YubiKey physique + PIN + toucher.

- `vault.sops.yml` : ce qui **donne un accès** (token du tunnel, mot de passe
  admin, credentials backup) : `just vault-edit`.
- `private.sops.yml` : ce qui **identifie** le déploiement (utilisateur, clés
  publiques, hostname, chemin de la clé Ansible) : `just private-edit`.

Deux destinataires (`.sops.yaml`), n'importe lequel déchiffre seul : YubiKey A
(quotidienne), YubiKey B (secours, rangée ailleurs). Il n'existe volontairement
aucun destinataire logiciel : la perte simultanée des deux clés rend les secrets
irrécupérables, ce qui fait de B un actif critique à stocker hors site.

Usage : `just unlock` en début de session (PIN une fois), puis toucher à chaque run.

Les mêmes YubiKeys portent les clés SSH (`ed25519-sk` résidentes). `private.sops.yml`
déclare la quotidienne ; pour travailler avec celle de secours, passer son chemin :
`just provision ~/.ssh/vps42_bis_sk`. Les poignées se régénèrent sur toute machine
avec `ssh-keygen -K`, la partie privée ne quittant jamais la puce.

Rotations :

- Édition : `just vault-edit` / `just private-edit` (SOPS ouvre en clair, re-chiffre
  à la sauvegarde).
- Token du tunnel : dashboard → Networking → Tunnels → le tunnel → *Rotate token*,
  puis *Add replica* pour lire la nouvelle valeur `eyJ...` (sans exécuter la commande
  proposée) → `just vault-edit` → `just provision`. Les connecteurs actifs survivent
  à la rotation jusqu'à leur redémarrage : l'accès n'est pas coupé dans l'intervalle.
- <details><summary>Mot de passe admin (changer sur le serveur AVANT le vault)</summary>

  Ansible ne peut pas faire ce changement : il s'authentifierait en sudo avec la
  valeur du vault, qui serait déjà la nouvelle alors que le serveur porte encore
  l'ancienne. Le serveur d'abord, le vault ensuite.

  ```bash
  ssh admin@ssh.example.com
  passwd
  exit

  just vault-edit   # y reporter la même valeur
  just check        # valide que become fonctionne toujours
  ```

  </details>
- <details><summary>Remplacer une YubiKey perdue / ajouter un destinataire</summary>

  Une YubiKey porte deux choses : un destinataire age (slot PIV, déchiffrement
  SOPS) et une clé SSH `ed25519-sk` résidente (slot FIDO2, accès au VPS). Les
  deux sont à remplacer.

  ```bash
  age-plugin-yubikey --generate            # nouveau destinataire age
  # remplacer l'ancien recipient dans .sops.yaml, puis :
  just sops-updatekeys

  /opt/homebrew/opt/openssh/bin/ssh-keygen -t ed25519-sk \
    -O resident -O verify-required -O application=ssh:vps \
    -C "vps@yubikey-c" -f ~/.ssh/vps_sk_c
  just private-edit                        # remplacer la pubkey dans les deux listes
  just provision                           # exclusive:true révoque l'ancienne
  ```

  L'ordre des destinataires dans `.sops.yaml` ne se propage pas aux fichiers déjà
  chiffrés (`updatekeys` compare des ensembles). Pour remettre la clé quotidienne
  en tête : `sops rotate -i --rm-age <recipient> <fichier>` puis la même commande
  avec `--add-age`, qui le replace en fin de liste.

  </details>

## Backups

Activation : créer un bucket S3/B2 → `just vault-edit` → renseigner
`vault_restic_repository`, `vault_restic_password`, `vault_restic_env` →
`just provision`. Timer quotidien, rétention 7j/4sem/6mois, chiffrement côté client.

> [!IMPORTANT]
> Une sauvegarde jamais restaurée n'existe pas. Tester après activation puis
> périodiquement :

```bash
ssh vps
sudo -u root bash -c 'set -a; . /etc/restic/restic.env; restic restore latest --target /tmp/restore-test'
```

## Mises à jour

Les correctifs de sécurité s'appliquent automatiquement (`dnf-automatic`), reboot
compris si le kernel l'exige ; une session tmux peut donc disparaître après un
correctif kernel : c'est un comportement voulu. Le reste des paquets est mis à
niveau par `just provision`.

## Dépannage

<details><summary>Table des symptômes et réflexes</summary>

| Symptôme | Réflexe |
|---|---|
| `ssh vps` ne répond plus | Tunnel *Healthy* dans le dashboard ? Sinon console provider : `journalctl -u cloudflared -e` |
| Access refuse l'e-mail | Zero Trust → Access → Applications → vérifier la policy et la méthode One-time PIN |
| Erreur 1033 dans le navigateur | Le tunnel n'a pas de connecteur : cloudflared arrêté côté VPS |
| Clé SSH refusée | `journalctl -u sshd` côté VPS (via console) : shell manquant, `AllowUsers`, contexte SELinux (`restorecon -Rv /home/<user>/.ssh`) |
| Tunnel définitivement mort | Console web du provider = accès de secours : login `admin` + mot de passe du vault |
| `Failed to decrypt YubiKey stanza` | PIN pas en cache : `just unlock` d'abord (contexte non-interactif ne peut pas le demander) |
| YubiKey A et B perdues | Secrets irrécupérables (pas de destinataire logiciel) : reconstruire le VPS à neuf, révoquer le tunnel, régénérer tous les secrets |

</details>

## Reconstruction (disaster recovery)

Prérequis permanents : le repo (tout y est, `private.sops.yml` et `vault.sops.yml`
chiffrés compris) + au moins une des deux YubiKeys + les identités dans
`~/.config/sops/age/keys.txt`. Plus un dépôt restic si activé.

> [!WARNING]
> Sans restic activé, `/home` est perdu. Rapatrier avant de détruire.

**1. Clé jetable.** Les panels d'hébergeur refusent le type `ed25519-sk` ; il faut
une clé logicielle pour la seule connexion au compte cloud. Elle ne sert qu'au
play 1 et disparaît avec ce compte, supprimé en fin de bootstrap.

```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/vps_tmp -C "temporaire-bootstrap"
cat ~/.ssh/vps_tmp.pub     # à déclarer dans le panel du provider
```

**2. Réinstallation.** Image Fedora, clé jetable sélectionnée. Noter l'IP publique,
elle peut changer. Le hostname du tunnel, lui, ne change pas : les clients
existants refonctionneront sans modification.

**3. Empreintes d'hôte.** Le serveur neuf a de nouvelles clés d'hôte, et Ansible ne
sait pas répondre à un prompt (`host_key_checking = True`).

```bash
ssh-keygen -R <ip-publique> && ssh-keygen -R ssh.example.com
ssh <user-cloud>@<ip-publique>    # accepter, vérifier le shell, sortir
```

**4. Bootstrap.**

```bash
just unlock
just bootstrap <ip-publique> <user-cloud>
```

**5. Bascule sur le tunnel.** Attendre le statut *HEALTHY* dans le dashboard Zero
Trust, puis purger à nouveau (même hostname, nouvel hôte) :

```bash
ssh-keygen -R ssh.example.com
ssh dev@ssh.example.com           # accepter, sortir
just provision
just check                        # changed=0 attendu : preuve d'idempotence
```

**6. Nettoyage.** `rm ~/.ssh/vps_tmp*` et retrait de la clé dans le panel. Puis
restauration des données depuis restic si activé.

**7. Vérification.** Voir la section suivante.

## Vérification de conformité

```bash
nmap -Pn <ip-publique>            # 1000 filtered, aucun open
```

```bash
ssh admin@ssh.example.com
ss -tlnp | grep ':22'             # 127.0.0.1 et [::1] uniquement
sudo firewall-cmd --get-target    # DROP
sudo getenforce                   # Enforcing
systemctl is-active cloudflared auditd chronyd
id <user-cloud>                   # "no such user"
```

```bash
ssh dev@ssh.example.com
id                                # aucun groupe privilégié
sudo -l                           # doit refuser
```

Tester aussi la YubiKey de secours seule, et la console web du provider en `admin`
avec le mot de passe du vault : c'est l'unique accès si le tunnel tombe.

## Qualité et garde-fous

- **CI** (`.github/workflows/ci.yml`) : ansible-lint (profil production), yamllint
  et scan de secrets gitleaks sur tout l'historique, à chaque push et pull request.
- **Hooks locaux** : `brew install pre-commit && pre-commit install` (une fois par
  clone). Ensuite chaque commit est scanné (gitleaks, yamllint) avant d'exister ;
  un secret en clair ne peut plus être commité par accident.
- Les deux fichiers `*.sops.yml` (chiffrés) sont en liste blanche gitleaks
  (`.gitleaks.toml`) : blobs à haute entropie sans secret en clair.

## Publication du repo

> [!WARNING]
> Avant tout passage en public, vérifier `git log -p | grep -iE '<valeurs sensibles>'` :
> l'historique git peut contenir d'anciennes valeurs en clair même si les fichiers
> courants sont propres. Au besoin, réinitialiser l'historique (branche orphan).

`vault.sops.yml` et `private.sops.yml` sont publiables : SOPS ne chiffre que les
**valeurs**, vers des clés dont la partie privée ne quitte jamais les puces PIV
des YubiKeys. Aucun secret racine n'est
committé ni gitignoré : il n'y a plus rien à protéger hors du repo, hormis les
clés physiques elles-mêmes.
