#!/usr/bin/env bash
#
# install-auditd-rules.sh
# -----------------------------------------------------------------------------
# Instala o Linux Audit Daemon (auditd) de forma idempotente e multi-distro e
# substitui o ruleset padrão (que vem vazio após a instalação) por um ruleset
# de auditoria de melhores práticas.
#
# Estratégia de obtenção do ruleset:
#   1. Tenta BAIXAR a versão mais recente do repositório oficial (curl/wget);
#   2. Se o download falhar (ou em modo --offline), usa a cópia AUTO-CONTIDA
#      embutida ao final deste próprio script.
# Assim o script é um único arquivo portável que sempre tem um ruleset válido.
#
# O ruleset é o "Linux Audit Daemon - Best Practice Configuration" de autoria
# de Florian Roth / Nextron Systems:
#
#     https://github.com/Neo23x0/auditd          (Apache License 2.0)
#
# Os devidos créditos ao autor original estão na cópia embutida (ver função
# print_embedded_rules, ao final) e no NOTICE deste projeto.
#
# Distros suportadas: Debian/Ubuntu, RHEL/CentOS/Rocky/Alma/Fedora,
#                     openSUSE/SLES, Arch e Alpine (best effort).
#
# Autor do instalador : Bruno Santos
# Licença             : Apache License 2.0 (ver ./LICENSE)
# -----------------------------------------------------------------------------

set -Eeuo pipefail

# =============================================================================
# Metadados
# =============================================================================
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="2.1.0"

# =============================================================================
# Configuração padrão (sobrescrevível por variáveis de ambiente ou flags)
# =============================================================================
AUDIT_RULES_DST="/etc/audit/rules.d/audit.rules"
RULES_URL="${RULES_URL:-https://raw.githubusercontent.com/Neo23x0/auditd/master/audit.rules}"

# Flags de comportamento.
RULES_OVERRIDE=""     # caminho de ruleset informado via --rules (prioridade máx.)
DRY_RUN=0
ASSUME_YES=0
MAKE_IMMUTABLE=0      # adiciona "-e 2" (regras imutáveis até reboot)
ALLOW_DOWNLOAD=1      # 1 = tenta baixar a versão mais recente; 0 = só embutido

# Timestamp único para backups desta execução.
readonly RUN_TS="$(date +%Y%m%d-%H%M%S)"

# =============================================================================
# Infraestrutura de log (com cores quando em terminal interativo)
# =============================================================================
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_INFO=$'\033[34m'; C_OK=$'\033[32m'
    C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'
else
    C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""
fi

_log() { # _log <cor> <rótulo> <mensagem...>
    local color="$1" label="$2"; shift 2
    printf '%s%s[%s]%s %s\n' "$color" "$C_DIM" "$label" "$C_RESET" "$*" >&2
}
log_info()  { _log "$C_INFO" "INFO" "$@"; }
log_ok()    { _log "$C_OK"   " OK " "$@"; }
log_warn()  { _log "$C_WARN" "WARN" "$@"; }
log_error() { _log "$C_ERR"  "ERRO" "$@"; }

die() { log_error "$@"; exit 1; }

# Executa um comando respeitando o modo dry-run.
run() {
    if (( DRY_RUN )); then
        log_info "[dry-run] $*"
        return 0
    fi
    "$@"
}

# =============================================================================
# Trap de erro: reporta o comando e a linha que falharam
# =============================================================================
on_error() {
    local exit_code=$?
    local line="${1:-?}"
    log_error "Falha (código ${exit_code}) na linha ${line}: comando '${BASH_COMMAND}'"
    log_error "Abortando. Nenhuma alteração adicional foi feita."
    exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

# =============================================================================
# Ajuda / versão
# =============================================================================
usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

Instala o auditd (multi-distro) e substitui o ruleset padrão pelo template de
melhores práticas de Florian Roth / Nextron Systems
(https://github.com/Neo23x0/auditd).

O ruleset é baixado da versão mais recente do repositório; se o download
falhar (ou com --offline), uma cópia embutida no próprio script é usada.

USO:
    sudo ./${SCRIPT_NAME} [opções]

OPÇÕES:
        --rules ARQUIVO   Usa este ruleset (ignora download e cópia embutida)
        --immutable       Torna as regras imutáveis (-e 2) até o próximo boot
        --offline         Não baixa; usa diretamente a cópia embutida
    -y, --yes             Não pergunta confirmação em ações destrutivas
    -n, --dry-run         Mostra o que faria, sem alterar o sistema
    -h, --help            Esta ajuda
    -V, --version         Versão

VARIÁVEL DE AMBIENTE: RULES_URL (sobrescreve a URL de download do ruleset).

EXEMPLOS:
    sudo ./${SCRIPT_NAME}                       # baixa (ou embutido) e aplica
    sudo ./${SCRIPT_NAME} --offline             # usa só a cópia embutida
    sudo ./${SCRIPT_NAME} --dry-run             # simulação, sem alterar nada
EOF
}

# =============================================================================
# Parsing de argumentos
# =============================================================================
parse_args() {
    while (( $# )); do
        case "$1" in
            --rules)       RULES_OVERRIDE="${2:?--rules requer um valor}"; shift 2;;
            --immutable)   MAKE_IMMUTABLE=1; shift;;
            --offline)     ALLOW_DOWNLOAD=0; shift;;
            -y|--yes)      ASSUME_YES=1; shift;;
            -n|--dry-run)  DRY_RUN=1; shift;;
            -h|--help)     usage; exit 0;;
            -V|--version)  printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0;;
            --)            shift; break;;
            -*)            die "Opção desconhecida: $1 (use --help)";;
            *)             die "Argumento inesperado: $1 (use --help)";;
        esac
    done
}

