#!/bin/bash
# Script d'installation pour OpenVPN Access Server  
# Le script installera automatiquement OpenVPN Access Server selon la distribution Linux utilisée
#
# Copyright 2024 OpenVPN Inc. All Rights Reserved.
#

set -eu

ARCH=""
PLIST="openvpn-as"
DCO_NAME="openvpn-dco-dkms"

abort() {
    echo "Cette $PRETTY_NAME $ARCH distribution n'est pas officiellement supportée. Installation avortée" >&2
    exit 1
}

repo_error() {
    echo
    echo "Désolé, le gestionnaire de paquets de votre système rapporte un problème sans en préciser la source" >&2
    echo "Veuillez consulter notre documentation en ligne ou contactez l'équipe de support pour une assistance." >&2
    echo
    echo "L'installation doit être interrompue" >&2
    exit 4
}

initialization() {
    if [ -f "/etc/os-release" ]; then
        . /etc/os-release
    else
        echo "Impossible de détecter l'OS/distribution. Installation avortée" >&2
        exit 1
    fi

    case $(uname -m) in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *)       abort ;;
    esac

    if [[ "$ARCH" == "arm64" && "$ID" != "ubuntu" ]]; then
        abort
    fi
}

install_packages() {
    initialization

    case $ID in
        ubuntu|debian)
            install_deb
            ;;
        rhel|centos|rocky|almalinux|ol|amzn)
            DCO_NAME="kmod-ovpn-dco"
            install_rpm
            ;;
        *)
            abort
            ;;
    esac
}

install_deb() {
    DISTRO_LIST="buster bullseye bookworm focal jammy noble"
    if echo $DISTRO_LIST |grep -q $VERSION_CODENAME ; then
        confirmation_prompt

        apt update || repo_error
        DEBIAN_FRONTEND=noninteractive apt -y install ca-certificates wget net-tools gnupg || repo_error
        mkdir -p /etc/apt/keyrings
        wget https://as-repository.openvpn.net/as-repo-public.asc -qO /etc/apt/keyrings/as-repository.asc
        echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/as-repository.asc] http://as-repository.openvpn.net/as/debian $VERSION_CODENAME main" > /etc/apt/sources.list.d/openvpn-as-repo.list
        apt update || repo_error
        DEBIAN_FRONTEND=noninteractive apt -y install $PLIST || repo_error
    else
        abort
    fi
    if echo $VERSION_CODENAME |grep -qv buster ; then
        if install_dco "deb" ; then
            apt update || repo_error
            DEBIAN_FRONTEND=noninteractive apt -y install $DCO_NAME || repo_error
        fi
    fi
}

install_rpm() {
    RELEASE=$(echo $VERSION_ID |sed 's/\.[0-9]*//')
    DIST=$ID
    RPM_CLONES="rocky almalinux ol"

    if echo $RPM_CLONES |grep -q $ID ; then
        echo "ATTENTION : Cet OS Linux est un clone RHEL qui n'est pas supporté officiellement," >&2
        echo "cependant, en théorie, il est compatible avec le dépôt RHEL que nous prenons en charge" >&2
        echo "Ce devrait être compatible mais il n'y a aucune garantie que cela fonctionne comme attendu" >&2
    fi

    yum repolist || repo_error

    if [[ "$RELEASE" == "7" ]]; then
        if [[ "$ID" == "rhel" ]]; then
            confirmation_prompt
            subscription-manager repos --enable rhel-7-server-optional-rpms --enable rhel-server-rhscl-7-rpms || repo_error
        elif [[ "$ID" == "centos" ]]; then
            confirmation_prompt
            yum -y install centos-release-scl-rh || repo_error
        fi
        DIST="centos"
    elif [[ "$RELEASE" == "8" || "$RELEASE" == "9" ]]; then
        confirmation_prompt
        DIST="rhel"
    elif [[ "$ID" == "amzn" && "$RELEASE" == "2" ]]; then
        confirmation_prompt
    else
        abort
    fi

    yum -y remove openvpn-as-yum || repo_error
    yum -y install "https://as-repository.openvpn.net/as-repo-${DIST}${RELEASE}.rpm" || repo_error
    yum -y install $PLIST || repo_error

    if [[ "$RELEASE" == "8" || "$RELEASE" == "9" ]]; then
        if install_dco "rpm" ; then
            if [[ "$ID" == "rocky" || "$ID" == "almalinux" ]]; then
                if [[ "$RELEASE" == "8" ]]; then
                    yum config-manager --set-enabled powertools || repo_error
                elif [[ "$RELEASE" == "9" ]]; then
                    yum config-manager --set-enabled crb || repo_error
                fi
                yum -y install epel-release || repo_error
            elif [[ "$ID" == "rhel" ]]; then
                yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-"$RELEASE".noarch.rpm || repo_error
            fi
            yum -y install $DCO_NAME || repo_error
        fi
    fi
}

