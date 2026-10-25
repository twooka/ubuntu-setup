HISTFILE=~/.zsh_history; HISTSIZE=200000; SAVEHIST=200000
setopt share_history inc_append_history hist_ignore_all_dups hist_reduce_blanks \
       autocd extended_glob interactive_comments no_beep
bindkey -e
autoload -Uz compinit && compinit -C
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'
export PATH="$HOME/.local/bin:$PATH"
export EDITOR=nvim VISUAL=code PAGER=less MANPAGER="sh -c 'col -bx | batcat -l man -p'"
alias ls='eza --group-directories-first'
alias ll='eza -lah --git --group-directories-first'
alias lt='eza --tree --level=2'
alias cat='batcat --paging=never'
alias fd='fdfind'
alias top='btop'
alias y='yazi'
alias py='uv run python'
[[ -o interactive && $TERM_PROGRAM != vscode && -r ~/.config/fastfetch/welcome.jsonc ]] && fastfetch -c ~/.config/fastfetch/welcome.jsonc
command -v mise >/dev/null && eval "$(mise activate zsh)"
export PATH="$HOME/.elan/bin:$HOME/.pixi/bin:$PATH"
eval "$(starship init zsh)"
eval "$(zoxide init zsh --cmd cd)"
source <(fzf --zsh)
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
alias vpn='protonvpn connect --country CH'
alias vpnoff='protonvpn disconnect'
alias vpnip='curl -s https://ipinfo.io | grep -E "\"ip\"|\"city\"|\"country\"|\"org\""'
export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