# =============================================================================
# Helpers de ambiente
# =============================================================================
have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
    if (( EUID != 0 )); then
        die "Este script precisa ser executado como root (use sudo). Usuário atual: $(id -un)"
    fi
    log_ok "Executando como root (UID 0)."
}

# Identifica a distro a partir do /etc/os-release.
detect_distro() {
    DISTRO_ID="desconhecida"; DISTRO_NAME="Linux"
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-desconhecida}"
        DISTRO_NAME="${PRETTY_NAME:-${NAME:-Linux}}"
    fi
    log_info "Distribuição detectada: ${DISTRO_NAME} (id=${DISTRO_ID})"
}

# Detecta o gerenciador de pacotes disponível.
detect_pkg_mgr() {
    if   have apt-get; then PKG_MGR="apt"
    elif have dnf;     then PKG_MGR="dnf"
    elif have yum;     then PKG_MGR="yum"
    elif have zypper;  then PKG_MGR="zypper"
    elif have pacman;  then PKG_MGR="pacman"
    elif have apk;     then PKG_MGR="apk"
    else PKG_MGR=""; fi
}

# Instala um conjunto de pacotes usando o gerenciador detectado.
pkg_install() { # pkg_install <pacote...>
    [[ -n "$PKG_MGR" ]] || die "Nenhum gerenciador de pacotes suportado encontrado. Instale manualmente: $*"
    log_info "Instalando via ${PKG_MGR}: $*"
    case "$PKG_MGR" in
        apt)    run env DEBIAN_FRONTEND=noninteractive apt-get update -qq
                run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        dnf)    run dnf install -y "$@" ;;
        yum)    run yum install -y "$@" ;;
        zypper) run zypper --non-interactive install -y "$@" ;;
        pacman) run pacman -Sy --noconfirm "$@" ;;
        apk)    run apk add --no-cache "$@" ;;
    esac
}

# Nomes de pacote do auditd variam conforme a distro.
audit_pkgs() {
    case "$PKG_MGR" in
        apt) echo "auditd audispd-plugins" ;;
        *)   echo "audit" ;;
    esac
}

# ---------------------------------------------------------------------------
# Abstração de serviço (systemd preferencial, com fallback para service/rc)
# ---------------------------------------------------------------------------
svc_active() { # svc_active <serviço>
    if have systemctl; then systemctl is-active --quiet "$1"
    elif have service; then service "$1" status >/dev/null 2>&1
    else rc-service "$1" status >/dev/null 2>&1
    fi
}

svc_enable() { # habilita no boot (best effort)
    if have systemctl; then run systemctl enable "$1" >/dev/null 2>&1 || true
    elif have rc-update; then run rc-update add "$1" default >/dev/null 2>&1 || true
    fi
}

svc_start() {
    if have systemctl; then run systemctl start "$1"
    elif have service; then run service "$1" start
    else run rc-service "$1" start
    fi
}

# Faz backup de um arquivo antes de sobrescrevê-lo.
backup_file() { # backup_file <arquivo>
    local f="$1"
    [[ -f "$f" ]] || return 0
    local bak="${f}.bak-${RUN_TS}"
    run cp -a -- "$f" "$bak"
    log_info "Backup criado: ${bak}"
}

# =============================================================================
# Etapas da instalação
# =============================================================================

ensure_auditd_installed() {
    if have auditctl; then
        log_ok "auditd já está instalado."
        return
    fi
    log_warn "auditd não encontrado; instalando..."
    # shellcheck disable=SC2046
    pkg_install $(audit_pkgs)
    have auditctl || die "auditd não pôde ser instalado/encontrado após a instalação."
    log_ok "auditd instalado."
}

ensure_auditd_running() {
    svc_enable auditd
    if ! svc_active auditd; then
        log_warn "Serviço auditd não está ativo; iniciando..."
        svc_start auditd
        (( DRY_RUN )) || svc_active auditd || die "Não foi possível iniciar o auditd."
    fi
    log_ok "Serviço auditd ativo."
}

# Baixa o ruleset para o arquivo informado. Retorna 0 em sucesso.
# (Não usa o wrapper 'run': baixar para um temp não altera o sistema.)
download_rules() { # download_rules <arquivo_destino>
    local out="$1"
    if have curl; then
        curl -fsSL --connect-timeout 10 --max-time 30 "$RULES_URL" -o "$out" 2>/dev/null
    elif have wget; then
        wget -q --timeout=30 -O "$out" "$RULES_URL" 2>/dev/null
    else
        return 1
    fi
    # Considera válido apenas se veio conteúdo de regras de fato.
    [[ -s "$out" ]] && grep -q '^-' "$out"
}

# Resolve a origem do ruleset segundo a estratégia:
#   --rules > download (mais recente) > cópia embutida (fallback)
# Ao final, RULES_SOURCE aponta para o arquivo a ser aplicado.
resolve_rules_source() {
    # 1. Override explícito do usuário.
    if [[ -n "$RULES_OVERRIDE" ]]; then
        [[ -f "$RULES_OVERRIDE" ]] || die "Arquivo informado em --rules não encontrado: $RULES_OVERRIDE"
        RULES_SOURCE="$RULES_OVERRIDE"
        log_ok "Usando ruleset informado via --rules: ${RULES_SOURCE}"
        return
    fi

    local tmp; tmp="$(mktemp)"

    # 2. Tenta baixar a versão mais recente.
    if (( ALLOW_DOWNLOAD )); then
        log_info "Baixando o ruleset mais recente de ${RULES_URL}..."
        if download_rules "$tmp"; then
            RULES_SOURCE="$tmp"
            log_ok "Ruleset baixado (versão mais recente do repositório)."
            return
        fi
        log_warn "Não foi possível baixar o ruleset; usando a cópia embutida no script."
    else
        log_info "Modo offline: usando a cópia embutida no script."
    fi

    # 3. Fallback: cópia auto-contida embutida neste script.
    print_embedded_rules > "$tmp"
    [[ -s "$tmp" ]] || die "Cópia embutida do ruleset está vazia (script corrompido?)."
    RULES_SOURCE="$tmp"
    log_ok "Usando a cópia embutida do ruleset (fallback offline)."
}

