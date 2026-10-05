# Sourced by interactive zsh. State is parsed as data, never evaluated as code.
[[ -o interactive ]] || return 0
typeset -g __shadowbat_state_file="${${(%):-%x}:A:h}/terminal-proxy.state"
typeset -ga __shadowbat_names=(http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY)
typeset -gA __shadowbat_original_value __shadowbat_original_kind __shadowbat_applied_value
typeset -g __shadowbat_session="${_SHADOWBAT_SESSION-}"

# Exported snapshots let nested shells restore the pre-Shadowbat environment too.
if [[ -n $__shadowbat_session ]]; then
    for __shadowbat_name in "${__shadowbat_names[@]}"; do
        __shadowbat_key="_SHADOWBAT_ORIGINAL_${__shadowbat_name}"
        __shadowbat_original_value[$__shadowbat_name]="${(P)__shadowbat_key}"
        __shadowbat_key="_SHADOWBAT_KIND_${__shadowbat_name}"
        __shadowbat_original_kind[$__shadowbat_name]="${(P)__shadowbat_key}"
        __shadowbat_key="_SHADOWBAT_APPLIED_${__shadowbat_name}"
        __shadowbat_applied_value[$__shadowbat_name]="${(P)__shadowbat_key}"
    done
fi
unset __shadowbat_name __shadowbat_key

__shadowbat_restore() {
    emulate -L zsh
    local name
    for name in "${__shadowbat_names[@]}"; do
        # Keep manual edits, including unset values or changed export attributes.
        if (( ${+parameters[$name]} )) && [[ ${(P)name} == "${__shadowbat_applied_value[$name]}" && ${parameters[$name]} == *export* ]]; then
            case "${__shadowbat_original_kind[$name]}" in
                exported) typeset -gx "$name=${__shadowbat_original_value[$name]}" ;;
                local) typeset -g "$name=${__shadowbat_original_value[$name]}"; typeset -g +x "$name" ;;
                unset) unset "$name" ;;
            esac
        fi
        unset "_SHADOWBAT_ORIGINAL_${name}" "_SHADOWBAT_KIND_${name}" "_SHADOWBAT_APPLIED_${name}"
    done
    unset _SHADOWBAT_SESSION
    __shadowbat_session=''
    __shadowbat_original_value=()
    __shadowbat_original_kind=()
    __shadowbat_applied_value=()
    return 0
}

__shadowbat_sync() {
    emulate -L zsh
    local -a state
    local signature='' name value entry
    if [[ -r $__shadowbat_state_file ]]; then
        state=("${(@f)$(< "$__shadowbat_state_file")}")
        if (( ${#state} == 5 )) && [[ ${state[1]} == 1 ]]; then
            local valid=1
            for entry in "${state[@]:1}"; do
                [[ $entry == <-> && ${#entry} -le 10 ]] || valid=0
            done
            if (( valid )) && (( 10#${state[2]} > 0 && 10#${state[3]} > 0 &&
                10#${state[4]} >= 1024 && 10#${state[4]} <= 65535 &&
                10#${state[5]} >= 1024 && 10#${state[5]} <= 65535 && 10#${state[4]} != 10#${state[5]} )) &&
                builtin kill -0 "${state[2]}" 2>/dev/null && builtin kill -0 "${state[3]}" 2>/dev/null; then
                signature="${(j.:.)state}"
            fi
        fi
    fi
    [[ $signature == "$__shadowbat_session" ]] && return 0
    [[ -n $__shadowbat_session ]] && __shadowbat_restore
    [[ -z $signature ]] && return 0

    for name in "${__shadowbat_names[@]}"; do
        if (( ${+parameters[$name]} )); then
            __shadowbat_original_value[$name]="${(P)name}"
            if [[ ${parameters[$name]} == *export* ]]; then
                __shadowbat_original_kind[$name]=exported
            else
                __shadowbat_original_kind[$name]=local
            fi
        else
            __shadowbat_original_value[$name]=''
            __shadowbat_original_kind[$name]=unset
        fi
    done
    for name in "${__shadowbat_names[@]}"; do
        case "$name" in
            http_proxy|https_proxy|HTTP_PROXY|HTTPS_PROXY) value="http://127.0.0.1:${state[4]}" ;;
            all_proxy|ALL_PROXY) value="socks5h://127.0.0.1:${state[5]}" ;;
            no_proxy|NO_PROXY)
                value="${__shadowbat_original_value[$name]}"
                if [[ ${__shadowbat_original_kind[$name]} == unset ]]; then
                    if [[ $name == no_proxy ]]; then value="${__shadowbat_original_value[NO_PROXY]}"
                    else value="${__shadowbat_original_value[no_proxy]}"; fi
                fi
                for entry in localhost 127.0.0.1 ::1; do
                    if [[ ",$value," != *",$entry,"* ]]; then value="${value:+$value,}$entry"; fi
                done ;;
        esac
        typeset -gx "$name=$value"
        __shadowbat_applied_value[$name]="$value"
        typeset -gx "_SHADOWBAT_ORIGINAL_${name}=${__shadowbat_original_value[$name]}"
        typeset -gx "_SHADOWBAT_KIND_${name}=${__shadowbat_original_kind[$name]}"
        typeset -gx "_SHADOWBAT_APPLIED_${name}=$value"
    done
    __shadowbat_session="$signature"
    typeset -gx "_SHADOWBAT_SESSION=$signature"
    return 0
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd __shadowbat_sync
add-zsh-hook preexec __shadowbat_sync
__shadowbat_sync
