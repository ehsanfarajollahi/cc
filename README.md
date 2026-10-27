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
cc remove [path|.]         # Remove a logged directory, or select one
cc --update                # Download and install the latest cc.sh
ws                        # Select a workspace
ws . [name]               # Add the current directory as a workspace
ws add <directory> [name] # Add a workspace
ws remove <path-or-name>  # Remove a workspace
ws -                      # Jump to the current workspace root
```

`cc` stores visited directories in `~/.cc_cd_log` and named workspaces in `~/.cc_ws`.
