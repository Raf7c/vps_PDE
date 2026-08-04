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

Trois destinataires (`.sops.yaml`), n'importe lequel déchiffre seul : YubiKey A
(quotidienne), YubiKey B (secours, rangée ailleurs), clé age logicielle (secours
ultime, clé privée dans le gestionnaire de mots de passe).

Usage : `just unlock` en début de session (PIN une fois), puis toucher à chaque run.

Rotations :

- Édition : `just vault-edit` / `just private-edit` (SOPS ouvre en clair, re-chiffre
  à la sauvegarde).
- Token du tunnel : dashboard Zero Trust → rotate → `just vault-edit` → `just provision`.
- <details><summary>Mot de passe admin (le hash n'est posé qu'à la création du compte)</summary>

  `just vault-edit` avec la nouvelle valeur, puis :

  ```bash
  ansible all --become -m ansible.builtin.user \
    -a "name=admin password={{ vault_vps_admin_password | password_hash('sha512') }}"
  ```

  </details>
- <details><summary>Remplacer une YubiKey perdue / ajouter un destinataire</summary>

  Générer l'identité sur la nouvelle clé (`age-plugin-yubikey --generate`),
  ajouter son recipient dans `.sops.yaml`, retirer l'ancien, puis réchiffrer
  les fichiers vers les nouveaux destinataires :

  ```bash
  just sops-updatekeys
  ```

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
| YubiKey A et B perdues | Déchiffrer avec la clé age de secours (gestionnaire de mdp) : `SOPS_AGE_KEY=<clé> sops decrypt ...` |

</details>

## Reconstruction (disaster recovery)

Prérequis permanents : le repo (tout y est, `private.sops.yml` et `vault.sops.yml`
chiffrés compris) + au moins une des clés age (YubiKey ou clé de secours du
gestionnaire de mots de passe) + les identités dans `~/.config/sops/age/keys.txt`.
Plus un dépôt restic si activé.

```bash
# le VPS neuf a de nouvelles clés d'hôte : purger les anciennes empreintes
ssh-keygen -R <ip-publique> && ssh-keygen -R ssh.example.com
# autoriser la clé de la machine de contrôle si le provider ne l'a pas injectée
ssh-copy-id -i ~/.ssh/id_ed25519_laptop.pub <user-cloud>@<ip-publique>

just bootstrap <ip-publique> [user-cloud]
just provision
# restauration des données depuis restic si activé
```

Le hostname du tunnel ne change pas : les clients existants refonctionnent sans
modification.

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
**valeurs**, vers des clés dont la partie privée vit dans les YubiKeys (ou le
gestionnaire de mots de passe pour la clé de secours). Aucun secret racine n'est
committé ni gitignoré : il n'y a plus rien à protéger hors du repo, hormis les
clés physiques elles-mêmes.
