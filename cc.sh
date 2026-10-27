#!/bin/bash
#
# Install directly with: /path/to/cc.sh --install
# Update directly with: /path/to/cc.sh --update
# Both flows are also available through `cc` after the next shell starts.

# Avoid loading the functions and completions more than once.
if [[ "${BASH_SOURCE[0]}" != "$0" && "${_CC_SH_LOADED:-}" == "1" ]]; then
    return 0
fi
_CC_SH_LOADED=1
_CC_SCRIPT_PATH=$(realpath -- "${BASH_SOURCE[0]}") || {
    echo "Unable to determine the cc.sh location." >&2
    if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
        return 1
    fi
    exit 1
}

# Debug variable
DEBUG=false

# File paths
DIR_PATHS_LOG="$HOME/.cc_cd_log"
WS_LIST_FILE="$HOME/.cc_ws"

# Ensure the log file exists
if [ ! -f "$DIR_PATHS_LOG" ]; then
    touch "$DIR_PATHS_LOG"
    [ "$DEBUG" = true ] && echo "Log file created: $DIR_PATHS_LOG"
fi

# Ensure the workspace file exists (optional)
if [ ! -f "$WS_LIST_FILE" ]; then
    touch "$WS_LIST_FILE"
    [ "$DEBUG" = true ] && echo "Workspace file created: $WS_LIST_FILE"
fi

# Workspace format: absolute path, a tab, then its required display name.
declare -a workspaces
declare -A workspace_names
while IFS=$'\t' read -r workspace_path workspace_name; do
    [[ -z "$workspace_path" ]] && continue
    if [[ -z "$workspace_name" ]]; then
        echo "Ignoring workspace without a name: $workspace_path" >&2
        continue
    fi
    workspaces+=("$workspace_path")
    workspace_names["$workspace_path"]="$workspace_name"
done < "$WS_LIST_FILE"

# Load existing log entries into a set
declare -A log_entries
while IFS= read -r line; do
    log_entries["$line"]=1
done < "$DIR_PATHS_LOG"

_cc_run_as_root() {
    if (( EUID == 0 )); then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "Installing fzf requires root privileges, but sudo is unavailable." >&2
        return 1
    fi
}

_cc_install_fzf() {
    if command -v fzf >/dev/null 2>&1; then
        echo "fzf is already installed: $(fzf --version)"
        return 0
    fi

    echo "Installing fzf..."
    if command -v apt-get >/dev/null 2>&1; then
        _cc_run_as_root apt-get install -y fzf
    elif command -v dnf >/dev/null 2>&1; then
        _cc_run_as_root dnf install -y fzf
    elif command -v pacman >/dev/null 2>&1; then
        _cc_run_as_root pacman -S --needed --noconfirm fzf
    elif command -v apk >/dev/null 2>&1; then
        _cc_run_as_root apk add fzf
    elif command -v zypper >/dev/null 2>&1; then
        _cc_run_as_root zypper --non-interactive install fzf
    elif command -v xbps-install >/dev/null 2>&1; then
        _cc_run_as_root xbps-install -Sy fzf
    elif command -v brew >/dev/null 2>&1; then
        brew install fzf
    else
        echo "No supported package manager found. Install fzf, then run cc --install again." >&2
        return 1
    fi || return 1

    hash -r
    if ! command -v fzf >/dev/null 2>&1; then
        echo "fzf installation completed, but fzf is not available on PATH." >&2
        return 1
    fi
    echo "fzf installed: $(fzf --version)"
}

_cc_setup_fzf() {
    local setup fzf_dir

    command -v fzf >/dev/null 2>&1 || return 0
    if setup="$(fzf --bash 2>/dev/null)"; then
        eval "$setup"
        return
    fi

    for fzf_dir in \
        "$HOME/.fzf/shell" \
        /usr/share/doc/fzf/examples \
        /usr/share/fzf/shell \
        /usr/share/fzf
    do
        if [[ -r "$fzf_dir/completion.bash" || -r "$fzf_dir/key-bindings.bash" ]]; then
            [[ -r "$fzf_dir/completion.bash" ]] && source "$fzf_dir/completion.bash"
            [[ -r "$fzf_dir/key-bindings.bash" ]] && source "$fzf_dir/key-bindings.bash"
            return
        fi
    done
}

