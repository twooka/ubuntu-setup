# Ubuntu 26.04 LTS: set-and-forget setup

Target: Ubuntu 26.04 LTS (Resolute Raccoon), GNOME 50, Wayland only, kernel 7.0, sudo-rs, rust-coreutils.
Laptop, VS Code + TeX, Firefox, Obsidian.

**Why this holds up:** GNOME stays at 50 for the whole LTS (HWE updates the kernel and Mesa, never the shell). Extensions that work on day one keep working until 2031. Everything below is reproducible from one `dconf` dump and a dotfiles repo (§12).

**Upgrade vs. fresh install:** do a fresh install. `do-release-upgrade` from 24.04 works, but it keeps cruft (X11 leftovers, old Evince/Tracker configs, apt sources in the old format). Back up `~` and `/etc` diffs first.

---

## 0. Things you need to know about 26.04

- **No Xorg GNOME session.** X11 apps run under XWayland. Anything that relies on X11 tricks (xdotool, old Conky setups, `xrandr` scripts) is degraded or doesn't work.
- **`sudo` is sudo-rs.** The original is still there as `sudo.ws`.
- **Coreutils are the Rust versions.** You get the GNU ones with a `gnu` prefix (`gnuls`, `gnudate`, …). `cp`, `mv` and `rm` are still GNU. If a script breaks on an obscure flag, that's why.
- **The initramfs is built by dracut**, not initramfs-tools.
- **Defaults:**
  - Terminal: Ptyxis
  - Image viewer: Loupe
  - PDF viewer: Papers
  - System monitor: Resources
  - Video player: Showtime
  - Search indexer: LocalSearch (formerly Tracker)
- **Software & Updates is gone.** Get it back with `software-properties-gtk`.
- **Kdump is on by default on the desktop.** It reserves RAM at boot. §2 removes it.
- **Login apps:** Settings ▸ Apps now has a "start at login" toggle.

---

## 1. Base

```bash
sudo apt update && sudo apt full-upgrade -y
sudo fwupdmgr refresh && sudo fwupdmgr update          # Dell firmware via LVFS
sudo ubuntu-drivers install --recommended              # only matters with NVIDIA/odd Wi-Fi
sudo apt install -y ubuntu-restricted-extras software-properties-gtk \
  gnome-tweaks gnome-shell-extension-manager gnome-shell-extensions \
  flatpak build-essential git curl wget pipx
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
sudo ufw enable                                        # default: deny incoming
```

Keep `unattended-upgrades` on (security only, the default). Disabling it isn't an optimization, it's a liability.

---

## 2. Performance and system tuning

### zram swap (largest real-world gain on a laptop)

```bash
sudo apt install -y systemd-zram-generator
sudo tee /etc/systemd/zram-generator.conf >/dev/null <<'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
EOF
sudo systemctl daemon-reload && sudo systemctl start systemd-zram-setup@zram0
swapon --show     # zram0 should be prio 100; the disk swapfile stays as low-prio fallback
```

### sysctl (tuned for zram, not for disk swap)

```bash
sudo tee /etc/sysctl.d/99-local.conf >/dev/null <<'EOF'
vm.swappiness = 180
vm.page-cluster = 0
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
EOF
sudo sysctl --system
```

### Remove dead weight

```bash
# kdump: reserves crashkernel memory; useless on a personal laptop
sudo apt purge -y kdump-tools linux-crashdump && sudo update-grub

# crash reporting
sudo systemctl disable --now apport.service apport-autoreport.timer 2>/dev/null || true
sudo sed -i 's/^enabled=1/enabled=0/' /etc/default/apport

# boot blocker for no benefit on a desktop
sudo systemctl disable NetworkManager-wait-online.service

# only if you never use them:
sudo systemctl disable --now ModemManager.service          # no WWAN modem
sudo systemctl disable --now cups-browsed.service          # network printer autodiscovery (also a CVE magnet)
# sudo systemctl disable --now bluetooth.service           # if you never use BT

# journal size cap
sudo mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=200M\n' | sudo tee /etc/systemd/journald.conf.d/size.conf
sudo systemctl restart systemd-journald
```

### Power

- **Power daemon:** the script (stage 6) installs **TLP + tlp-pd + tlp-rdw**, replacing power-profiles-daemon. `tlp-pd` implements the same D-Bus API, so GNOME's power-mode menu keeps working. Local overrides live in `/etc/tlp.d/01-local.conf` (charge thresholds 75–80 %). Don't add auto-cpufreq on top.
- Settings ▸ Power ▸ **Battery health preservation**: on. Dell exposes charge thresholds through the `dell-laptop` driver.
- `thermald` is already installed on Intel. Leave it.

