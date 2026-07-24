# Orchestration du repo (prérequis machine de contrôle : docs/SETUP.md phase 2)

set shell := ["bash", "-cu"]

default: check

# Premier provisionnement, via l'IP publique du provider (une seule fois).
# Usage : just bootstrap 203.0.113.10           (login root direct)
#         just bootstrap 203.0.113.10 fedora    (image OVH : user fedora + sudo)
bootstrap ip user="root":
    ansible-playbook playbooks/bootstrap.yml -i '{{ ip }},' -u {{ user }}

provision:
    ansible-playbook playbooks/site.yml

check:
    ansible-playbook playbooks/site.yml --check --diff

lint:
    ansible-lint --offline
    yamllint .

facts:
    ansible all -m setup

ping:
    ansible all -m ping

vault-init:
    ansible-vault create inventories/prod/group_vars/all/vault.yml

vault-edit:
    ansible-vault edit inventories/prod/group_vars/all/vault.yml

private-edit:
    ansible-vault edit inventories/prod/group_vars/all/private.yml
