# cc

Fast Bash directory navigation powered by `fzf`, with named workspaces and workspace-aware results.

## Install

```bash
git clone git@github.com:ehsanfarajollahi/cc.git
cd cc
bash cc.sh --install
source ~/.bashrc
```

## Usage

```bash
cc <name>                  # Jump to a matching logged directory
cc -                       # Jump to the current workspace root, or home
cc --remove [path|.]       # Collapse a path and descendants to its parent
cc --update                # Download and install the latest cc.sh
cc --ws                    # Select a workspace
cc --ws add <dir> [name]   # Add a workspace
cc --ws remove [path|name] # Remove directly or select a workspace
cc --ws -                  # Jump to the current workspace root
```

`cc` stores visited directories in `~/.cc_cd_log` and named workspaces in `~/.cc_ws`.
