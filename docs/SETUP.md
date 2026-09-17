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
3. Un **tunnel** nommé (type *Cloudflared*). Le token se lit dans Networking →
   Tunnels → le tunnel → *Add replica* : c'est la chaîne `eyJ...` de la commande
   d'installation affichée. Le copier dans un gestionnaire de mots de passe (il
   ira dans le vault en phase 3).
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
# macOS : ansible, lint, just, cloudflared, nmap + chaîne SOPS/age.
# openssh est requis : le ssh-keygen d'Apple ne gère pas les clés FIDO (-sk).
brew install ansible ansible-lint yamllint just cloudflared nmap \
             sops age-plugin-yubikey ykman openssh pre-commit
pre-commit install                              # hooks anti-secrets (gitleaks)
ansible-galaxy collection install -r requirements.yml
```

Une clé SSH **par YubiKey**, résidente dans la puce FIDO2 : le fichier local n'est
qu'une poignée, inutilisable sans la clé physique. `application` distingue les
clés lors d'une extraction ultérieure par `ssh-keygen -K` sur une machine neuve.

```bash
/opt/homebrew/opt/openssh/bin/ssh-keygen -t ed25519-sk \
  -O resident -O verify-required -O application=ssh:vps \
  -C "vps@yubikey-a" -f ~/.ssh/vps_sk_a
```

Répéter avec la seconde YubiKey (`application=ssh:vps-b`, `-f ~/.ssh/vps_sk_b`).
`verify-required` ajoute le PIN FIDO2 au toucher : deux facteurs par connexion, au
prix de tout usage non interactif (cron, CI).

Les secrets sont chiffrés avec SOPS vers des clés **age matérielles**, portées par
les mêmes YubiKeys dans leur slot PIV : enregistrement des identités dans
`~/.config/sops/age/keys.txt` et durcissement des clés (PIN, PUK, management key
TDES), voir [OPERATIONS.md](OPERATIONS.md#secrets).

Vérification :

- [ ] `just --version`, `sops --version`, `cloudflared --version` répondent

## Phase 3 : Configuration du repo

Les destinataires de chiffrement (recipients des deux YubiKeys) sont
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

Prérequis : VPS Fedora joignable sur son IP publique, avec une clé autorisée sur le
compte cloud. Les panels d'hébergeur refusent en général le type `ed25519-sk`, d'où
une clé logicielle jetable, utilisée par le seul play 1 et disparaissant avec le
compte cloud que le play 2 supprime.

```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/vps_tmp -C "temporaire-bootstrap"
# déclarer ~/.ssh/vps_tmp.pub dans le panel du provider, puis :

# Image cloud avec user sudo (ex. OVH → "fedora") :
just bootstrap 203.0.113.10 fedora
# Provider avec login root direct :
just bootstrap 203.0.113.10
# Autre chemin pour la clé jetable (défaut : ~/.ssh/vps_tmp) :
just bootstrap 203.0.113.10 fedora ~/.ssh/autre
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
  IdentityFile ~/.ssh/vps_sk_a
  IdentityFile ~/.ssh/vps_sk_b
  IdentitiesOnly yes
  ProxyCommand cloudflared access ssh --hostname %h
```

Les deux `IdentityFile` laissent ssh retenir celle dont la YubiKey est branchée.
Ansible, lui, reste explicite : la clé quotidienne vient de `private.sops.yml`,
celle de secours se passe en argument (`just provision ~/.ssh/vps_sk_b`).

Une fois le bootstrap validé, supprimer la clé jetable (`rm ~/.ssh/vps_tmp*`) et
la retirer du panel du provider.

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
