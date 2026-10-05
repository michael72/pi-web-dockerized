#!/bin/bash

# Bash completion for pi-web-dockerized.sh
# Source this file in your ~/.bashrc or install system-wide

_pi_web_dockerized() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="run web auth models exec pkg shell build update version config clean help --help -h"

    case "${prev}" in
        run|web|shell)
            # Complete directory paths
            mapfile -t COMPREPLY < <(compgen -d -- "${cur}")
            return 0
            ;;
        config)
            mapfile -t COMPREPLY < <(compgen -W "show edit path" -- "${cur}")
            return 0
            ;;
        pkg)
            mapfile -t COMPREPLY < <(compgen -W "list install remove update config" -- "${cur}")
            return 0
            ;;
        *)
            ;;
    esac

    mapfile -t COMPREPLY < <(compgen -W "${opts}" -- "${cur}")
    return 0
}

complete -F _pi_web_dockerized pi-web-dockerized.sh
complete -F _pi_web_dockerized ./pi-web-dockerized.sh
complete -F _pi_web_dockerized pi-web-dockerized
complete -F _pi_web_dockerized pid