apply_audit_rules() {
    resolve_rules_source

    # Limpa as regras atualmente carregadas no kernel.
    log_info "Limpando regras de auditoria atualmente carregadas (auditctl -D)..."
    if (( ! DRY_RUN )); then
        auditctl -D >/dev/null 2>&1 || log_warn "auditctl -D retornou erro (pode estar em modo imutável); seguindo."
    fi

    # Substitui o ruleset padrão (vazio) em rules.d, com backup do anterior.
    run install -d -m 0750 "$(dirname -- "$AUDIT_RULES_DST")"
    backup_file "$AUDIT_RULES_DST"
    log_info "Substituindo o ruleset em ${AUDIT_RULES_DST}..."
    run install -m 0640 -- "$RULES_SOURCE" "$AUDIT_RULES_DST"

    # Opcionalmente torna as regras imutáveis (precisa vir por último).
    if (( MAKE_IMMUTABLE )); then
        log_info "Adicionando flag de imutabilidade (-e 2)..."
        if (( ! DRY_RUN )); then
            printf '\n# Tornar a configuração imutável até o próximo boot\n-e 2\n' >> "$AUDIT_RULES_DST"
        fi
    fi

    # Recarrega as regras.
    log_info "Recarregando regras de auditoria..."
    if have augenrules; then
        if run augenrules --load; then
            log_ok "Regras recarregadas com augenrules."
        else
            die "Falha ao recarregar regras com augenrules. Verifique a sintaxe do ruleset."
        fi
    else
        if run auditctl -R "$AUDIT_RULES_DST"; then
            log_ok "Regras recarregadas com auditctl."
        else
            die "Falha ao recarregar regras com auditctl. Verifique a sintaxe do ruleset."
        fi
    fi

    # Relatório rápido.
    if (( ! DRY_RUN )) && have auditctl; then
        local n; n="$(auditctl -l 2>/dev/null | grep -vc '^No rules$' || true)"
        log_info "Regras atualmente carregadas no kernel: ${n}"
    fi
}

print_summary() {
    log_ok "Concluído."
    {
        printf '\n%s==== Resumo ====%s\n' "$C_OK" "$C_RESET"
        printf '  Ruleset aplicado : %s -> %s\n' "$RULES_SOURCE" "$AUDIT_RULES_DST"
        printf '  Regras imutáveis : %s\n' "$( ((MAKE_IMMUTABLE)) && echo sim || echo não )"
        printf '\nVerifique com:  auditctl -s   |   auditctl -l   |   ausearch -k susp_activity\n'
    } >&2
}

# =============================================================================
# Main
# =============================================================================
main() {
    parse_args "$@"

    log_info "${SCRIPT_NAME} v${SCRIPT_VERSION} — iniciando$( ((DRY_RUN)) && echo ' (DRY-RUN)' )"
    require_root
    detect_distro
    detect_pkg_mgr

    ensure_auditd_installed
    ensure_auditd_running
    apply_audit_rules

    print_summary
}