_cc_bashrc_sources_path() {
    local bashrc="$1"
    local expected_path="$2"
    local directive configured_path remainder resolved_path

    expected_path=$(realpath -- "$expected_path") || return 1
    while read -r directive configured_path remainder; do
        [[ "$directive" == "source" || "$directive" == "." ]] || continue
        [[ -z "$remainder" || "$remainder" == \#* ]] || continue

        if [[ "$configured_path" == \"*\" && "$configured_path" == *\" ]]; then
            configured_path="${configured_path:1:${#configured_path}-2}"
        elif [[ "$configured_path" == \'*\' && "$configured_path" == *\' ]]; then
            configured_path="${configured_path:1:${#configured_path}-2}"
        fi

        case "$configured_path" in
            "~/"*) configured_path="$HOME/${configured_path#\~/}" ;;
            '${HOME}/'*) configured_path="$HOME/${configured_path#\$\{HOME\}/}" ;;
            '$HOME/'*) configured_path="$HOME/${configured_path#\$HOME/}" ;;
        esac

        resolved_path=$(realpath -- "$configured_path" 2>/dev/null) || continue
        [[ "$resolved_path" == "$expected_path" ]] && return 0
    done < "$bashrc"
    return 1
}

_cc_configure_bashrc() {
    local source_path source_path_quoted source_line bashrc

    source_path="$_CC_SCRIPT_PATH"
    printf -v source_path_quoted '%q' "$source_path"
    source_line="source $source_path_quoted"
    bashrc="$HOME/.bashrc"

    touch "$bashrc" || {
        echo "Unable to create $bashrc." >&2
        return 1
    }

    if _cc_bashrc_sources_path "$bashrc" "$source_path"; then
        echo "$bashrc is already configured."
        return 0
    fi

    printf '%s\n' "$source_line" >> "$bashrc" || {
        echo "Unable to update $bashrc." >&2
        return 1
    }
    echo "Updated $bashrc."
}

_cc_install() {
    _cc_install_fzf || return 1
    _cc_configure_bashrc || return 1
    echo "Installation complete. Run: source \"$HOME/.bashrc\""
}

_cc_update() {
    local source_path tmp
    local current_checksum downloaded_checksum downloaded_size ignored
    local url="https://raw.githubusercontent.com/ehsanfarajollahi/cc/refs/heads/main/cc.sh"

    source_path="$_CC_SCRIPT_PATH"
    tmp=$(mktemp "${source_path}.update.XXXXXX") || return 1

    echo "Downloading the latest cc.sh from GitHub..."
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -H "Cache-Control: no-cache" -H "Pragma: no-cache" \
            "$url" -o "$tmp"
    elif command -v wget >/dev/null 2>&1; then
        wget --no-cache -qO "$tmp" "$url"
    else
        echo "Updating requires curl or wget." >&2
        rm -f "$tmp"
        return 1
    fi || {
        echo "Unable to download $url." >&2
        rm -f "$tmp"
        return 1
    }

    if [[ ! -s "$tmp" ]] || ! bash -n "$tmp" || ! grep -Fq '_cc_update()' "$tmp"; then
        echo "Downloaded cc.sh is empty, invalid, or missing the updater; keeping the current version." >&2
        rm -f "$tmp"
        return 1
    fi

    read -r current_checksum ignored ignored < <(cksum "$source_path")
    read -r downloaded_checksum downloaded_size ignored < <(cksum "$tmp")
    echo "Downloaded $downloaded_size bytes (checksum $downloaded_checksum)."
    if cmp -s "$source_path" "$tmp"; then
        rm -f "$tmp"
        echo "Result: no changes; the current cc.sh matches the download."
        return 0
    fi

    chmod --reference="$source_path" "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv -f -- "$tmp" "$source_path" || {
        rm -f "$tmp"
        return 1
    }
    echo "Result: updated $source_path ($current_checksum -> $downloaded_checksum)."
    echo "Reload with: source \"$HOME/.bashrc\""
}

# Function to add to log
add_to_log() {
    local dir="$1"
    if [ -z "${log_entries["$dir"]}" ]; then
        echo "$dir" >> "$DIR_PATHS_LOG"
        log_entries["$dir"]=1
        if [ "$DEBUG" = true ]; then
            echo "Added to log: $dir"
        fi
    fi
    return 0
}

_remove_log_entry() {
    local target="${1:-}"
    local tmp line count selected parent
    local removed_count=0
    local parent_present=false
    local -a removed_entries=()

    if [[ -z "$target" ]]; then
        if [[ ! -s "$DIR_PATHS_LOG" ]]; then
            echo "No directory records found." >&2
            return 1
        fi
        count=$(sort -u "$DIR_PATHS_LOG" | wc -l)
        selected=$(
            sort -u "$DIR_PATHS_LOG" |
                fzf --height "$(( count + 2 ))" --prompt="Remove directory: "
        )
        [[ -n "$selected" ]] || {
            echo "No directory selected"
            return 1
        }
        target="$selected"
    elif [[ "$target" == "." ]]; then
        target=$(realpath ".") || return 1
    else
        target=$(realpath -m -- "$target") || return 1
    fi

    parent=$(realpath -m -- "$target/..") || return 1

    tmp=$(mktemp "${DIR_PATHS_LOG}.tmp.XXXXXX") || return 1
    while IFS= read -r line; do
        if [[ "$line" == "$target" ||
              ( "$target" == "/" && "$line" == /* ) ||
              ( "$target" != "/" && "$line" == "$target/"* ) ]]; then
            removed_entries+=("$line")
            (( removed_count++ ))
        else
            printf '%s\n' "$line"
            [[ "$line" == "$parent" ]] && parent_present=true
        fi
    done < "$DIR_PATHS_LOG" > "$tmp"

    if (( removed_count == 0 )); then
        rm -f "$tmp"
        echo "No directory records found under: $target" >&2
        return 1
    fi
    if [[ "$parent_present" == false ]]; then
        printf '%s\n' "$parent" >> "$tmp"
    fi
    if ! cat "$tmp" > "$DIR_PATHS_LOG"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    for line in "${removed_entries[@]}"; do
        unset "log_entries[$line]"
    done
    log_entries["$parent"]=1
    echo "Collapsed $removed_count directory record(s) to: $parent"
}

# Function to find current workspace root for a directory
get_workspace_root() {
    local dir="$1"
    local match=""

    for ws in "${workspaces[@]}"; do
        if [[ "$dir" == "$ws" || "$dir" == "$ws/"* ]] && (( ${#ws} > ${#match} )); then
            match="$ws"
        fi
    done
    echo "$match"
}

_add_workspace() {
    local path="$1"
    local name="${2:-}"
    local existing

    path=$(realpath "$path") || return 1
    for existing in "${workspaces[@]}"; do
        if [[ "$existing" == "$path" ]]; then
            echo "Workspace already exists: $path" >&2
            return 1
        fi
    done

    if [[ -z "$name" ]]; then
        read -r -p "Workspace name: " name || {
            echo "A workspace name is required." >&2
            return 1
        }
    fi
    if [[ -z "$name" || "$name" == *$'\t'* || "$name" =~ [[:cntrl:]] ]]; then
        echo "Workspace name must be non-empty and contain no control characters." >&2
        return 1
    fi
    for existing in "${workspaces[@]}"; do
        if [[ "${workspace_names["$existing"]}" == "$name" ]]; then
            echo "Workspace name already exists: $name" >&2
            return 1
        fi
    done

    printf '%s\t%s\n' "$path" "$name" >> "$WS_LIST_FILE" || return 1
    workspaces+=("$path")
    workspace_names["$path"]="$name"
    echo "Workspace added: $name ($path)"
}

_remove_workspace() {
    local target="$1"
    local remove_path="" existing tmp
    local -a remaining=()

    if [[ -d "$target" ]]; then
        target=$(realpath "$target") || return 1
    fi
    for existing in "${workspaces[@]}"; do
        if [[ "$existing" == "$target" || "${workspace_names["$existing"]}" == "$target" ]]; then
            remove_path="$existing"
            break
        fi
    done
    if [[ -z "$remove_path" ]]; then
        echo "Workspace not found: $target" >&2
        return 1
    fi

    tmp="${WS_LIST_FILE}.tmp"
    : > "$tmp" || return 1
    for existing in "${workspaces[@]}"; do
        if [[ "$existing" == "$remove_path" ]]; then
            continue
        fi
        printf '%s\t%s\n' "$existing" "${workspace_names["$existing"]}" >> "$tmp" || {
            rm -f "$tmp"
            return 1
        }
        remaining+=("$existing")
    done
    mv "$tmp" "$WS_LIST_FILE" || return 1
    workspaces=("${remaining[@]}")
    unset "workspace_names[$remove_path]"
    echo "Workspace removed: $remove_path"
}

# Function to handle workspace commands
ws() {
    local cmd="$1"
    local path="$2"
    local name="$3"

    if [[ -z "$cmd" ]]; then
        if (( ${#workspaces[@]} == 0 )); then
            echo "No workspaces defined."
            return 1
        fi
        local fzf_height=$(( ${#workspaces[@]} + 2 ))
        local selected selected_path workspace
        selected=$(
            for workspace in "${workspaces[@]}"; do
                printf '%s\t%s\n' "${workspace_names["$workspace"]}" "$workspace"
            done |
                fzf --height "$fzf_height" --delimiter=$'\t' --with-nth=1,2 \
                    --prompt="Select workspace: "
        )
        if [[ -n "$selected" ]]; then
            selected_path="${selected#*$'\t'}"
            cd "$selected_path" || return 1
            echo "Switched to workspace: ${workspace_names["$selected_path"]} ($selected_path)"
        else
            echo "No workspace selected"
            return 1
        fi
        return
    fi

    if [[ "$cmd" == "-" ]]; then
        local root
        root=$(get_workspace_root "$(pwd)")
        if [[ -n "$root" ]]; then
            cd "$root" || return 1
            echo "Switched to workspace root: $root"
        fi
        return
    fi

    if [[ "$cmd" == "." ]]; then
        _add_workspace "$(realpath ".")" "$path"
        return
    fi

    case "$cmd" in
        add)
            if [[ -z "$path" || ! -d "$path" ]]; then
                echo "Usage: ws add <valid_directory> [name]"
                return 1
            fi
            _add_workspace "$path" "$name"
            ;;
        remove)
            if [[ -z "$path" ]]; then
                echo "Usage: ws remove <path-or-name>"
                return 1
            fi
            _remove_workspace "$path"
            ;;
        *)
            echo "Usage: ws add <directory> [name] | ws remove <path-or-name> | ws . [name] | ws -"
            return 1
            ;;
    esac
}


# Main cc function
cc() {
    local target="$1"

    if [[ "$target" == "--install" ]]; then
        if (( $# != 1 )); then
            echo "Usage: cc --install" >&2
            return 1
        fi
        _cc_install
        return
    fi

    if [[ "$target" == "--update" ]]; then
        if (( $# != 1 )); then
            echo "Usage: cc --update" >&2
            return 1
        fi
        _cc_update
        return
    fi

    if [[ "$target" == "remove" ]]; then
        if (( $# > 2 )); then
            echo "Usage: cc remove [path|.]" >&2
            return 1
        fi
        _remove_log_entry "${2:-}"
        return
    fi

    if [[ "$target" == "-" ]]; then
        local root
        root=$(get_workspace_root "$(pwd)")
        if [[ -n "$root" ]]; then
            cd "$root" || return 1
            add_to_log "$(pwd)"
            return
        else
            cd ~ || return 1
            add_to_log "$(pwd)"
            return
        fi
    fi

    if [ -z "$target" ]; then
        cd ~ || return 1
        add_to_log "$(pwd)"
        return
    fi

    if [ -d "$target" ]; then
        cd "$target" || return 1
        add_to_log "$(pwd)"
        return
    fi

    local cwd_ws_root
    cwd_ws_root=$(get_workspace_root "$(pwd)")

    local target_lower="${target,,}"
    local path part built candidate_ws rank group label display
    local -a parts candidate_paths=() candidate_records=()
    declare -A seen_candidates=()

    # Build one record per matching directory. Records carry hidden sort fields
    # so fzf can keep the workspace groups together while displaying labels.
    while IFS= read -r path; do
        [[ "${path,,}" == *"$target_lower"* ]] || continue
        IFS='/' read -ra parts <<< "$path"
        built=""
        for part in "${parts[@]}"; do
            [[ -z "$part" ]] && continue
            built="$built/$part"
            [[ "${part,,}" == *"$target_lower"* ]] || continue
            [[ -n "${seen_candidates["$built"]:-}" ]] && continue
            seen_candidates["$built"]=1

            candidate_ws=$(get_workspace_root "$built")
            if [[ -n "$cwd_ws_root" && "$candidate_ws" == "$cwd_ws_root" ]]; then
                rank=0
                group="$candidate_ws"
                label=""
            elif [[ -n "$candidate_ws" ]]; then
                group="$candidate_ws"
                if [[ -n "$cwd_ws_root" ]]; then
                    rank=1
                    label="[${workspace_names["$candidate_ws"]}]"
                else
                    rank=0
                    label="[${workspace_names["$candidate_ws"]}]"
                fi
            else
                group=""
                if [[ -n "$cwd_ws_root" ]]; then
                    rank=2
                else
                    rank=1
                fi
                label=""
            fi

            display="$built"
            [[ -n "$label" ]] && display+=" $label"
            if [[ -n "$cwd_ws_root" && -n "$candidate_ws" && "$candidate_ws" != "$cwd_ws_root" ]]; then
                display=$'\033[38;5;250m'"$display"$'\033[0m'
            fi

            candidate_paths+=("$built")
            candidate_records+=("$rank"$'\t'"$group"$'\t'"${#built}"$'\t'"$display"$'\t'"$built")
        done
    done < "$DIR_PATHS_LOG"

    if (( ${#candidate_records[@]} == 0 )); then
        echo "No matches found for target: $target"
        return 1
    fi

    local choice
    if (( ${#candidate_records[@]} == 1 )); then
        choice="${candidate_paths[0]}"
    else
        local fzf_height=$(( ${#candidate_records[@]} + 2 ))
        local selected
        if [[ -z "$cwd_ws_root" ]]; then
            selected=$(
                printf '%s\n' "${candidate_records[@]}" |
                    LC_ALL=C sort -t $'\t' -k3,3nr -k5,5 |
                    fzf --height "$fzf_height" --delimiter=$'\t' --with-nth=4 \
                        --prompt="Select directory: "
            )
            choice="${selected##*$'\t'}"
        else
            selected=$(
                printf '%s\n' "${candidate_records[@]}" |
                    LC_ALL=C sort -t $'\t' -k1,1n -k2,2 -k3,3nr -k5,5 |
                    fzf --height "$fzf_height" --no-sort --ansi --delimiter=$'\t' \
                        --with-nth=4 --prompt="Select directory: "
            )
            choice="${selected##*$'\t'}"
        fi
    fi

    if [ -n "$choice" ]; then
        cd "$choice" || return 1
        add_to_log "$(pwd)"
        if [ "$DEBUG" = true ]; then
            echo "Changed directory to: $choice"
        fi
        return 0
    else
        echo "No directory selected"
        return 1
    fi
}

# Autocomplete and fzf shell integration are only useful in interactive shells.
if [[ $- == *i* ]]; then
    _cc_setup_fzf

    _cc_autocomplete() {
        local cur=${COMP_WORDS[COMP_CWORD]}
        local -a command_matches directory_matches

        if (( COMP_CWORD == 1 )); then
            if [[ "$cur" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "--install --update" -- "$cur")
            else
                mapfile -t command_matches < <(compgen -W "remove" -- "$cur")
                mapfile -t directory_matches < <(compgen -d -- "$cur")
                COMPREPLY=("${command_matches[@]}" "${directory_matches[@]}")
            fi
        else
            mapfile -t COMPREPLY < <(compgen -d -- "$cur")
        fi
    }

    _cc_install_autocomplete() {
        local cur=${COMP_WORDS[COMP_CWORD]}

        COMPREPLY=()
        if (( COMP_CWORD == 1 )); then
            mapfile -t COMPREPLY < <(compgen -W "--install --update" -- "$cur")
        fi
    }

    complete -o filenames -F _cc_autocomplete cc
    complete -F _cc_install_autocomplete cc.sh ./cc.sh
fi


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --install)
            (( $# == 1 )) || { echo "Usage: $0 --install" >&2; exit 1; }
            _cc_install
            ;;
        --update)
            (( $# == 1 )) || { echo "Usage: $0 --update" >&2; exit 1; }
            _cc_update
            ;;
        *)
            echo "Usage: $0 --install | --update" >&2
            exit 1
            ;;
    esac
fi