### Search indexer (LocalSearch)

Settings ▸ Search ▸ Search Locations: limit indexing to Documents and Projects, or turn it off entirely. Do this in the same panel:

- disable the snap search provider
- disable the web search provider
- disable any other result providers you don't use

### Things deliberately NOT done

| Don't | Why |
|---|---|
| `mitigations=off` | Real security hole for a few % gain |
| `preload` | Pointless on NVMe |
| Swappiness 10 | Wrong advice once swap is zram |
| Purge snapd | Breaks firmware-updater and App Center, and buys you nothing measurable |
| Custom kernels (XanMod etc.) | Breaks the "never touch again" goal; HWE 7.0 is current |
| `noatime` | `relatime` is already the default and enough |

`fstrim.timer` is enabled by default. Check with `systemctl status fstrim.timer`.

---

## 3. Startup / boot management

What runs at login:

- **GUI:** Settings ▸ Apps ▸ (app) ▸ "Run at login" (new in 26.04).
- **Raw:** `~/.config/autostart/*.desktop`. Add `X-GNOME-Autostart-enabled=false` to disable a system entry in `/etc/xdg/autostart/` without deleting it: copy the file into your autostart dir and add that line.
- **Better GUI manager:** Ignition (`flatpak install flathub io.github.flattool.Ignition`). It manages autostart entries, including scripts with delays.
- **Daemons you write yourself:** use `systemd --user` units, not autostart files. You get restart policies, logging and ordering.

```ini
# ~/.config/systemd/user/foo.service
[Unit]
Description=foo
After=graphical-session.target
PartOf=graphical-session.target
[Service]
ExecStart=%h/.local/bin/foo
Restart=on-failure
[Install]
WantedBy=graphical-session.target
```

`systemctl --user enable --now foo.service`; logs: `journalctl --user -u foo -f`.

Boot profiling:

```bash
systemd-analyze                 # total
systemd-analyze blame | head -20
systemd-analyze critical-chain
systemctl list-unit-files --state=enabled
systemctl --user list-unit-files --state=enabled
```

GRUB is hidden by default on single-boot. If you dual-boot, set `GRUB_TIMEOUT=2` in `/etc/default/grub`, then run `sudo update-grub`.

---

## 4. Dark theme, fonts, core GNOME behaviour

```bash
sudo apt install -y fonts-jetbrains-mono fonts-inter qt6ct
flatpak install -y flathub org.gtk.Gtk3theme.adw-gtk3-dark   # dark GTK3 flatpaks

# dark everywhere
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-dark'
gsettings set org.gnome.desktop.interface icon-theme 'Yaru-dark'
gsettings set org.gnome.desktop.interface cursor-theme 'Yaru'
# (Settings ▸ Appearance ▸ Dark sets the above; pick accent colour there)

# fonts
gsettings set org.gnome.desktop.interface font-name 'Inter 11'
gsettings set org.gnome.desktop.interface document-font-name 'Inter 11'
gsettings set org.gnome.desktop.interface monospace-font-name 'JetBrains Mono 11'
gsettings set org.gnome.desktop.interface font-antialiasing 'grayscale'
gsettings set org.gnome.desktop.interface font-hinting 'slight'

# top bar clock / battery
gsettings set org.gnome.desktop.interface clock-show-weekday true
gsettings set org.gnome.desktop.interface clock-show-date true
gsettings set org.gnome.desktop.interface show-battery-percentage true

# behaviour
gsettings set org.gnome.desktop.interface enable-hot-corners false
gsettings set org.gnome.mutter center-new-windows true
gsettings set org.gnome.mutter dynamic-workspaces false
gsettings set org.gnome.desktop.wm.preferences num-workspaces 4
gsettings set org.gnome.desktop.wm.preferences button-layout 'appmenu:close'
gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click true
gsettings set org.gnome.desktop.peripherals.touchpad natural-scroll true
gsettings set org.gnome.desktop.input-sources xkb-options "['caps:ctrl_modifier']"   # or ctrl:nocaps / caps:escape
gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled true

# privacy / noise
gsettings set org.gnome.desktop.privacy remember-recent-files false
gsettings set org.gnome.desktop.privacy remove-old-trash-files true
gsettings set org.gnome.desktop.privacy old-files-age 14
gsettings set org.gnome.desktop.notifications show-in-lock-screen false

# keybindings
gsettings set org.gnome.desktop.wm.keybindings close "['<Super>q','<Alt>F4']"
for i in 1 2 3 4; do
  gsettings set org.gnome.shell.keybindings switch-to-application-$i "[]"
  gsettings set org.gnome.desktop.wm.keybindings switch-to-workspace-$i "['<Super>$i']"
  gsettings set org.gnome.desktop.wm.keybindings move-to-workspace-$i "['<Super><Shift>$i']"
done
```

