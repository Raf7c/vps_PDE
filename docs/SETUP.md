[README](../README.md) · [Architecture](ARCHITECTURE.md) · **Setup** · [Opérations](OPERATIONS.md) · [Client](CLIENT-POSTE.md)

# Setup

Runbook initial, à dérouler une seule fois et dans l'ordre. Chaque phase se termine
par une **vérification** : ne pas passer à la suivante tant qu'elle n'est pas
satisfaite. L'exploitation courante est couverte par [OPERATIONS.md](OPERATIONS.md).

Placeholders utilisés : `dev` (utilisateur de travail), `ssh.example.com` (hostname
du tunnel), `203.0.113.10` (IP publique du VPS). Remplacer par vos valeurs.

## Phase 1 : Cloudflare

Objectif : un compte Zero Trust avec un tunnel dont seul le **token** nous importe.
À réaliser (l'interface évolue ; référence :
[doc officielle Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/)) :

> [!IMPORTANT]
> Ne jamais exécuter les commandes d'installation proposées par le dashboard :
> l'installation côté serveur est du ressort exclusif d'Ansible.

1. Compte Cloudflare avec **MFA activé** (il contrôle l'accès au VPS) + domaine
   rattaché (statut *Active* ; DNSSEC désactivé chez le registrar au préalable).
2. Zero Trust activé (plan Free suffisant).
3. Un **tunnel** nommé (type *Cloudflared*) → copier le token `eyJ...` dans un
   gestionnaire de mots de passe (il ira dans le vault en phase 3).
4. Un **ingress** : `ssh.example.com` → `ssh://localhost:22`.
5. Une **application Access** *Self-hosted* sur ce hostname : policy Allow limitée
   à l'adresse e-mail autorisée, session 24 h, *browser rendering* désactivé,
   méthode One-time PIN active.

Vérification :

- [ ] `https://ssh.example.com` affiche la page de login Access
- [ ] l'e-mail autorisé reçoit un code PIN et passe le login
- [ ] l'erreur 1033 qui suit est attendue (le tunnel n'a pas encore de connecteur)

## Phase 2 : Machine de contrôle

```bash
# macOS : ansible, lint, just, cloudflared, nmap + chaîne SOPS/age
brew install ansible ansible-lint yamllint just cloudflared nmap \
             sops age-plugin-yubikey pre-commit
pre-commit install                              # hooks anti-secrets (gitleaks)
ansible-galaxy collection install -r requirements.yml

# Une clé SSH par machine cliente
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_laptop -C "dev@laptop"
ssh-add --apple-use-keychain ~/.ssh/id_ed25519_laptop   # macOS
```

Les secrets sont chiffrés avec SOPS vers des clés **age matérielles** (YubiKey) :
enregistrement des identités dans `~/.config/sops/age/keys.txt` et durcissement
des clés (PIN, PUK, management key TDES) — voir [OPERATIONS.md](OPERATIONS.md#secrets).

Vérification :

- [ ] `just --version`, `sops --version`, `cloudflared --version` répondent

## Phase 3 : Configuration du repo

Les destinataires de chiffrement (recipients des YubiKeys + clé de secours) sont
déclarés dans `.sops.yaml`. Créer les deux fichiers depuis leurs modèles, les
remplir, puis les chiffrer avec SOPS :

```bash
cd inventories/prod/group_vars/all

# Valeurs identifiantes : user, clés publiques, hostname, clé privée Ansible
cp private.sops.yml.example private.sops.yml && $EDITOR private.sops.yml
sops encrypt -i private.sops.yml

# Secrets : token du tunnel, mot de passe admin, credentials backup
cp vault.sops.yml.example vault.sops.yml && $EDITOR vault.sops.yml
sops encrypt -i vault.sops.yml
cd -
```

Vérification :

- [ ] `grep -q 'sops:' vault.sops.yml` et idem `private.sops.yml` (fichiers chiffrés)
- [ ] `sops decrypt vault.sops.yml` affiche le clair (PIN + toucher YubiKey)
- [ ] `just lint` passe

## Phase 4 : Bootstrap

> [!NOTE]
> Chaque session : `just unlock` une fois (saisit le PIN, mis en cache tant que
> la YubiKey reste branchée). Les commandes suivantes ne demandent que le toucher.

Prérequis : VPS Fedora joignable sur son IP publique, avec la clé de la machine de
contrôle autorisée (sinon `ssh-copy-id` au préalable).

```bash
# Image cloud avec user sudo (ex. OVH → "fedora") :
just bootstrap 203.0.113.10 fedora
# Provider avec login root direct :
just bootstrap 203.0.113.10
```

Deux plays dans le même run : le compte cloud du provider sert uniquement à
créer `admin` (play 1), puis tout s'exécute en `admin` (play 2) : compte `dev`
sans privilège, paquets de base, mises à jour automatiques, cloudflared connecté
au tunnel, sshd verrouillé sur localhost, firewall public en DROP, et
**suppression du compte cloud**. La fenêtre d'exposition publique se referme à
la fin de ce run, définitivement.

> [!IMPORTANT]
> Garder un accès console provider ouvert tant que toutes les vérifications ne
> sont pas vertes : c'est la porte de secours si le tunnel ne monte pas.

Vérification :

- [ ] dashboard Zero Trust → tunnel : **Healthy**
- [ ] `nmap -Pn 203.0.113.10` → tous les ports `filtered`, aucun `open`
- [ ] `ssh vps` aboutit via le tunnel, avec ce bloc `~/.ssh/config` :

```sshconfig
Host vps
  HostName ssh.example.com
  User dev
  IdentityFile ~/.ssh/id_ed25519_laptop
  ProxyCommand cloudflared access ssh --hostname %h
```

## Phase 5 : Provisionnement complet

```bash
just check       # dry-run : lire le diff
just provision   # état complet : outils de dev, backups éventuels
```

Vérification :

- [ ] `ssh vps 'gcc --version | head -1 && make -v | head -1 && valgrind --version && tmux -V && podman --version'`
- [ ] `ssh vps 'sudo -l'` est **refusé** (aucun privilège pour `dev`)
- [ ] `ssh vps 'id fedora'` → no such user
- [ ] commit + push : le repo ne contient que du générique, du chiffré et du public

## Phase 6 : Poste restreint

Suivre [CLIENT-POSTE.md](CLIENT-POSTE.md) : binaire `cloudflared` dans `~/bin`,
clé dédiée, bloc `~/.ssh/config`. Ajouter la clé publique du poste à
`vps_user_pubkeys` (`just private-edit`) puis `just provision` depuis la machine
de contrôle.