# =============================================================================
# Cópia AUTO-CONTIDA do ruleset (fallback offline)
# -----------------------------------------------------------------------------
# Conteúdo abaixo é o "Linux Audit Daemon - Best Practice Configuration" de
# Florian Roth / Nextron Systems (https://github.com/Neo23x0/auditd), Apache-2.0,
# redistribuído SEM modificações. Atualize-o periodicamente com:
#   curl -fsSL https://raw.githubusercontent.com/Neo23x0/auditd/master/audit.rules
# O heredoc usa aspas simples ('__NEO23X0_AUDIT_RULES__'): nada é expandido.
# =============================================================================
print_embedded_rules() {
    cat <<'__NEO23X0_AUDIT_RULES__'
#      ___             ___ __      __
#     /   | __  ______/ (_) /_____/ /
#    / /| |/ / / / __  / / __/ __  /
#   / ___ / /_/ / /_/ / / /_/ /_/ /
#  /_/  |_\__,_/\__,_/_/\__/\__,_/
#
# Linux Audit Daemon - Best Practice Configuration
# /etc/audit/audit.rules
#
# Maintained by Nextron Systems (https://www.nextron-systems.com)
#
# These rules provide broad, high-fidelity telemetry for Linux hosts.
# Detection intelligence (specific tool signatures, behavioral patterns,
# threat-actor TTPs) belongs in Sigma rules evaluated by your SIEM or
# a host-level agent, not in the audit ruleset itself.
#
# UID_MIN convention
#   Rules that target human-user activity use `auid>=1000 -F auid!=unset`.
#   1000 is the default UID_MIN on Debian/Ubuntu and RHEL 7+ / Fedora.
#   If your host uses a different UID_MIN (e.g. 500 on RHEL/CentOS 6),
#   replace 1000 everywhere with `awk '/^UID_MIN/{print $2}' /etc/login.defs`.
#   auditd rules do not support variables, so this substitution must be
#   done at deploy time (Ansible/Jinja2, sed, envsubst, etc.).
#
# Remove any existing rules
-D

# Buffer Size
## Feel free to increase this if the machine panic's
-b 8192

# Failure Mode
## Possible values: 0 (silent), 1 (printk, print a failure message), 2 (panic, halt the system)
-f 1

# Ignore errors
## Keep optional distro-specific paths from aborting the whole load.
## For strict validation, test a copy of this file with this line removed.
-i

# Self Auditing ---------------------------------------------------------------

## Audit the audit logs
### Successful and unsuccessful attempts to read information from the audit records
-w /var/log/audit/ -p wra -k auditlog
-w /var/audit/ -p wra -k auditlog

## Auditd configuration
### Modifications to audit configuration that occur while the audit collection functions are operating
-w /etc/audit/ -p wa -k auditconfig
-w /etc/libaudit.conf -p wa -k auditconfig
-w /etc/audisp/ -p wa -k audispconfig

# Filters ---------------------------------------------------------------------

### We put these early because audit is a first match wins system.

## Ignore current working directory records
## -a always,exclude -F msgtype=CWD

## Cron jobs fill the logs with stuff we normally don't want (works with SELinux)
## NOTE: subj_type= requires SELinux. On non-SELinux systems (Debian/Ubuntu)
## these rules are silently ignored (due to -i above). Replace with UID-based
## filters if not running SELinux.
-a never,user -F subj_type=crond_t
-a never,exit -F subj_type=crond_t

## Optional, distro-specific chrony/ntp suppression (commented out by default):
## Account names differ across distros (chrony vs _chrony on Ubuntu 24.04) so
## uncomment and adjust uid= to your host's time-daemon account if needed.
#-a never,exit -F arch=b64 -S adjtimex -F auid=unset -F uid=chrony -F subj_type=chronyd_t

## This is not very interesting and wastes a lot of space if the server is public facing
-a always,exclude -F msgtype=CRYPTO_KEY_USER

## Open VM Tools
-a never,exit -F arch=b64 -S all -F exe=/usr/bin/vmtoolsd
-a never,exit -F arch=b32 -S all -F exe=/usr/bin/vmtoolsd

## High Volume Event Filter (especially on Linux Workstations)
-a never,exit -F arch=b32 -F dir=/dev/shm/ -F key=sharedmemaccess
-a never,exit -F arch=b64 -F dir=/dev/shm/ -F key=sharedmemaccess

-a never,exit -F arch=b32 -F dir=/var/lock/lvm/ -F key=locklvm
-a never,exit -F arch=b64 -F dir=/var/lock/lvm/ -F key=locklvm

## Filebeat
### https://www.elastic.co/guide/en/beats/filebeat/current/directory-layout.html

-a always,exit -F arch=b32 -F dir=/etc/filebeat/ -F perm=wa -F key=filebeat
-a always,exit -F arch=b64 -F dir=/etc/filebeat/ -F perm=wa -F key=filebeat

-a always,exit -F arch=b32 -F dir=/usr/share/filebeat/ -F perm=wa -F key=filebeat
-a always,exit -F arch=b64 -F dir=/usr/share/filebeat/ -F perm=wa -F key=filebeat

## More information on how to filter events
### https://access.redhat.com/solutions/2482221

# Rules -----------------------------------------------------------------------

## Kernel parameters
-w /etc/sysctl.conf -p wa -k sysctl
-w /etc/sysctl.d -p wa -k sysctl

## Kernel module loading and unloading
-a always,exit -F arch=b64 -S finit_module -S init_module -S delete_module -F auid!=unset -k modules
-a always,exit -F arch=b32 -S finit_module -S init_module -S delete_module -F auid!=unset -k modules

## Modprobe configuration
-w /etc/modprobe.conf -p wa -k modprobe
-w /etc/modprobe.d -p wa -k modprobe
-w /etc/modules-load.d/ -p wa -k modprobe

## KExec usage (all actions)
## NOTE: kexec_file_load is x86_64-only; i386/b32 kexec is deprecated
## and omitted here to keep the ruleset portable across libaudit versions.
-a always,exit -F arch=b64 -S kexec_file_load -k KEXEC

## Special files
-a always,exit -F arch=b64 -S mknod -S mknodat -k specialfiles
-a always,exit -F arch=b32 -S mknod -S mknodat -k specialfiles

## Mount operations (only attributable)
-a always,exit -F arch=b64 -S mount -S umount2 -S move_mount -S open_tree -S fsopen -S fsconfig -S fsmount -F auid!=unset -k mount
-a always,exit -F arch=b32 -S mount -S umount2 -S move_mount -S open_tree -S fsopen -S fsconfig -S fsmount -F auid!=unset -k mount

## Change swap (only attributable)
-a always,exit -F arch=b64 -S swapon -S swapoff -F auid!=unset -k swap
-a always,exit -F arch=b32 -S swapon -S swapoff -F auid!=unset -k swap

## Time
## Account names differ across distros (ntp/chrony/systemd-timesync) so no
## uid!= filter is applied here. Add a distro-specific never,exit overlay
## above if your time daemon generates excessive noise.
-a always,exit -F arch=b64 -S adjtimex -S settimeofday -S clock_settime -k time
-a always,exit -F arch=b32 -S adjtimex -S settimeofday -S clock_settime -k time
### Local time zone
-w /etc/localtime -p wa -k localtime

## Cron configuration & scheduled jobs
-w /etc/cron.allow -p wa -k cron
-w /etc/cron.deny -p wa -k cron
-w /etc/cron.d/ -p wa -k cron
-w /etc/cron.daily/ -p wa -k cron
-w /etc/cron.hourly/ -p wa -k cron
-w /etc/cron.monthly/ -p wa -k cron
-w /etc/cron.weekly/ -p wa -k cron
-w /etc/crontab -p wa -k cron
-w /etc/anacrontab -p wa -k cron
-w /etc/at.allow -p wa -k cron
-w /etc/at.deny -p wa -k cron
-w /var/spool/cron/ -p wa -k cron

## User, group, password databases
-w /etc/group -p wa -k etcgroup
-w /etc/passwd -p wa -k etcpasswd
-w /etc/gshadow -p wa -k etcgroup
-w /etc/shadow -p wa -k etcpasswd
-w /etc/nsswitch.conf -p wa -k etcpasswd
-w /etc/sssd/ -p wa -k etcpasswd
-w /etc/openldap/ -p wa -k etcpasswd
-w /etc/krb5.conf -p wa -k etcpasswd
-w /etc/krb5.conf.d/ -p wa -k etcpasswd
-w /etc/subuid -p wa -k etcpasswd
-w /etc/subgid -p wa -k etcpasswd

## PAM & security configuration
-w /etc/pam.d/ -p wa -k pam
-w /etc/security/ -p wa -k pam
-w /etc/polkit-1/ -p wa -k pam

## Sudoers file changes
-w /etc/sudoers -p wa -k actions
-w /etc/sudoers.d/ -p wa -k actions

## Login configuration and information
-w /etc/login.defs -p wa -k login
-w /etc/securetty -p wa -k login
-w /var/log/faillog -p wa -k login
-w /var/log/lastlog -p wa -k login
-w /var/log/tallylog -p wa -k login

## Network Environment
### Changes to hostname
-a always,exit -F arch=b64 -S sethostname -S setdomainname -k network_modifications
-a always,exit -F arch=b32 -S sethostname -S setdomainname -k network_modifications

### Successful IPv4 Connections
-a always,exit -F arch=b64 -S connect -F a2=16 -F success=1 -F key=network_connect_4
-a always,exit -F arch=b32 -S connect -F a2=16 -F success=1 -F key=network_connect_4

### Successful IPv6 Connections
-a always,exit -F arch=b64 -S connect -F a2=28 -F success=1 -F key=network_connect_6
-a always,exit -F arch=b32 -S connect -F a2=28 -F success=1 -F key=network_connect_6

### Changes to other files
-w /etc/hosts -p wa -k network_modifications
-w /etc/resolv.conf -p wa -k network_modifications
-w /etc/hostname -p wa -k network_modifications
-w /etc/sysconfig/ -p wa -k sysconfig
-w /etc/network/ -p wa -k network
-a always,exit -F dir=/etc/NetworkManager/ -F perm=wa -k network_modifications

### Firewall configuration
-w /etc/nftables.conf -p wa -k firewall
-w /etc/iptables/ -p wa -k firewall

### Changes to issue
-w /etc/issue -p wa -k etcissue
-w /etc/issue.net -p wa -k etcissue

## Service defaults
-w /etc/default/ -p wa -k svc_defaults

## Filesystem table
-w /etc/fstab -p wa -k fstab

## udev rules
-w /etc/udev/rules.d/ -p wa -k udev

## System startup scripts
-w /etc/inittab -p wa -k init
-w /etc/init.d/ -p wa -k init
-w /etc/init/ -p wa -k init
-w /etc/rc.local -p wa -k init

## System binary and boot path changes
## NOTE: On modern distros /bin -> /usr/bin; bin_writes and usr_writes may
## double-fire for the same path. Keep both for older layouts.
-a always,exit -F arch=b32 -F dir=/bin -F perm=wa -k bin_writes
-a always,exit -F arch=b64 -F dir=/bin -F perm=wa -k bin_writes
-a always,exit -F arch=b32 -F dir=/usr -F perm=wa -k usr_writes
-a always,exit -F arch=b64 -F dir=/usr -F perm=wa -k usr_writes
-a always,exit -F arch=b32 -F dir=/boot -F perm=wa -k boot_writes
-a always,exit -F arch=b64 -F dir=/boot -F perm=wa -k boot_writes

## Library search paths
-w /etc/ld.so.conf -p wa -k libpath
-w /etc/ld.so.conf.d -p wa -k libpath

## Systemwide library preloads (LD_PRELOAD)
-w /etc/ld.so.preload -p wa -k systemwide_preloads

## System-wide environment variables
-w /etc/environment -p wa -k environment

## Mail configuration
-w /etc/aliases -p wa -k mail
-w /etc/postfix/ -p wa -k mail
-w /etc/exim4/ -p wa -k mail

## SSH configuration
-w /etc/ssh/ -p wa -k sshd
-w /etc/dropbear/ -p wa -k sshd

## root ssh key tampering
-w /root/.ssh -p wa -k rootkey

# Systemd
-w /etc/systemd/ -p wa -k systemd
-w /usr/lib/systemd -p wa -k systemd
-w /lib/systemd/ -p wa -k systemd
-w /usr/local/lib/systemd/ -p wa -k systemd

## Mandatory Access Controls (MAC) policy
-w /etc/selinux/ -p wa -k mac_policy
-w /etc/apparmor/ -p wa -k mac_policy
-w /etc/apparmor.d/ -p wa -k mac_policy

## Shell/profile configurations
-w /etc/profile.d/ -p wa -k shell_profiles
-w /etc/profile -p wa -k shell_profiles
-w /etc/shells -p wa -k shell_profiles
-w /etc/bashrc -p wa -k shell_profiles
-w /etc/csh.cshrc -p wa -k shell_profiles
-w /etc/csh.login -p wa -k shell_profiles
-w /etc/fish/ -p wa -k shell_profiles
-w /etc/zsh/ -p wa -k shell_profiles

## Critical elements access failures
-a always,exit -F arch=b64 -S open -S openat -S openat2 -S open_by_handle_at -F dir=/etc -F success=0 -F auid>=1000 -F auid!=unset -k unauthedfileaccess
-a always,exit -F arch=b32 -S open -S openat -S openat2 -S open_by_handle_at -F dir=/etc -F success=0 -F auid>=1000 -F auid!=unset -k unauthedfileaccess
-a always,exit -F arch=b64 -S open -S openat -S openat2 -S open_by_handle_at -F dir=/bin -F success=0 -F auid>=1000 -F auid!=unset -k unauthedfileaccess
-a always,exit -F arch=b32 -S open -S openat -S openat2 -S open_by_handle_at -F dir=/bin -F success=0 -F auid>=1000 -F auid!=unset -k unauthedfileaccess
-a always,exit -F arch=b64 -S open -S openat -S openat2 -S open_by_handle_at -F dir=/sbin -F success=0 -F auid>=1000 -F auid!=unset -k unauthedfileaccess
-a always,exit -F arch=b32 -S open -S openat -S openat2 -S open_by_handle_at -F dir=/sbin -F success=0 -F auid>=1000 -F auid!=unset -k unauthedfileaccess
-a always,exit -F arch=b64 -S open -S openat -S openat2 -S open_by_handle_at -F dir=/usr/bin -F success=0 -F auid>=1000 -F auid!=unset -k unauthedfileaccess
-a always,exit -F arch=b32 -S open -S openat -S openat2 -S open_by_handle_at -F dir=/usr/bin -F success=0 -F auid>=1000 -F auid!=unset -k unauthedfileaccess
-a always,exit -F arch=b64 -S open -S openat -S openat2 -S open_by_handle_at -F dir=/usr/sbin -F success=0 -F auid>=1000 -F auid!=unset -k unauthedfileaccess
-a always,exit -F arch=b32 -S open -S openat -S openat2 -S open_by_handle_at -F dir=/usr/sbin -F success=0 -F auid>=1000 -F auid!=unset -k unauthedfileaccess
-a always,exit -F arch=b64 -S open -S openat -S openat2 -S open_by_handle_at -F dir=/var -F success=0 -F auid>=1000 -F auid!=unset -k unauthedfileaccess
-a always,exit -F arch=b32 -S open -S openat -S openat2 -S open_by_handle_at -F dir=/var -F success=0 -F auid>=1000 -F auid!=unset -k unauthedfileaccess
-a always,exit -F arch=b64 -S open -S openat -S openat2 -S open_by_handle_at -F dir=/home -F success=0 -F auid>=1000 -F auid!=unset -k unauthedfileaccess
-a always,exit -F arch=b32 -S open -S openat -S openat2 -S open_by_handle_at -F dir=/home -F success=0 -F auid>=1000 -F auid!=unset -k unauthedfileaccess
-a always,exit -F arch=b64 -S open -S openat -S openat2 -S open_by_handle_at -F dir=/srv -F success=0 -F auid>=1000 -F auid!=unset -k unauthedfileaccess
-a always,exit -F arch=b32 -S open -S openat -S openat2 -S open_by_handle_at -F dir=/srv -F success=0 -F auid>=1000 -F auid!=unset -k unauthedfileaccess

### Permission-denied opens from system accounts/daemons (no login session).
### Narrower than success=0 above to avoid the file-not-found noise that
### dominates daemon activity — EACCES/EPERM are the high-signal cases.
-a always,exit -F arch=b64 -S open -S openat -S openat2 -S open_by_handle_at -F exit=-EACCES -F auid=unset -k unauthedfileaccess_system
-a always,exit -F arch=b64 -S open -S openat -S openat2 -S open_by_handle_at -F exit=-EPERM -F auid=unset -k unauthedfileaccess_system
-a always,exit -F arch=b32 -S open -S openat -S openat2 -S open_by_handle_at -F exit=-EACCES -F auid=unset -k unauthedfileaccess_system
-a always,exit -F arch=b32 -S open -S openat -S openat2 -S open_by_handle_at -F exit=-EPERM -F auid=unset -k unauthedfileaccess_system

## Session initiation information
-w /var/run/utmp -p wa -k session
-w /var/log/btmp -p wa -k session
-w /var/log/wtmp -p wa -k session

## Discretionary Access Control (DAC) modifications
## NOTE: Rules that use `auid>=1000` assume the common Linux `UID_MIN=1000`.
## If your host uses a different UID_MIN in `/etc/login.defs`, replace `1000`
## accordingly before deployment. `auid!=unset` excludes daemon/system sessions.
-a always,exit -F arch=b64 -S chmod -S fchmod -S fchmodat -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b32 -S chmod -S fchmod -S fchmodat -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b64 -S chown -S fchown -S fchownat -S lchown -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b32 -S chown -S fchown -S fchownat -S lchown -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b64 -S setxattr -S lsetxattr -S fsetxattr -S removexattr -S lremovexattr -S fremovexattr -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b32 -S setxattr -S lsetxattr -S fsetxattr -S removexattr -S lremovexattr -S fremovexattr -F auid>=1000 -F auid!=unset -k perm_mod

# Special Rules ---------------------------------------------------------------

## Ptrace (injection, debugging, tracing)
### Logs all ptrace calls; Sigma differentiates by a0 value
### (0x4=PTRACE_POKETEXT, 0x5=PTRACE_POKEDATA, 0x6=PTRACE_POKEUSR, etc.)
-a always,exit -F arch=b64 -S ptrace -k tracing
-a always,exit -F arch=b32 -S ptrace -k tracing

## Anonymous File Creation
### "memfd_create" creates anonymous file and returns a file descriptor to access it
### When combined with "fexecve" can be used to stealthily run binaries in memory without touching disk
-a always,exit -F arch=b64 -S memfd_create -F key=anon_file_create
-a always,exit -F arch=b32 -S memfd_create -F key=anon_file_create

## Timestomping (T1070.006)
-a always,exit -F arch=b64 -S utimensat -S utimes -S futimesat -F auid>=1000 -F auid!=unset -k T1070_006_timestomp
-a always,exit -F arch=b32 -S utimensat -S utimes -S futimesat -F auid>=1000 -F auid!=unset -k T1070_006_timestomp

## eBPF program loading
-a always,exit -F arch=b64 -S bpf -k bpf
-a always,exit -F arch=b32 -S bpf -k bpf

## Namespace manipulation
-a always,exit -F arch=b64 -S unshare -S setns -S pivot_root -k namespaces
-a always,exit -F arch=b32 -S unshare -S setns -S pivot_root -k namespaces

## Cross-process memory access
-a always,exit -F arch=b64 -S process_vm_readv -S process_vm_writev -k process_vm
-a always,exit -F arch=b32 -S process_vm_readv -S process_vm_writev -k process_vm

## io_uring (known audit blind spot — operations bypass syscall auditing)
-a always,exit -F arch=b64 -S io_uring_setup -k io_uring
-a always,exit -F arch=b32 -S io_uring_setup -k io_uring

## Exploitation primitives
-a always,exit -F arch=b64 -S userfaultfd -k userfaultfd
-a always,exit -F arch=b32 -S userfaultfd -k userfaultfd

## System reboot/shutdown
-a always,exit -F arch=b64 -S reboot -k reboot
-a always,exit -F arch=b32 -S reboot -k reboot

## Process accounting control
-a always,exit -F arch=b64 -S acct -k process_accounting
-a always,exit -F arch=b32 -S acct -k process_accounting

## Kernel crypto sockets (AF_ALG)
### Low-noise on most hosts. AF_ALG usage typically requires socket creation,
### SOL_ALG configuration, and bind() with a SOCKADDR record that downstream
### tooling can decode to recover salg_type / salg_name. Audit cannot match
### those strings in-kernel, so keep the collection generic here.
-a always,exit -F arch=b64 -S socket -F a0=38 -F success=1 -F auid>=1000 -F auid!=unset -k af_alg
-a always,exit -F arch=b32 -S socket -F a0=38 -F success=1 -F auid>=1000 -F auid!=unset -k af_alg
-a always,exit -F arch=b64 -S bind -F a2=88 -F success=1 -F auid>=1000 -F auid!=unset -k af_alg
-a always,exit -F arch=b32 -S bind -F a2=88 -F success=1 -F auid>=1000 -F auid!=unset -k af_alg
-a always,exit -F arch=b64 -S setsockopt -F a1=279 -F success=1 -F auid>=1000 -F auid!=unset -k af_alg
-a always,exit -F arch=b32 -S setsockopt -F a1=279 -F success=1 -F auid>=1000 -F auid!=unset -k af_alg

## Privilege Abuse
### The purpose of this rule is to detect when an admin may be abusing power by looking in user's home dir.
-a always,exit -F dir=/home -F uid=0 -F auid>=1000 -F auid!=unset -C auid!=obj_uid -k power_abuse

## Raw sockets
### Logs all raw sockets
-a always,exit -F arch=b32 -S socket -F a0=17 -F a1=3 -k raw_network_socket_created
-a always,exit -F arch=b64 -S socket -F a0=17 -F a1=3 -k raw_network_socket_created
### Keep watch for when BPF filters are attached
-a always,exit -F arch=b32 -S setsockopt -F a1=1 -F a2=26 -k socket_bpf_filter_attached
-a always,exit -F arch=b64 -S setsockopt -F a1=1 -F a2=26 -k socket_bpf_filter_attached

# Socket Creations
# will catch both IPv4 and IPv6

-a always,exit -F arch=b32 -S socket -F a0=2  -k network_socket_created
-a always,exit -F arch=b64 -S socket -F a0=2  -k network_socket_created

-a always,exit -F arch=b32 -S socket -F a0=10 -k network_socket_created
-a always,exit -F arch=b64 -S socket -F a0=10 -k network_socket_created

## Optional overlay: enable only if splice/vmsplice are rare in your estate.
## Correlate short bursts of these events with recent af_alg activity from the
## same pid/auid when investigating unusual kernel crypto socket usage.
#-a always,exit -F arch=b64 -S splice -S vmsplice -F success=1 -F auid>=1000 -F auid!=unset -k splice_user
#-a always,exit -F arch=b32 -S splice -S vmsplice -F success=1 -F auid>=1000 -F auid!=unset -k splice_user

# Software Management ---------------------------------------------------------

## Package manager configuration
-w /etc/apt/ -p wa -k software_mgmt
-w /etc/dnf/ -p wa -k software_mgmt
-w /etc/yum.repos.d/ -p wa -k software_mgmt

## Container configuration
-w /var/lib/docker -p wa -k docker
-w /etc/docker -p wa -k docker
-w /etc/containers/ -p wa -k containers

# CrowdStrike Falcon
-a always,exit -F arch=b32 -F dir=/etc/crowdstrike/ -F perm=wa -F key=falcon_sensor
-a always,exit -F arch=b64 -F dir=/etc/crowdstrike/ -F perm=wa -F key=falcon_sensor

-a always,exit -F arch=b32 -F dir=/usr/lib/crowdstrike/ -F perm=wa -F key=falcon_sensor
-a always,exit -F arch=b64 -F dir=/usr/lib/crowdstrike/ -F perm=wa -F key=falcon_sensor

-a always,exit -F arch=b32 -F dir=/opt/CrowdStrike/ -F perm=wa -F key=falcon_sensor
-a always,exit -F arch=b64 -F dir=/opt/CrowdStrike/ -F perm=wa -F key=falcon_sensor

-a always,exit -F arch=b32 -F dir=/var/log/crowdstrike/ -F perm=wa -F key=falcon_sensor
-a always,exit -F arch=b64 -F dir=/var/log/crowdstrike/ -F perm=wa -F key=falcon_sensor

-a always,exit -F arch=b32 -S connect -F exe=/opt/CrowdStrike/falcon-sensor -F key=crowdstrike_network
-a always,exit -F arch=b64 -S connect -F exe=/opt/CrowdStrike/falcon-sensor -F key=crowdstrike_network

# ipc system call
# /usr/include/linux/ipc.h

## NOTE: glibc's semop() is implemented via semtimedop() on modern systems;
## the standalone semop name was dropped from some libaudit tables.
-a always,exit -F arch=b64 -S msgctl -S msgget -S semctl -S semget -S shmctl -S shmget -k Inter-Process_Communication
-a always,exit -F arch=b32 -S msgctl -S msgget -S semctl -S semget -S shmctl -S shmget -k Inter-Process_Communication

# High Volume Events ----------------------------------------------------------

## Disable these rules if they create too many events in your environment

## Process creation
### Collect generic execution telemetry and derive tool- and context-specific
### detections in downstream tooling such as Sigma / SIEM content.
-a always,exit -F arch=b32 -S execve -S execveat -k process_creation
-a always,exit -F arch=b64 -S execve -S execveat -k process_creation

## File Deletion Events by User
-a always,exit -F arch=b64 -S rmdir -S unlink -S unlinkat -S rename -S renameat -S renameat2 -F auid>=1000 -F auid!=unset -k delete
-a always,exit -F arch=b32 -S rmdir -S unlink -S unlinkat -S rename -S renameat -S renameat2 -F auid>=1000 -F auid!=unset -k delete

## File Access
### Unauthorized Access (unsuccessful)
-a always,exit -F arch=b64 -S creat -S open -S openat -S openat2 -S open_by_handle_at -S truncate -S ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=unset -k file_access
-a always,exit -F arch=b64 -S creat -S open -S openat -S openat2 -S open_by_handle_at -S truncate -S ftruncate -F exit=-EPERM -F auid>=1000 -F auid!=unset -k file_access
-a always,exit -F arch=b32 -S creat -S open -S openat -S openat2 -S open_by_handle_at -S truncate -S ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=unset -k file_access
-a always,exit -F arch=b32 -S creat -S open -S openat -S openat2 -S open_by_handle_at -S truncate -S ftruncate -F exit=-EPERM -F auid>=1000 -F auid!=unset -k file_access

### Unsuccessful Creation
-a always,exit -F arch=b64 -S mkdir -S mkdirat -S creat -S link -S linkat -S symlink -S symlinkat -S mknod -S mknodat -F exit=-EACCES -k file_creation
-a always,exit -F arch=b64 -S mkdir -S mkdirat -S creat -S link -S linkat -S symlink -S symlinkat -S mknod -S mknodat -F exit=-EPERM -k file_creation
-a always,exit -F arch=b32 -S mkdir -S mkdirat -S creat -S link -S linkat -S symlink -S symlinkat -S mknod -S mknodat -F exit=-EACCES -k file_creation
-a always,exit -F arch=b32 -S mkdir -S mkdirat -S creat -S link -S linkat -S symlink -S symlinkat -S mknod -S mknodat -F exit=-EPERM -k file_creation

### Unsuccessful Modification
-a always,exit -F arch=b64 -S rename -S renameat -S renameat2 -S truncate -S chmod -S setxattr -S lsetxattr -S removexattr -S lremovexattr -F exit=-EACCES -k file_modification
-a always,exit -F arch=b64 -S rename -S renameat -S renameat2 -S truncate -S chmod -S setxattr -S lsetxattr -S removexattr -S lremovexattr -F exit=-EPERM -k file_modification
-a always,exit -F arch=b32 -S rename -S renameat -S renameat2 -S truncate -S chmod -S setxattr -S lsetxattr -S removexattr -S lremovexattr -F exit=-EACCES -k file_modification
-a always,exit -F arch=b32 -S rename -S renameat -S renameat2 -S truncate -S chmod -S setxattr -S lsetxattr -S removexattr -S lremovexattr -F exit=-EPERM -k file_modification

## 32bit ABI Exploitation
### https://github.com/linux-audit/audit-userspace/blob/c014eec64b3a16c004f4a75e5792a4ac2fcc0df2/rules/21-no32bit.rules
### If you are on a 64 bit platform, everything _should_ be running
### in 64 bit mode. This rule will detect any use of the 32 bit syscalls
### because this might be a sign of someone exploiting a hole in the 32
### bit ABI.
### NOTE: Explicit b32 rules above provide specific keys for SIEM correlation;
### this catch-all additionally tags all 32-bit activity under a single key.
-a always,exit -F arch=b32 -S all -k 32bit_abi

# Make The Configuration Immutable --------------------------------------------

##-e 2
__NEO23X0_AUDIT_RULES__
}

main "$@"
