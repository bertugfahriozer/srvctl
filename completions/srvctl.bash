# ═══════════════════════════════════════════════
#  srvctl Bash Auto-Completion
#  Kurulum: cp completions/srvctl.bash /etc/bash_completion.d/srvctl
# ═══════════════════════════════════════════════

_srvctl_completions() {
    local cur prev commands
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Ana komutlar
    commands="init domain cron deploy backup ssl security status monitor notify cloudflare ip trusted user plugin webhook changelog version help"

    # 1. seviye
    if [[ ${COMP_CWORD} -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$commands" -- "$cur"))
        return
    fi

    # 2. seviye — alt komutlar
    case "${COMP_WORDS[1]}" in
        domain)
            local domain_cmds="add remove list info clone suspend unsuspend php-switch resources staging migrate rate-limit framework repair worker scheduler"
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=($(compgen -W "$domain_cmds" -- "$cur"))
            elif [[ ${COMP_CWORD} -eq 3 ]]; then
                # Domain adı tamamlama
                _srvctl_complete_domains
            elif [[ ${COMP_CWORD} -ge 4 && "${COMP_WORDS[2]}" == "add" ]]; then
                # 'domain add' bayrak tamamlama (--redis-queue dahil)
                COMPREPLY=($(compgen -W "--php= --rate= --sensitive= --framework= --resources= --no-ssl --redis-queue" -- "$cur"))
            elif [[ ${COMP_CWORD} -eq 4 && "${COMP_WORDS[2]}" == "framework" ]]; then
                # 'domain framework <domain> <deger>' — beyan değeri tamamlama
                COMPREPLY=($(compgen -W "ci4 laravel symfony none" -- "$cur"))
            fi
            ;;
        cron)
            local cron_cmds="add list show run enable disable remove logs"
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=($(compgen -W "$cron_cmds" -- "$cur"))
            elif [[ ${COMP_CWORD} -eq 3 ]]; then
                # <domain>|--system tamamlama
                COMPREPLY=($(compgen -W "--system" -- "$cur"))
                _srvctl_complete_domains
            elif [[ ${COMP_CWORD} -ge 4 && "${COMP_WORDS[2]}" == "add" ]]; then
                # 'cron add' bayrak tamamlama
                COMPREPLY=($(compgen -W "--name= --schedule= --command= --description= --timeout= --catch-up-on-boot --utc" -- "$cur"))
            fi
            ;;
        deploy)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=($(compgen -W "rollback health list prune" -- "$cur"))
                _srvctl_complete_domains
            elif [[ ${COMP_CWORD} -eq 3 ]]; then
                case "${COMP_WORDS[2]}" in
                    rollback|health|list) _srvctl_complete_domains ;;
                    prune)
                        COMPREPLY=($(compgen -W "--all" -- "$cur"))
                        _srvctl_complete_domains
                        ;;
                    *) COMPREPLY=($(compgen -W "main staging develop --dry-run" -- "$cur")) ;;
                esac
            elif [[ "${COMP_WORDS[2]}" == "prune" ]]; then
                COMPREPLY=($(compgen -W "--apply --include-bak --keep=" -- "$cur"))
            fi
            ;;
        backup)
            local backup_cmds="run list restore"
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=($(compgen -W "$backup_cmds" -- "$cur"))
            elif [[ ${COMP_CWORD} -eq 3 && "$prev" == "run" ]]; then
                _srvctl_complete_domains
            fi
            ;;
        ssl)
            COMPREPLY=($(compgen -W "renew status" -- "$cur"))
            ;;
        security)
            COMPREPLY=($(compgen -W "audit harden-fs harden-fpm" -- "$cur"))
            ;;
        monitor)
            COMPREPLY=($(compgen -W "live domains uptime check traffic" -- "$cur"))
            ;;
        notify)
            COMPREPLY=($(compgen -W "test setup" -- "$cur"))
            ;;
        cloudflare)
            local cf_cmds="setup dns purge waf ddos status"
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=($(compgen -W "$cf_cmds" -- "$cur"))
            elif [[ ${COMP_CWORD} -eq 3 ]]; then
                case "$prev" in
                    dns)    COMPREPLY=($(compgen -W "list add remove" -- "$cur")) ;;
                    waf)    COMPREPLY=($(compgen -W "enable disable" -- "$cur")) ;;
                    ddos)   COMPREPLY=($(compgen -W "on off" -- "$cur")) ;;
                    purge|status)  _srvctl_complete_domains ;;
                esac
            elif [[ ${COMP_CWORD} -eq 4 ]]; then
                _srvctl_complete_domains
            fi
            ;;
        ip)
            local ip_cmds="ban unban whitelist blacklist list geoblock reapply"
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=($(compgen -W "$ip_cmds" -- "$cur"))
            elif [[ ${COMP_CWORD} -eq 3 ]]; then
                case "$prev" in
                    whitelist|blacklist) COMPREPLY=($(compgen -W "add remove" -- "$cur")) ;;
                    geoblock)            COMPREPLY=($(compgen -W "add remove list" -- "$cur")) ;;
                esac
            fi
            ;;
        trusted)
            local trusted_cmds="sync list"
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=($(compgen -W "$trusted_cmds" -- "$cur"))
            fi
            ;;
        user)
            local user_cmds="add remove list info grant revoke key 2fa audit"
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=($(compgen -W "$user_cmds" -- "$cur"))
            elif [[ ${COMP_CWORD} -eq 3 ]]; then
                case "$prev" in
                    key)  COMPREPLY=($(compgen -W "add remove" -- "$cur")) ;;
                    2fa)  COMPREPLY=($(compgen -W "setup disable" -- "$cur")) ;;
                esac
            fi
            ;;
        plugin)
            local plugin_cmds="install remove list enable disable create"
            COMPREPLY=($(compgen -W "$plugin_cmds" -- "$cur"))
            ;;
        webhook)
            COMPREPLY=($(compgen -W "start stop status setup" -- "$cur"))
            ;;
        changelog)
            COMPREPLY=($(compgen -W "show tail search export" -- "$cur"))
            ;;
    esac
}

_srvctl_complete_domains() {
    local web_root="/var/www"
    if [[ -d "$web_root" ]]; then
        local domains
        domains=$(find "$web_root" -maxdepth 1 -type d ! -name "$(basename "$web_root")" -printf "%f\n" 2>/dev/null)
        COMPREPLY=($(compgen -W "$domains" -- "$cur"))
    fi
}

complete -F _srvctl_completions srvctl
