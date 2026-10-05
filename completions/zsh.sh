#compdef pi-web-dockerized.sh
# shellcheck shell=bash disable=SC2034,SC2154,SC1087,SC2016

# Zsh completion for pi-web-dockerized.sh
# Source this file in your ~/.zshrc or place in /usr/local/share/zsh/site-functions/

_pi_web_dockerized() {
    local -a commands
    commands=(
        'run:Run Pi in Docker (default: current directory)'
        'web:Run the pi-web browser UI'
        'auth:Sign in to a model provider (use /login)'
        'models:List models available to the configured providers'
        'exec:Run a non-interactive prompt (pi -p)'
        'pkg:Manage Pi packages'
        'shell:Open a bash shell in the container'
        'build:Build the Docker image'
        'update:Update Pi, pi-web and graphify to the latest version'
        'version:Show the versions in the image'
        'config:Show, edit, or print config file path'
        'clean:Remove the Docker image'
        'help:Show help message'
    )

    _arguments -C \
        '1: :->cmds' \
        '*:: :->args'

    case $state in
        cmds)
            _describe -t commands 'pi-web-dockerized command' commands
            ;;
        args)
            case $words[1] in
                run|web|shell)
                    _files -/
                    ;;
                pkg)
                    _values 'pkg subcommand' list install remove update config
                    ;;
                config)
                    local -a config_cmds
                    config_cmds=(
                        'show:Show current configuration'
                        'edit:Edit config file in $EDITOR'
                        'path:Print config file path'
                    )
                    _describe -t config_cmds 'config subcommand' config_cmds
                    ;;
            esac
            ;;
    esac
}

compdef _pi_web_dockerized pi-web-dockerized.sh
compdef _pi_web_dockerized pi-web-dockerized
compdef _pi_web_dockerized pid
