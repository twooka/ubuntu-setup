#!/usr/bin/env bash
# Ubuntu 26.04 set-and-forget setup — staged.
# Usage:  ./ubuntu-setup.sh 1   → base + tuning            → REBOOT
#         ./ubuntu-setup.sh 2   → theme, GNOME, dock, ext  → LOG OUT/IN
#         ./ubuntu-setup.sh 3   → terminal, files, apps    → LOG OUT/IN
#         (manual: Vitals sensors, Firefox Sync, Timeshift wizard)
#         ./ubuntu-setup.sh 6   → Proton VPN (CH default, kill switch, autoconnect) + TLP
#         ./ubuntu-setup.sh 7   → look: login screen, avatar, boot splash (from ~/dotfiles/assets)
#         ./ubuntu-setup.sh 8   → dev toolchain: uv, mise (node/pnpm/go/bun/doctl/gh/vercel), Lean, pixi(+Sage), Podman
#         ./ubuntu-setup.sh 9   → VS Code profiles LaTeX, Coding, ML Code, Lean (extensions + settings from ~/dotfiles/vscode)
#         ./ubuntu-setup.sh 4   → verify + freeze to ~/dotfiles
#         ./ubuntu-setup.sh 5   → restore from ~/dotfiles (fresh install; then run 6 for VPN sign-in)
# Run as your user (not root). Each stage is idempotent.
set -uo pipefail
[ "$(id -u)" -eq 0 ] && { echo "run as your user, not root"; exit 1; }
say(){ printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
has(){ dpkg -s "$1" &>/dev/null; }
backup(){ [ -e "$1" ] && cp -a "$1" "$1.bak.$(date +%s)"; }

stage1() {
  say "Base"
  sudo apt update && sudo apt full-upgrade -y
  sudo fwupdmgr refresh --force || true
  sudo fwupdmgr update -y || true
  sudo ubuntu-drivers install --recommended || true
  sudo apt install -y ubuntu-restricted-extras software-properties-gtk gnome-tweaks \
    gnome-shell-extension-manager gnome-shell-extensions flatpak build-essential \
    git curl wget jq x11-utils
  flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  sudo ufw --force enable

  say "zram"
  if sudo apt install -y systemd-zram-generator; then
    sudo tee /etc/systemd/zram-generator.conf >/dev/null <<'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
EOF
    sudo systemctl daemon-reload
    sudo systemctl start systemd-zram-setup@zram0 || true
  else
    sudo apt install -y zram-tools
    printf 'ALGO=zstd\nPERCENT=50\nPRIORITY=100\n' | sudo tee /etc/default/zramswap >/dev/null
    sudo systemctl restart zramswap
  fi

  say "sysctl"
  sudo tee /etc/sysctl.d/99-local.conf >/dev/null <<'EOF'
vm.swappiness = 180
vm.page-cluster = 0
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
EOF
  sudo sysctl --system >/dev/null

  say "Remove kdump / apport"
  for p in kdump-tools linux-crashdump; do has "$p" && sudo apt purge -y "$p"; done
  sudo update-grub
  sudo systemctl disable --now apport.service apport-autoreport.timer 2>/dev/null || true
  [ -f /etc/default/apport ] && sudo sed -i 's/^enabled=1/enabled=0/' /etc/default/apport

  say "Services"
  sudo systemctl disable NetworkManager-wait-online.service || true
  sudo systemctl disable --now cups-browsed.service 2>/dev/null || true
  # uncomment what you don't use:
  # sudo systemctl disable --now ModemManager.service
  # sudo systemctl disable --now bluetooth.service

  say "Journald cap"
  sudo mkdir -p /etc/systemd/journald.conf.d
  printf '[Journal]\nSystemMaxUse=200M\n' | sudo tee /etc/systemd/journald.conf.d/size.conf >/dev/null
  sudo systemctl restart systemd-journald

  say "uv / gext"
  command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh
  export PATH="$HOME/.local/bin:$PATH"
  uv tool install gnome-extensions-cli || uv tool upgrade gnome-extensions-cli

  say "Stage 1 done → REBOOT, then: swapon --show ; grep -c crashkernel /proc/cmdline"
}

stage2() {
  export PATH="$HOME/.local/bin:$PATH"
  say "Fonts / theme"
  sudo apt install -y fonts-jetbrains-mono fonts-inter qt6ct
  flatpak install -y flathub org.gtk.Gtk3theme.adw-gtk3-dark || true
  I=org.gnome.desktop.interface
  gsettings set $I color-scheme 'prefer-dark'
  gsettings set $I gtk-theme 'Yaru-dark'
  gsettings set $I icon-theme 'Yaru-dark'
  gsettings set $I cursor-theme 'Yaru'
  gsettings set $I font-name 'Inter 11'
  gsettings set $I document-font-name 'Inter 11'
  gsettings set $I monospace-font-name 'JetBrains Mono 11'
  gsettings set $I font-antialiasing 'grayscale'
  gsettings set $I font-hinting 'slight'
  gsettings set $I clock-show-weekday true
  gsettings set $I clock-show-date true
  gsettings set $I show-battery-percentage true
  gsettings set $I enable-hot-corners false
  mkdir -p ~/.config/environment.d
  echo 'QT_QPA_PLATFORMTHEME=qt6ct' > ~/.config/environment.d/qt.conf

  say "Behaviour"
  gsettings set org.gnome.mutter center-new-windows true
  gsettings set org.gnome.mutter dynamic-workspaces false
  gsettings set org.gnome.desktop.wm.preferences num-workspaces 4
  gsettings set org.gnome.desktop.wm.preferences button-layout 'appmenu:close'
  gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click true
  gsettings set org.gnome.desktop.peripherals.touchpad natural-scroll true
  gsettings set org.gnome.desktop.input-sources xkb-options "['caps:ctrl_modifier']"
  gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled true
  gsettings set org.gnome.desktop.privacy remember-recent-files false
  gsettings set org.gnome.desktop.privacy remove-old-trash-files true
  gsettings set org.gnome.desktop.privacy old-files-age 14
  gsettings set org.gnome.desktop.notifications show-in-lock-screen false

  say "Keybindings"
  gsettings set org.gnome.desktop.wm.keybindings close "['<Super>q','<Alt>F4']"
  for i in 1 2 3 4; do
    gsettings set org.gnome.shell.keybindings switch-to-application-$i "[]"
    gsettings set org.gnome.desktop.wm.keybindings switch-to-workspace-$i "['<Super>$i']"
    gsettings set org.gnome.desktop.wm.keybindings move-to-workspace-$i "['<Super><Shift>$i']"
  done

  say "Dock auto-hide, desktop icons off"
  D=org.gnome.shell.extensions.dash-to-dock
  gsettings set $D dock-fixed false
  gsettings set $D autohide true
  gsettings set $D intellihide false
  gsettings set $D extend-height false
  gsettings set $D dock-position 'BOTTOM'
  gsettings set $D dash-max-icon-size 36
  gsettings set $D show-trash false
  gsettings set $D show-mounts false
  gsettings set $D click-action 'minimize-or-previews'
  # purist: gnome-extensions disable ubuntu-dock@ubuntu.com
  gnome-extensions disable ding@rastersoft.com 2>/dev/null || true

  say "Extensions"
  gext install just-perfection-desktop@just-perfection Vitals@CoreCoding.com
  J=/org/gnome/shell/extensions/just-perfection
  dconf write $J/activities-button false
  dconf write $J/workspace-popup false
  dconf write $J/startup-status 0
  dconf write $J/window-demands-attention-focus true
  dconf write $J/search true
  dconf write $J/world-clock false
  dconf write $J/weather false
  dconf write $J/events-button false
  dconf write $J/panel-size 28
  dconf write $J/animation 4

  say "Stage 2 done → LOG OUT/IN"
}

stage3() {
  export PATH="$HOME/.local/bin:$PATH"
  say "Enable extensions (post-login)"
  gnome-extensions enable just-perfection-desktop@just-perfection || true
  gnome-extensions enable Vitals@CoreCoding.com || true

  say "Terminal + CLI"
  sudo apt install -y ghostty zsh zsh-autosuggestions zsh-syntax-highlighting starship \
    fzf zoxide eza bat ripgrep fd-find git-delta btop fastfetch tealdeer neovim \
    htop ncdu duf tree unzip p7zip-full sshfs
  sudo snap install yazi --classic || true
  tldr --update || true
  [ "$(getent passwd "$USER" | cut -d: -f7)" != /usr/bin/zsh ] && chsh -s /usr/bin/zsh

  sudo update-alternatives --set x-terminal-emulator /usr/bin/ghostty 2>/dev/null || true
  echo 'com.mitchellh.ghostty.desktop' > ~/.config/xdg-terminals.list
  KB=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/
  gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['$KB']"
  gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KB name 'Terminal'
  gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KB command 'ghostty'
  gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KB binding '<Super>Return'

  mkdir -p ~/.config/ghostty; backup ~/.config/ghostty/config
  cat > ~/.config/ghostty/config <<'EOF'
theme = Catppuccin Mocha
font-family = JetBrains Mono
font-size = 11
window-padding-x = 10
window-padding-y = 6
window-decoration = none
gtk-single-instance = true
confirm-close-surface = false
copy-on-select = clipboard
mouse-hide-while-typing = true
shell-integration = zsh
cursor-style = block
cursor-style-blink = false
EOF
  ghostty +validate-config || echo "!! fix ghostty config (theme name?)"

  backup ~/.zshrc
  cat > ~/.zshrc <<'EOF'
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
alias vpn='protonvpn connect --country CH'
alias vpnoff='protonvpn disconnect'
alias vpnip='curl -s https://ipinfo.io | grep -E "\"ip\"|\"city\"|\"country\"|\"org\""'
[[ -o interactive && $TERM_PROGRAM != vscode && -r ~/.config/fastfetch/welcome.jsonc ]] && fastfetch -c ~/.config/fastfetch/welcome.jsonc
command -v mise >/dev/null && eval "$(mise activate zsh)"
export PATH="$HOME/.elan/bin:$HOME/.pixi/bin:$PATH"
eval "$(starship init zsh)"
eval "$(zoxide init zsh --cmd cd)"
source <(fzf --zsh)
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
EOF

  git config --global core.pager delta
  git config --global interactive.diffFilter 'delta --color-only'
  git config --global delta.navigate true
  git config --global delta.side-by-side true
  git config --global merge.conflictstyle zdiff3
  git config --global init.defaultBranch main
  git config --global pull.rebase true

  say "Nautilus"
  N=org.gnome.nautilus.preferences
  gsettings set $N default-folder-viewer 'list-view'
  gsettings set $N show-create-link true
  gsettings set $N show-delete-permanently true
  gsettings set $N recursive-search 'local-only'
  gsettings set $N show-image-thumbnails 'local-only'
  gsettings set org.gnome.nautilus.list-view use-tree-view true
  gsettings set org.gnome.nautilus.list-view default-zoom-level 'small'
  gsettings set org.gtk.gtk4.Settings.FileChooser sort-directories-first true

  say "VS Code repo"
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /usr/share/keyrings/microsoft.gpg >/dev/null
  sudo tee /etc/apt/sources.list.d/vscode.sources >/dev/null <<'EOF'
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/microsoft.gpg
EOF

  say "Firefox repo (deb)"
  sudo install -d -m 0755 /etc/apt/keyrings
  wget -qO- https://packages.mozilla.org/apt/repo-signing-key.gpg | sudo tee /etc/apt/keyrings/packages.mozilla.org.asc >/dev/null
  sudo tee /etc/apt/sources.list.d/mozilla.sources >/dev/null <<'EOF'
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc
EOF
  sudo tee /etc/apt/preferences.d/mozilla >/dev/null <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF
  sudo apt update
  sudo apt install -y code
  if snap list firefox &>/dev/null; then
    read -rp "Replace Firefox snap with deb? Snap profile is DELETED — Sync first. [y/N] " a
    [[ $a == [yY] ]] && sudo snap remove --purge firefox
  fi
  # Ubuntu's transitional "1:1snap1" has an epoch → outranks Mozilla's build; pin + downgrade replaces it
  if ! snap list firefox &>/dev/null; then
    sudo apt install -y --allow-downgrades firefox
    apt policy firefox 2>/dev/null | grep -q 'Installed:.*snap' && echo "!! still the snap stub — check /etc/apt/preferences.d/mozilla"
  fi

  say "Dock favourites"
  gsettings set org.gnome.shell favorite-apps "['firefox.desktop', 'com.mitchellh.ghostty.desktop', 'org.gnome.Nautilus.desktop', 'code.desktop', 'md.obsidian.Obsidian.desktop']"

  say "TeX + apps"
  sudo apt install -y texlive-full latexmk biber chktex timeshift
  flatpak install -y flathub md.obsidian.Obsidian com.mattjakeman.ExtensionManager io.github.flattool.Ignition

  say "Stage 3 done → LOG OUT/IN. Then manually: Vitals prefs, Firefox Sync, VS Code Settings Sync, Timeshift wizard. Then stage 4."
}

stage4() {
  say "Verify"
  swapon --show
  echo "crashkernel in cmdline: $(grep -c crashkernel /proc/cmdline)"
  systemd-analyze
  systemd-analyze blame | head -15
  powerprofilesctl get
  gsettings get org.gnome.desktop.interface color-scheme
  gnome-extensions list --enabled
  echo "shell: $SHELL"; ghostty +version | head -1
  apt policy firefox | sed -n 1,4p
  sudo ufw status | head -1
  systemctl list-unit-files --state=enabled --no-pager | head -40

  say "Freeze → ~/dotfiles"
  D=~/dotfiles; mkdir -p $D/etc $D/config && cd $D
  [ -d .git ] || git init -q
  # dconf without personal state (app grid, last folders, online-account ids, file-chooser history)
  dconf dump / | awk '
    /^\[/ { skip = ($0 ~ /^\[org\/gnome\/portal\/filechooser\// || $0 ~ /window-state\]$/ || $0 ~ /^\[org\/yorba\//) }
    skip { next }
    /^(app-picker-layout|last-folder-path|goa-account-id|location-data|keyrings-selected|last-panel|welcome-dialog-last-shown-version|window-(size|position|maximized)|sidebar-width)=/ { next }
    { print }' | cat -s > gnome.dconf
  gnome-extensions list --enabled > extensions.txt
  apt-mark showmanual > apt-manual.txt
  flatpak list --app --columns=application > flatpak.txt
  cp -a ~/.zshrc .
  # git config without identity / machine paths; identity lives in ~/.gitconfig.local (never committed)
  cp ~/.gitconfig .gitconfig
  git config -f .gitconfig --remove-section user 2>/dev/null || true
  git config -f .gitconfig --unset-all safe.directory 2>/dev/null || true
  git config -f .gitconfig --get include.path >/dev/null || git config -f .gitconfig include.path '~/.gitconfig.local'
  # conky: both widgets (conky.conf + hw.sh + ascii.lua, hud.conf + orrery2.lua); autostart: conky + HUD entries
  for d in ghostty conky autostart fastfetch mise uv; do [ -e ~/.config/$d ] && { rm -rf config/$d; cp -a ~/.config/$d config/; }; done
  [ -e ~/.config/starship.toml ] && cp -a ~/.config/starship.toml config/
  cp -a ~/.config/xdg-terminals.list config/ 2>/dev/null || true
  # systemd user units managed by this setup only (allow-list), env; Nautilus bookmarks are NOT saved (folder names)
  local UNITS='protonvpn-connect|rclone-proton'
  rm -rf config/systemd-user config/gtk-3.0; mkdir -p config/systemd-user
  for u in ~/.config/systemd/user/*.service ~/.config/systemd/user/*.timer ~/.config/systemd/user/*.service.d; do
    [ -e "$u" ] && basename "$u" | grep -qE "^($UNITS)\." && cp -a "$u" config/systemd-user/
  done
  systemctl --user list-unit-files --state=enabled --no-legend | awk '{print $1}' \
    | grep -E "^($UNITS)\.(service|timer)$" > systemd-user-enabled.txt || true
  cp -a ~/.config/environment.d config/ 2>/dev/null || true
  # rclone: remote names/types only — NEVER the credentials
  command -v rclone >/dev/null && rclone listremotes --long > rclone-remotes.txt
  printf '%s\n' rclone.conf '*.bak.*' '.gitconfig.local' 'config/gtk-3.0/' > .gitignore
  for f in /etc/sysctl.d/99-local.conf /etc/systemd/zram-generator.conf \
           /etc/apt/sources.list.d/mozilla.sources /etc/apt/sources.list.d/vscode.sources \
           /etc/apt/preferences.d/mozilla /etc/systemd/journald.conf.d/size.conf \
           /etc/default/zramswap /etc/tlp.d/01-local.conf; do
    [ -e "$f" ] && cp -a "$f" etc/
  done
  # look: login-screen dconf, installed boot-splash script (assets/ holds avatar, emblem, plymouth theme)
  command -v uv >/dev/null && uv tool list 2>/dev/null | awk '/^[a-z0-9]/{print $1}' > uv-tools.txt
  if command -v code >/dev/null; then
    mkdir -p vscode
    for prof in LaTeX Coding "ML Code" Lean; do
      pd=$(vscode_profile_dir "$prof"); f=$(echo "$prof" | tr "A-Z " "a-z-")
      [ -n "$pd" ] && [ -f "$pd/settings.json" ] && cp "$pd/settings.json" "vscode/$f.settings.json"
    done
  fi
  mkdir -p etc/gdm
  [ -e /etc/dconf/profile/gdm ] && cp /etc/dconf/profile/gdm etc/gdm/profile-gdm
  [ -e /etc/dconf/db/gdm.d/01-local ] && cp /etc/dconf/db/gdm.d/01-local etc/gdm/01-local
  [ -e /usr/share/plymouth/themes/prompt/prompt.script ] && mkdir -p assets/plymouth-prompt \
    && cp /usr/share/plymouth/themes/prompt/prompt.script assets/plymouth-prompt/
  # never commit with a personal address; never commit anything gitleaks flags
  local em; em=$(git config user.email || true)
  case "$em" in *@users.noreply.github.com|"") ;; *)
    echo "!! repo commits would use '$em' — set a no-reply address for this repo:"
    echo "   git -C $D config user.email '<id>+<user>@users.noreply.github.com'"; return 1 ;; esac
  if command -v gitleaks >/dev/null; then
    gitleaks dir . --no-banner --redact >/dev/null 2>&1 || { echo "!! gitleaks found possible secrets — run: gitleaks dir ~/dotfiles --redact -v"; return 1; }
  else echo "  (install gitleaks for a secret scan before each commit: mise use -g gitleaks)"; fi
  git add -A && git commit -qm "snapshot $(date +%F)" && echo "committed in $D — push it off-machine"
}

# ---------------------------------------------------------------- repos used by stage 5 and 6
PVPN_DEB=protonvpn-stable-release_1.0.10_all.deb
PVPN_SHA=c8a9fffb4ebdd63db08ce7f11c9b0ac394064ae6a210feb9ab63a0f7d8d060a7
proton_repo() {
  dpkg -s protonvpn-stable-release &>/dev/null && return 0
  local tmp; tmp=$(mktemp -d)
  wget -q -O "$tmp/$PVPN_DEB" "https://repo.protonvpn.com/debian/dists/stable/main/binary-all/$PVPN_DEB" \
    && echo "$PVPN_SHA  $tmp/$PVPN_DEB" | sha256sum --check - \
    || { echo "!! Proton repo package download/checksum failed — get the current one from"
         echo "   https://protonvpn.com/support/official-ubuntu-vpn-setup and update PVPN_DEB/PVPN_SHA"; return 1; }
  sudo dpkg -i "$tmp/$PVPN_DEB" && sudo apt update
}
tlp_repo() {   # TLP >= 1.9 ships tlp-pd (keeps GNOME's power-mode menu); PPA only if the archive lacks it
  apt-cache show tlp-pd &>/dev/null && return 0
  sudo add-apt-repository -y ppa:linrunner/tlp && sudo apt update
}

stage6() {
  export PATH="$HOME/.local/bin:$PATH"
  say "Proton VPN"
  proton_repo || return 1
  sudo apt install -y proton-vpn-gnome-desktop
  pkill -f -i protonvpn-app 2>/dev/null || true          # GUI and CLI can't run together
  if ! protonvpn connect --country CH; then
    read -rp "Proton username: " PU
    protonvpn signin "$PU" && protonvpn connect --country CH
  fi
  say "Proton VPN settings (lost on signout)"
  protonvpn config set vpn-accelerator on || true
  protonvpn config set kill-switch advanced \
    || { echo "!! kill-switch value not accepted; valid values:"; protonvpn config set kill-switch; }
  echo ">> netshield levels (set manually: protonvpn config set netshield <level>):"
  protonvpn config set netshield 2>&1 | head -6 || true

  say "Auto-connect to Switzerland at login"
  mkdir -p ~/.config/systemd/user
  cat > ~/.config/systemd/user/protonvpn-connect.service <<'EOF'
[Unit]
Description=Proton VPN auto-connect
After=graphical-session.target network-online.target
PartOf=graphical-session.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/env protonvpn connect --country CH
ExecStop=/usr/bin/env protonvpn disconnect

[Install]
WantedBy=graphical-session.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable protonvpn-connect.service
  grep -q "alias vpn=" ~/.zshrc || cat >> ~/.zshrc <<'EOF'
alias vpn='protonvpn connect --country CH'
alias vpnoff='protonvpn disconnect'
alias vpnip='curl -s https://ipinfo.io | grep -E "\"ip\"|\"city\"|\"country\"|\"org\""'
EOF
  curl -s https://ipinfo.io | grep -E '"country"|"org"' || true

  say "TLP (replaces power-profiles-daemon; tlp-pd keeps GNOME's power-mode menu)"
  tlp_repo || true
  sudo apt install -y tlp tlp-rdw
  sudo apt install -y tlp-pd || echo "!! tlp-pd not available — GNOME power-mode menu will be gone"
  sudo mkdir -p /etc/tlp.d
  sudo tee /etc/tlp.d/01-local.conf >/dev/null <<'EOF'
# Local overrides — everything else stays at TLP defaults (AC: performance, BAT: powersave).
# Battery care: charge only between 75 % and 80 % (Dell: dell-laptop driver). Full charge once: sudo tlp fullcharge
START_CHARGE_THRESH_BAT0=75
STOP_CHARGE_THRESH_BAT0=80
# tlp-rdw examples (off by default):
#DEVICES_TO_DISABLE_ON_LAN_CONNECT="wifi"
#DEVICES_TO_ENABLE_ON_LAN_DISCONNECT="wifi"
EOF
  sudo systemctl enable --now tlp.service
  sudo systemctl mask systemd-rfkill.service systemd-rfkill.socket
  sudo tlp start
  sudo tlp-stat -s | sed -n '/+++ TLP Status/,/^$/p'
  sudo tlp-stat -b | grep -E 'charge_control|charge_.*threshold' || true
  say "Stage 6 done. Kill switch is ADVANCED: no internet unless connected (vpn / vpnoff + 'protonvpn config set kill-switch off')."
}

# ---------------------------------------------------------------- look (stage 7, also run by stage 5)
rebuild_initramfs() {
  if command -v update-initramfs >/dev/null; then sudo update-initramfs -u -k all; else sudo dracut -f --regenerate-all; fi
}
apply_look() {
  local D=~/dotfiles A=~/dotfiles/assets
  say "Login screen (GDM): black, dark, green accent"
  if [ -f $D/etc/gdm/01-local ]; then
    sudo mkdir -p /etc/dconf/profile /etc/dconf/db/gdm.d
    if [ -f $D/etc/gdm/profile-gdm ]; then sudo cp $D/etc/gdm/profile-gdm /etc/dconf/profile/gdm
    else printf 'user-db:user\nsystem-db:gdm\n' | sudo tee /etc/dconf/profile/gdm >/dev/null; fi
    [ -f /usr/share/gdm/greeter-dconf-defaults ] || sudo sed -i '/file-db/d' /etc/dconf/profile/gdm
    sudo cp $D/etc/gdm/01-local /etc/dconf/db/gdm.d/01-local
    sudo dconf update
  fi
  say "Avatar"
  [ -f $A/avatar.png ] && busctl call org.freedesktop.Accounts /org/freedesktop/Accounts/User$(id -u) \
    org.freedesktop.Accounts.User SetIconFile s "$A/avatar.png"
  say "Boot splash: prompt theme"
  if [ -f $A/plymouth-prompt/prompt.plymouth ]; then
    local T=/usr/share/plymouth/themes/prompt
    ls /usr/lib/*/plymouth/script.so >/dev/null 2>&1 || sudo apt install -y plymouth-themes
    sudo rm -rf "$T"; sudo cp -r "$A/plymouth-prompt" "$T"
    sudo update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth "$T/prompt.plymouth" 210
    sudo update-alternatives --set default.plymouth "$T/prompt.plymouth"
    printf '[Daemon]\nTheme=prompt\n' | sudo tee /etc/plymouth/plymouthd.conf >/dev/null
    rebuild_initramfs
  fi
}
stage7() { apply_look; say "Stage 7 done → log out (login screen), reboot (boot splash)"; }

# ---------------------------------------------------------------- dev toolchain (stage 8, also run by stage 5)
stage8() {
  export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$HOME/.elan/bin:$HOME/.pixi/bin:$PATH"

  say "uv: Python versions, venvs, deps, CLI tools"
  command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh
  mkdir -p ~/.config/uv
  [ -f ~/.config/uv/uv.toml ] || printf 'python-preference = "managed"\n' > ~/.config/uv/uv.toml
  uv python install
  # migrate the old pipx tool, then install CLI tools
  command -v pipx >/dev/null && pipx list --short 2>/dev/null | grep -q gnome-extensions-cli && pipx uninstall gnome-extensions-cli
  local tools="ruff pre-commit jupyterlab gnome-extensions-cli"
  [ -s ~/dotfiles/uv-tools.txt ] && tools="$tools $(tr '\n' ' ' < ~/dotfiles/uv-tools.txt)"
  for t in $(echo $tools | tr ' ' '\n' | sort -u); do uv tool install "$t" >/dev/null 2>&1 || uv tool upgrade "$t" >/dev/null 2>&1 || echo "  !! uv tool: $t"; done

  say "mise: node, pnpm, go, bun, doctl, gh, vercel"
  command -v mise >/dev/null || curl -fsSL https://mise.run | MISE_INSTALL_PATH="$HOME/.local/bin/mise" sh
  mkdir -p ~/.config/mise
  [ -f ~/.config/mise/config.toml ] || cat > ~/.config/mise/config.toml <<'EOF'
# global defaults — projects override with their own mise.toml (`mise use node@22`)
[tools]
node = "lts"
pnpm = "latest"
go = "latest"
bun = "latest"
doctl = "latest"
gh = "latest"
"npm:vercel" = "latest"

[settings]
idiomatic_version_file_enable_tools = ["node"]   # honour .nvmrc / .node-version
EOF
  mise install -y
  mise reshim

  say "Lean 4 (elan)"
  command -v elan >/dev/null || curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
    | sh -s -- -y --no-modify-path --default-toolchain stable

  say "pixi (conda-forge)"
  command -v pixi >/dev/null || curl -fsSL https://pixi.sh/install.sh | PIXI_NO_PATH_UPDATE=1 sh
  if ! command -v sage >/dev/null; then
    read -rp "Install SageMath via pixi now (several GB)? [y/N] " a
    [[ $a == [yY] ]] && pixi global install sage
  fi

  say "Podman (rootless containers, Docker-compatible)"
  sudo apt install -y podman podman-compose

  say "Shell + desktop session PATH"
  grep -q 'mise activate zsh' ~/.zshrc || echo 'command -v mise >/dev/null && eval "$(mise activate zsh)"' >> ~/.zshrc
  grep -q '.elan/bin' ~/.zshrc || echo 'export PATH="$HOME/.elan/bin:$HOME/.pixi/bin:$PATH"' >> ~/.zshrc
  grep -q "alias py=" ~/.zshrc || echo "alias py='uv run python'" >> ~/.zshrc
  mkdir -p ~/.config/environment.d
  cat > ~/.config/environment.d/50-dev-path.conf <<'EOF'
# GUI apps (VS Code from the launcher) see the same tools as the terminal; applies from next login
PATH=$HOME/.local/share/mise/shims:$HOME/.elan/bin:$HOME/.pixi/bin:$HOME/.local/bin:$PATH
EOF

  say "Versions"
  printf '  %-10s ' python; uv run --no-project python --version 2>/dev/null || echo missing
  for c in uv node pnpm go bun doctl gh vercel elan pixi podman; do
    printf '  %-10s ' "$c"; (timeout 10 $c --version 2>/dev/null || timeout 10 $c version 2>/dev/null) </dev/null | head -1 || echo "missing/timeout"
  done
  printf '  %-10s ' lean; timeout 10 elan show 2>/dev/null </dev/null | grep -m1 -E 'leanprover|default' || echo "run: elan toolchain install stable"
  say "Stage 8 done → open a new terminal (log out/in for GUI apps)"
}

# ---------------------------------------------------------------- VS Code profiles (stage 9, also run by stage 5)
vscode_profile_dir() {   # profile name → its settings dir (empty if VS Code doesn't know it yet)
  python3 - "$1" <<'PY'
import json, os, sys
f = os.path.expanduser('~/.config/Code/User/globalStorage/storage.json')
try: d = json.load(open(f))
except Exception: sys.exit()
for p in d.get('userDataProfiles', []):
    if p.get('name') == sys.argv[1]:
        print(os.path.expanduser('~/.config/Code/User/profiles/' + p['location']))
PY
}
stage9() {
  local V=~/dotfiles/vscode
  command -v code >/dev/null || { echo "!! VS Code not installed (stage 3)"; return 1; }
  [ -d "$V" ] || { echo "!! $V missing"; return 1; }

  sudo apt install -y fonts-juliamono >/dev/null 2>&1 || true   # Unicode fallback for the Lean profile
  say "Podman behind the Docker API (Container Tools, Dev Containers, docker.docker)"
  sudo apt install -y podman-docker >/dev/null 2>&1 || true
  systemctl --user enable --now podman.socket
  mkdir -p ~/.config/environment.d
  echo 'DOCKER_HOST=unix://${XDG_RUNTIME_DIR}/podman/podman.sock' > ~/.config/environment.d/60-podman.conf
  grep -q DOCKER_HOST ~/.zshrc || echo 'export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"' >> ~/.zshrc

  for prof in LaTeX Coding "ML Code" Lean; do
    local f; f=$(echo "$prof" | tr "A-Z " "a-z-")
    say "VS Code profile: $prof"
    local dir; dir=$(vscode_profile_dir "$prof")
    if [ -z "$dir" ]; then
      echo ">> creating profile '$prof' — a VS Code window opens; close it when it has loaded"
      code --profile "$prof" --new-window >/dev/null 2>&1 &
      for _ in $(seq 30); do sleep 2; dir=$(vscode_profile_dir "$prof"); [ -n "$dir" ] && break; done
      [ -n "$dir" ] || { echo "!! profile $prof not created; run 'code --profile $prof' once and re-run stage 9"; continue; }
    fi
    local want; want=$(sed 's/#.*//' "$V/$f.extensions.txt" | awk 'NF{print tolower($1)}')
    for e in $want; do
      code --profile "$prof" --list-extensions 2>/dev/null | tr A-Z a-z | grep -qx "$e" && continue
      code --profile "$prof" --install-extension "$e" >/dev/null 2>&1 && echo "  + $e" || echo "  !! $e"
    done
    # remove anything not in the list (dependencies of listed extensions are re-added automatically)
    for e in $(code --profile "$prof" --list-extensions 2>/dev/null | tr A-Z a-z); do
      echo "$want" | grep -qx "$e" && continue
      case "$e" in ms-toolsai.*|ms-python.*|github.*) continue ;; esac     # extension-pack members
      code --profile "$prof" --uninstall-extension "$e" >/dev/null 2>&1 && echo "  - $e"
    done
    mkdir -p "$dir"
    [ -f "$dir/settings.json" ] && cp "$dir/settings.json" "$dir/settings.json.bak.$(date +%s)"
    cp "$V/$f.settings.json" "$dir/settings.json"
    echo "  settings → $dir/settings.json"
  done
  say "Stage 9 done → in VS Code: profile switcher (gear ▸ Profiles) or 'code --profile LaTeX <folder>'"
}

stage5() {
  # Restore from ~/dotfiles on a fresh install (after stages 1–3)
  export PATH="$HOME/.local/bin:$PATH"
  D=~/dotfiles; [ -d $D ] || { echo "clone your dotfiles to $D first"; exit 1; }
  cd $D
  say "Packages"
  grep -q '^proton-vpn-gnome-desktop$' apt-manual.txt && proton_repo
  grep -q '^tlp' apt-manual.txt && tlp_repo
  xargs -a apt-manual.txt sudo apt install -y --allow-downgrades \
    || while read -r p; do sudo apt install -y --allow-downgrades "$p" >/dev/null 2>&1 || echo "  skipped: $p"; done < apt-manual.txt
  [ -s flatpak.txt ] && xargs -a flatpak.txt flatpak install -y flathub || true
  say "Extensions + GNOME settings"
  xargs -a extensions.txt -n1 gext install || true
  dconf load / < gnome.dconf
  say "Configs"
  cp -a .zshrc .gitconfig ~/
  if [ ! -f ~/.gitconfig.local ]; then
    read -rp "git name: " GN; read -rp "git email: " GE
    git config -f ~/.gitconfig.local user.name "$GN"; git config -f ~/.gitconfig.local user.email "$GE"
  fi
  mkdir -p ~/.config
  for d in ghostty conky autostart environment.d fastfetch mise uv; do [ -e config/$d ] && { mkdir -p ~/.config/$d; cp -a config/$d/. ~/.config/$d/; }; done
  [ -e config/starship.toml ] && cp -a config/starship.toml ~/.config/
  [ -e config/xdg-terminals.list ] && cp -a config/xdg-terminals.list ~/.config/
  mkdir -p ~/.config/gtk-3.0
  grep -qs ProtonDrive ~/.config/gtk-3.0/bookmarks || echo "file://$HOME/ProtonDrive Proton Drive" >> ~/.config/gtk-3.0/bookmarks
  sed -i "s|/home/[^/]*/|$HOME/|g" ~/.config/conky/*.conf ~/.config/conky/*.lua ~/.config/autostart/*.desktop 2>/dev/null || true
  sudo apt install -y conky-all lm-sensors   # widgets need Lua + cairo build
  say "System files"
  for f in etc/*; do
    case "$(basename "$f")" in
      99-local.conf)        sudo cp "$f" /etc/sysctl.d/ ;;
      zram-generator.conf)  sudo cp "$f" /etc/systemd/ ;;
      size.conf)            sudo mkdir -p /etc/systemd/journald.conf.d && sudo cp "$f" /etc/systemd/journald.conf.d/ ;;
      *.sources)            sudo cp "$f" /etc/apt/sources.list.d/ ;;
      mozilla)              sudo cp "$f" /etc/apt/preferences.d/ ;;
      zramswap)             sudo apt install -y zram-tools && sudo cp "$f" /etc/default/ && sudo systemctl restart zramswap ;;
      01-local.conf)        sudo mkdir -p /etc/tlp.d && sudo cp "$f" /etc/tlp.d/ && { sudo systemctl enable --now tlp.service; sudo systemctl mask systemd-rfkill.service systemd-rfkill.socket; } ;;
    esac
  done
  sudo sysctl --system >/dev/null
  say "rclone + user services"
  command -v rclone >/dev/null || { sudo apt install -y fuse3; curl -fsSL https://rclone.org/install.sh | sudo bash; }
  mkdir -p ~/.config/systemd/user ~/ProtonDrive
  cp -a config/systemd-user/* ~/.config/systemd/user/ 2>/dev/null || true
  systemctl --user daemon-reload
  if ! rclone listremotes | grep -q '^proton:'; then
    echo ">> recreate the remote: rclone config create proton protondrive username <you> --all"
    echo ">> then: systemctl --user enable --now rclone-proton"
    grep -v rclone-proton systemd-user-enabled.txt | xargs -r systemctl --user enable --now
  else
    xargs -a systemd-user-enabled.txt -r systemctl --user enable --now
  fi
  stage8
  stage9 || true
  apply_look
  say "Stage 5 done → log out/in"
}

case "${1:-}" in
  1) stage1 ;; 2) stage2 ;; 3) stage3 ;; 4) stage4 ;; 5) stage5 ;; 6) stage6 ;; 7) stage7 ;; 8) stage8 ;; 9) stage9 ;;
  *) sed -n 2,14p "$0"; exit 1 ;;
esac