Qt apps (rare): put `export QT_QPA_PLATFORMTHEME=qt6ct` in `~/.config/environment.d/qt.conf` (as `QT_QPA_PLATFORMTHEME=qt6ct`, no `export`). Then run `qt6ct` once, choose the Fusion style with a dark palette, and it's done.

Animations: keep them on, they're GPU-cheap. If you want snappier, Settings ▸ Accessibility ▸ Reduced Motion, or the animation speed in Just Perfection (§5).

---

## 5. Dock, desktop icons, top bar

### Dock: auto-hide (or remove)

```bash
D=org.gnome.shell.extensions.dash-to-dock
gsettings set $D dock-fixed false
gsettings set $D autohide true
gsettings set $D intellihide false          # hide always, not only when overlapped
gsettings set $D extend-height false
gsettings set $D dock-position 'BOTTOM'
gsettings set $D dash-max-icon-size 36
gsettings set $D show-trash false
gsettings set $D show-mounts false
gsettings set $D click-action 'minimize-or-previews'
```

Purist option: `gnome-extensions disable ubuntu-dock@ubuntu.com`. Super then gives you the overview with the dash. Use Super+1..9 for favourites only if you didn't rebind them in §4.

### Desktop icons: off

```bash
gnome-extensions disable ding@rastersoft.com
```

### Extensions

Install the CLI once: `pipx install gnome-extensions-cli`, then:

```bash
gext install just-perfection-desktop@just-perfection Vitals@CoreCoding.com
```

Before installing, check that each one lists **GNOME 50** on extensions.gnome.org. Both have historically followed releases within weeks.

**Just Perfection** strips the shell down. Set its options with `dconf`, which doesn't need the schema to be installed:

```bash
J=/org/gnome/shell/extensions/just-perfection
dconf write $J/activities-button false
dconf write $J/workspace-popup false
dconf write $J/startup-status 0           # boot to desktop, not overview
dconf write $J/window-demands-attention-focus true
dconf write $J/search true
dconf write $J/world-clock false
dconf write $J/weather false
dconf write $J/events-button false
dconf write $J/panel-size 28
dconf write $J/animation 4                # faster animations; 1 = default, 0 = off
```

