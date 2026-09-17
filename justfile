# Orchestration du repo (prérequis machine de contrôle : docs/SETUP.md phase 2)

set shell := ["bash", "-cu"]

default: check

# Réveille la YubiKey : saisit le PIN une fois (policy « once per session »),
# mis en cache tant que la clé reste branchée. Les commandes just suivantes ne
# demandent alors plus que le toucher physique. À lancer en début de session.
unlock:
    @sops decrypt inventories/prod/group_vars/all/vault.sops.yml > /dev/null && echo "YubiKey déverrouillée pour la session."

# Premier provisionnement, via l'IP publique du provider (une seule fois).
# Usage : just bootstrap 203.0.113.10                        (login root direct)
#         just bootstrap 203.0.113.10 fedora                 (image OVH : user fedora + sudo)
#         just bootstrap 203.0.113.10 fedora ~/.ssh/autre    (autre clé jetable)
# Inventaire prod (→ secrets SOPS chargés par le vars-plugin), mais on force
# l'IP publique et la connexion directe (le tunnel n'existe pas encore).
# La clé jetable ne sert qu'au play 1 : voir le commentaire dans bootstrap.yml.
bootstrap ip user="root" key="~/.ssh/vps_tmp":
    ansible-playbook playbooks/bootstrap.yml \
      -i inventories/prod/hosts.yml \
      -e ansible_host={{ ip }} -e ansible_ssh_common_args='' \
      -e bootstrap_cloud_user={{ user }} \
      -e bootstrap_cloud_key={{ key }}

# Sans argument : la clé déclarée dans private.sops.yml (YubiKey quotidienne).
# Avec la YubiKey de secours :  just provision ~/.ssh/vps42_bis_sk
provision key="":
    ansible-playbook playbooks/site.yml {{ if key == "" { "" } else { "-e ansible_ssh_private_key_file=" + key } }}

check key="":
    ansible-playbook playbooks/site.yml --check --diff {{ if key == "" { "" } else { "-e ansible_ssh_private_key_file=" + key } }}

lint:
    ansible-lint --offline
    yamllint .

facts:
    ansible all -m setup

ping:
    ansible all -m ping

# Édition des fichiers chiffrés (SOPS ouvre en clair, re-chiffre à la sauvegarde ;
# YubiKey requise : toucher demandé). Rotation des destinataires après édition
# de .sops.yaml : just sops-updatekeys
vault-edit:
    sops edit inventories/prod/group_vars/all/vault.sops.yml

private-edit:
    sops edit inventories/prod/group_vars/all/private.sops.yml

sops-updatekeys:
    sops updatekeys inventories/prod/group_vars/all/vault.sops.yml
    sops updatekeys inventories/prod/group_vars/all/private.sops.yml
