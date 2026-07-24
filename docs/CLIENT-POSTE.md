[README](../README.md) · [Architecture](ARCHITECTURE.md) · [Setup](SETUP.md) · [Opérations](OPERATIONS.md) · **Client**

# Accès client (poste restreint ou machine personnelle)

Accès au VPS via le tunnel : le client a seulement besoin du binaire `cloudflared`
et d'une clé SSH dédiée. Le trafic sort en HTTPS/443 et traverse les réseaux
restrictifs comme du trafic web ordinaire. Le flux SSH reste chiffré de bout en
bout : l'empreinte du serveur est vérifiée localement, l'intermédiaire ne
transporte que des octets chiffrés.

Placeholders : `dev`, `ssh.example.com`. Remplacer par vos valeurs.

## Installation de cloudflared (une fois par machine)

**Mode A, poste restreint (ni root ni droits d'installation)** : un binaire
statique dans le home, aucun privilège requis.

```bash
mkdir -p ~/bin
curl -fsSL -o ~/bin/cloudflared \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x ~/bin/cloudflared
~/bin/cloudflared --version   # vérification
```

<details><summary><b>Mode B, machine personnelle (droits admin)</b> : le
gestionnaire de paquets</summary>

```bash
brew install cloudflared      # macOS
sudo dnf install cloudflared  # Fedora (dépôt pkg.cloudflare.com)
cloudflared --version
```

</details>

La suite est identique dans les deux modes ; seule différence, le chemin du
binaire dans le `ProxyCommand` (`~/bin/cloudflared` en mode A, `cloudflared`
en mode B).

## Clé SSH dédiée au poste

Une clé par machine, révocable individuellement sans toucher aux autres :

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_poste -C "dev@poste"
```

Ajouter le contenu de `~/.ssh/id_ed25519_poste.pub` à `vps_user_pubkeys`
(`just private-edit` depuis la machine de contrôle) puis `just provision`.

## Configuration `~/.ssh/config`

```sshconfig
Host vps
  HostName ssh.example.com
  User dev
  IdentityFile ~/.ssh/id_ed25519_poste
  ProxyCommand ~/bin/cloudflared access ssh --hostname %h
```

Puis : `ssh vps`. À la première connexion, cloudflared ouvre une URL
d'authentification Cloudflare Access (code PIN par e-mail ou SSO selon la
policy). La session est valable la durée configurée (24 h par défaut), ensuite
c'est transparent.

## Secours zéro-install

Si même un binaire dans le home est impossible : le *browser rendering* SSH de
Cloudflare Access (application, option « Enable browser rendering ») donne un
terminal dans le navigateur à `https://ssh.example.com`.

> [!WARNING]
> Dans ce mode, l'edge déchiffre la session pour la rendre en HTML : la propriété
> de chiffrement de bout en bout est perdue. À activer consciemment, pour du
> dépannage uniquement, jamais pour des données sensibles, puis à re-désactiver.