Log out and back in after installing extensions (Wayland can't restart the shell in place).

**Top bar system info: Vitals.** Open its prefs, pick CPU %, RAM %, temperature and net down/up, set it to "use higher precision" off and position right. Sensor IDs depend on the machine, so set them in the GUI; §12 captures them. The alternative with zero third-party code is the built-in `system-monitor@gnome-shell-extensions.gcampax.github.com` from the `gnome-shell-extensions` package. It's less configurable but can't break.

Ubuntu's AppIndicator (`ubuntu-appindicators@ubuntu.com`) and Tiling Assistant (`tiling-assistant@ubuntu.com`) are built in. Keep both.

---

## 6. Desktop widget (Conky)

Caveat: GNOME lacks wlr-layer-shell, so Conky has to run as an XWayland window pinned below everything else. It works fine as a passive display. It may show as a thumbnail in the overview. If that bothers you, the alternative is the "Desktop Widgets" extension (`azclock@azclock.gitlab.com`), which does clock and date natively in the shell.

```bash
sudo apt install -y conky-all lm-sensors
ip -br link    # note your Wi-Fi interface name, e.g. wlp0s20f3
mkdir -p ~/.config/conky
```

`~/.config/conky/conky.conf` (replace `IFACE`):

```lua
conky.config = {
  out_to_x = true, out_to_wayland = false,
  own_window = true, own_window_type = 'normal', own_window_class = 'Conky',
  own_window_argb_visual = true, own_window_argb_value = 0, own_window_transparent = false,
  own_window_hints = 'undecorated,below,sticky,skip_taskbar,skip_pager',
  alignment = 'top_right', gap_x = 40, gap_y = 60, minimum_width = 260,
  double_buffer = true, update_interval = 2, no_buffers = true,
  cpu_avg_samples = 2, net_avg_samples = 2,
  use_xft = true, font = 'JetBrains Mono:size=10', draw_shades = false,
  default_color = 'b0b0b0', color1 = 'ffffff', color2 = '7aa2f7',
}
conky.text = [[
${color1}${font JetBrains Mono:bold:size=30}${time %H:%M}${font}${color}
${time %A %d %B %Y}
${color2}${hr}${color}
CPU  ${alignr}${cpu cpu0}%  ${acpitemp}°C
${cpubar 4}
RAM  ${alignr}$mem / $memmax
${membar 4}
SWAP ${alignr}$swap / $swapmax
/    ${alignr}${fs_used /} / ${fs_size /}
${fs_bar 4 /}
BAT  ${alignr}${battery_percent BAT0}%  ${battery_time BAT0}
NET  ${alignr}↓ ${downspeedf IFACE} KiB/s  ↑ ${upspeedf IFACE} KiB/s
${color2}${hr}${color}
${top name 1}${alignr}${top cpu 1}%
${top name 2}${alignr}${top cpu 2}%
${top name 3}${alignr}${top cpu 3}%
UP   ${alignr}$uptime_short
]]
```

Autostart:

```bash
cat > ~/.config/autostart/conky.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Conky
Exec=sh -c "sleep 4 && conky -d -c %h/.config/conky/conky.conf"
X-GNOME-Autostart-enabled=true
EOF
sed -i "s|%h|$HOME|" ~/.config/autostart/conky.desktop
```

---

## 7. Terminal: Ghostty + zsh + modern CLI

Ghostty is in the 26.04 `universe` repo (1.3.0): GPU-rendered, native GTK4/libadwaita, the best Linux terminal today. Kitty and WezTerm are the fallbacks.

```bash
sudo apt install -y ghostty zsh zsh-autosuggestions zsh-syntax-highlighting starship \
  fzf zoxide eza bat ripgrep fd-find git-delta btop fastfetch tealdeer jq \
  htop ncdu duf tree unzip p7zip-full
chsh -s /usr/bin/zsh
sudo snap install yazi --classic        # TUI file manager (§8)
tldr --update
```

Make Ghostty the default terminal:

```bash
sudo update-alternatives --set x-terminal-emulator /usr/bin/ghostty 2>/dev/null || true
mkdir -p ~/.config && echo 'com.mitchellh.ghostty.desktop' > ~/.config/xdg-terminals.list
# Super+Return → Ghostty
KB=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/
gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['$KB']"
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KB name 'Terminal'
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KB command 'ghostty'
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KB binding '<Super>Return'
```

`~/.config/ghostty/config` (theme names: `ghostty +list-themes`):

```ini
theme = Catppuccin Mocha
font-family = JetBrains Mono
font-size = 11
window-padding-x = 10
window-padding-y = 6
window-decoration = none          # use Super+drag / tiling to move; remove if you want a titlebar
gtk-single-instance = true        # near-instant new windows
confirm-close-surface = false
copy-on-select = clipboard
mouse-hide-while-typing = true
shell-integration = zsh
cursor-style = block
cursor-style-blink = false
```

`~/.zshrc`:

```zsh
HISTFILE=~/.zsh_history; HISTSIZE=200000; SAVEHIST=200000
setopt share_history inc_append_history hist_ignore_all_dups hist_reduce_blanks \
       autocd extended_glob interactive_comments no_beep
bindkey -e
autoload -Uz compinit && compinit -C
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'

export EDITOR=nvim VISUAL=code PAGER=less MANPAGER="sh -c 'col -bx | batcat -l man -p'"

alias ls='eza --group-directories-first'
alias ll='eza -lah --git --group-directories-first'
alias lt='eza --tree --level=2'
alias cat='batcat --paging=never'
alias fd='fdfind'
alias top='btop'
alias y='yazi'

eval "$(starship init zsh)"
eval "$(zoxide init zsh --cmd cd)"
source <(fzf --zsh)
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh   # must be last
```

Change `EDITOR=nvim` to whatever you use; if it's nvim, add `neovim` to the apt line.

`~/.gitconfig` additions:

```ini
[core]      pager = delta
[interactive] diffFilter = delta --color-only
[delta]     navigate = true
            side-by-side = true
[merge]     conflictstyle = zdiff3
[init]      defaultBranch = main
[pull]      rebase = true
```

Starship: the defaults are fine. For minimal, run `starship preset plain-text-symbols -o ~/.config/starship.toml`, or write a 5-line config with just `directory`, `git_branch`, `git_status` and `cmd_duration`.

Ptyxis stays installed (removing it removes the `ubuntu-desktop` metapackage). It's harmless.

---

## 8. File management

- **GUI: keep Nautilus (Files).** It's the only file manager that integrates properly with GNOME 50 portals, the GTK4 file chooser, network mounts and LocalSearch. Nemo, Dolphin and the rest give you dual pane in exchange for broken integration. Not worth it.
- **Power use: yazi** (Rust TUI, async, image previews in Ghostty via the Kitty graphics protocol). Bound to `y`.

Nautilus tweaks:

```bash
N=org.gnome.nautilus.preferences
gsettings set $N default-folder-viewer 'list-view'
gsettings set $N show-create-link true
gsettings set $N show-delete-permanently true
gsettings set $N recursive-search 'local-only'
gsettings set $N show-image-thumbnails 'local-only'
gsettings set org.gnome.nautilus.list-view use-tree-view true
gsettings set org.gnome.nautilus.list-view default-zoom-level 'small'
gsettings set org.gtk.gtk4.Settings.FileChooser show-hidden false   # Ctrl+H toggles
gsettings set org.gtk.gtk4.Settings.FileChooser sort-directories-first true
```

Useful keys: Ctrl+L path bar, F2 rename (select several for batch rename), Ctrl+Shift+N new folder, F9 sidebar, Ctrl+H hidden files.

Add `sshfs` for remote mounts (`sudo apt install sshfs`). Nautilus also handles `sftp://host` natively in the path bar, which covers DigitalOcean boxes.

---

## 9. Applications

### Firefox as a .deb (Mozilla's repo; faster startup than the snap, native messaging works)

```bash
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
sudo snap remove --purge firefox
sudo apt update && sudo apt install -y firefox
```

Export your profile or sign into Sync first. `about:config`: `widget.use-xdg-desktop-portal.file-picker = 1` (GTK4 picker), and leave `gfx.webrender.all` alone (already on).

### VS Code (Microsoft repo, auto-updates via apt)

```bash
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /usr/share/keyrings/microsoft.gpg >/dev/null
sudo tee /etc/apt/sources.list.d/vscode.sources >/dev/null <<'EOF'
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/microsoft.gpg
EOF
sudo apt update && sudo apt install -y code
```

Use Settings Sync for extensions. In settings.json, set `"window.titleBarStyle": "custom"` and `"window.menuBarVisibility": "toggle"` for the minimal look under Wayland.

### TeX

Set-and-forget: `sudo apt install -y texlive-full latexmk biber chktex`. The TL version is frozen for the LTS, which is the point.

The alternative, current CTAN packages with `tlmgr update --all`, is the upstream `install-tl` into `/usr/local/texlive/YYYY`. It needs a reinstall every year, which contradicts "never modify".

VS Code: LaTeX Workshop. Set `latex-workshop.view.pdf.viewer: "tab"` (or external Papers) and the latexmk recipe.

### Other

```bash
flatpak install -y flathub md.obsidian.Obsidian com.mattjakeman.ExtensionManager io.github.flattool.Ignition
sudo apt install -y timeshift
```

---

## 10. Snapshots and backup

- **System:** Timeshift. Use rsync mode on ext4 (to a second partition or an external disk), or btrfs mode if root is btrfs. Keep 3 daily and 2 weekly snapshots. Exclude `/home`.
- **Home:** `restic` or Déjà Dup (preinstalled) to an external disk or cloud. Timeshift is not a backup.

---

## 11. Optional hardening (no friction)

```bash
sudo apt install -y apparmor-utils    # AppArmor is already enforcing
# Full-disk encryption: choose it at install time (TPM-backed FDE is offered in the 26.04 installer)
```

Security Center (new in 26.04) controls snap permission prompting. Leave the defaults.

---

## 12. Freeze it (this is what makes it "never modify")

After everything is configured, including the Vitals sensors, Just Perfection and keybindings:

```bash
mkdir -p ~/dotfiles && cd ~/dotfiles && git init
dconf dump / > gnome.dconf                           # ALL GNOME + extension settings
gnome-extensions list --enabled > extensions.txt
cp -r ~/.zshrc ~/.gitconfig ~/.config/{ghostty,conky,starship.toml,autostart} . 2>/dev/null
mkdir -p etc && cp /etc/sysctl.d/99-local.conf /etc/systemd/zram-generator.conf /etc/apt/sources.list.d/{mozilla,vscode}.sources /etc/apt/preferences.d/mozilla etc/
apt-mark showmanual > apt-manual.txt
flatpak list --app --columns=application > flatpak.txt
git add -A && git commit -m "baseline 26.04"
```

Restore on a fresh 26.04:

```bash
xargs -a apt-manual.txt sudo apt install -y
xargs -a flatpak.txt flatpak install -y flathub
xargs -a extensions.txt -n1 gext install
dconf load / < gnome.dconf
# copy dotfiles back (or GNU stow), log out/in
```

---

## 13. Verification checklist

```bash
swapon --show                         # zram0 prio 100
cat /proc/cmdline | grep -c crashkernel   # 0 after kdump purge + reboot
systemd-analyze                        # should be well under 10 s to graphical target on NVMe
powerprofilesctl                       # balanced, driver intel_pstate/amd_pstate
gsettings get org.gnome.desktop.interface color-scheme   # 'prefer-dark'
gnome-extensions list --enabled
echo $SHELL; ghostty +version
apt policy firefox | head -5           # packages.mozilla.org, priority 1000
sudo ufw status
```

Visual check:

- the dock hides itself
- the desktop has no icons
- the top bar shows only workspaces, clock, Vitals and the system menu
- Conky sits top right, below windows
- Super+Return opens Ghostty
- Super+Q closes the window

---

## 14. Later additions (all automated in `ubuntu-setup.sh`)

| Stage | What |
|---|---|
| 6 | Proton VPN: official repo, CLI sign-in, **Switzerland** default, advanced kill switch, VPN accelerator, `protonvpn-connect` user service, `vpn` / `vpnoff` / `vpnip` aliases. TLP + tlp-pd + tlp-rdw with 75–80 % charge thresholds (`/etc/tlp.d/01-local.conf`). |
| 7 | Look: GDM login screen (`/etc/dconf/db/gdm.d/01-local` → black background, dark, green accent), `>_` avatar (`assets/avatar.png`), Plymouth **prompt** boot splash (`assets/plymouth-prompt/`: types `booting` / `rebooting` / `shutting down`, blinking cursor). |
| 8 | Dev toolchain: **uv** (Python versions/venvs/deps; `uv tool` for ruff, pre-commit, jupyterlab, gext), **mise** global `~/.config/mise/config.toml` (node LTS, pnpm, go, bun, doctl, gh, vercel; reads `.nvmrc`), **elan** (Lean 4), **pixi** (+ optional SageMath), **Podman**. `mise activate` in zsh, `~/.config/environment.d/50-dev-path.conf` for GUI apps. Per project: `mise use node@22`, `uv init && uv add …`. |
| 9 | VS Code profiles from `~/dotfiles/vscode/` (`<profile>.extensions.txt` + `<profile>.settings.json`): **LaTeX** (LaTeX Workshop live build/PDF/SyncTeX/math preview, latexindent, LTeX+, Claude, Copilot), **Coding** (Claude + Copilot, Prettier/ESLint/Ruff/Intelephense/Laravel, C++, Dart, containers on Podman, Dev Containers, Remote-SSH), **ML Code** (Ruff, Pylance tuned for torch/sklearn/transformers, Jupyter + interactive `# %%`, Data Wrangler, TensorBoard, Colab), **Lean** (lean4 InfoView/Unicode input, Mathlib style, `.lake` excluded). Extra extensions are removed; stage 4 copies live settings back. |

Also in the snapshot: both Conky widgets (`conky.conf` stats + `hud.conf`/`orrery2.lua` solar system, Cairo, 5 fps on AC / 1 fps on battery) and their autostart entries; Ghostty config; fastfetch welcome card (`~/.config/fastfetch/welcome.jsonc`); systemd user units and drop-ins (rclone Proton Drive mount + wait-for-network); Nautilus bookmarks.

**Fresh install order:** 1 → reboot → 2 → log out/in → 3 → log out/in → `git clone <dotfiles> ~/dotfiles` → 5 (also runs 7, 8, 9) → 6 → reboot.
**After any change:** `~/dotfiles/ubuntu-setup.sh 4`, then push the repo.

Known caveats: rclone's Proton Drive backend is unofficial (re-login: clear `client_*` tokens; Proton rate-limits auth for ~1 h after repeated failures). Goodix `27c6:538d` fingerprint reader has no supported driver.