install_dco() {
    echo
   
    echo "Les versions d'Access Server 2.12 et au-dessus supporte l'OpenVPN Data Channel Offload (DCO)."
    echo   
    echo "Avec DCO vous pouvez bénéficier d'améliorations des performances en activant DCO sur votre serveur VPN et les clients"
    echo
    echo "DCO change la gestion des données du tunnel VPN"
    echo "Le chiffrage/déchiffrage est déchargé vers le noyau plutôt que de gérer ça dans l'espace utilisateur"
    echo "Utilise le multi-threading et copie les opérations du noyau vers l'espace utilisateur."
    echo
    echo "Explications DCO : https://openvpn.net/as-docs/openvpn-data-channel-offload.html##"
    echo "OpenVPN DCO est un module chargeable optionellement installé et utilisé avec Access Server."
    echo
    echo "La version de votre noyau en fonction est : '$(uname -r)'"
    echo
    echo "DCO a besoin des headers du noyau pour être installé"
    echo "Si ces headers ne sont pas présents, ils seront installés automatiquement"
    echo
    read -p "Voulez-vous installer OpenVPN Data Channel Offload? (oui/NON): " resp

    if [[ "$resp" = 'OUI' || "$resp" = 'oui' ]]; then
        if check_install_headers "$1" ; then
            echo
            echo "Les headers du noyau Linux sont installés. Passage à l'installation de DCO"
            echo
            echo "Souvenez-vous que si de nouvelles versions du noyau sont disponibles,"
            echo "il est possible que l'installation de DCO échoue."
            return 0
        else
            echo
            echo "ATTENTION : Les headers du noyau actuel n'ont pu être ni localisés ni installés" >&2
            echo "Veuillez consulter notre documentation en ligne ou contactez l'équipe de support pour plus d'assistance" >&2
            echo "https://openvpn.net/vpn-server-resources/openvpn-dco-access-server/" >&2
            echo
            echo "DCO ne peut pas être installé, ignoré" >&2
        fi
    fi
    return 101
}

check_install_headers() {
    if [[ "$1" == "rpm" ]]; then
        if rpm -q kernel-headers-$(uname -r) ; then
            return 0
        else
            if yum -y install kernel-headers-$(uname -r) kernel-devel-$(uname -r) ; then
                return 0
            fi
        fi
    elif [[ "$1" == "deb" ]]; then
        if dpkg -l |grep linux-headers-$(uname -r) ; then
            return 0
        else
            apt update || repo_error
            if apt -y install linux-headers-$(uname -r) ; then
                return 0
            fi
        fi
    fi
    return 100
}

confirmation_prompt() {
    echo "Si vous êtes prêt à installer OpenVPN Access Server, continuez dessous"
    echo
    echo "Linux, distribution détectée : $PRETTY_NAME $ARCH"
    read -p "Voulez-vous procéder à l'installation ? (oui/NON): " response

    if [[ "$response" != "OUI" && "$response" != "oui" ]]; then
        echo "Installation avortée." >&2
        exit 0
    fi
}

echo
echo
echo "Bienvenue sur l'installation d'OpenVPN Access Server !"
echo
echo
echo "ttention : Veuillez avant vérifier qu'il n'y a aucune mise à jour de sécurité"
echo "ou du noyau pour votre système"
echo "Il est recommandé de les installer avant de procéder à toute installation"
echo

install_packages

echo
echo "Nouvelle Installation Réussie!"
