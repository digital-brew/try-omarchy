# Rebuilding this Omarchy machine

This folder holds everything needed to recreate the customised Try Omarchy
VM ("try-omarchy", aarch64 Arch Linux ARM, Omarchy 4 Quattro) on a fresh
guest image, plus a record of how the machine was built up in the first
place.

```
/mnt/mac/omarchy-rebuild/
├── README.md              this file
├── bin/
│   ├── try-omarchy            the one command; with no flag it lists the flags below
│   └── try-omarchy.d/
│       ├── backup             try-omarchy --backup: capture the current VM (run inside the VM)
│       ├── restore            try-omarchy --restore: recreate it in a fresh VM (run inside the new VM)
│       └── repack             try-omarchy --repack: rebuild a .pkg.tar.zst from an installed package (used by --backup)
└── snapshot/              output of the last try-omarchy --backup run
```

`bin/try-omarchy` is symlinked into `~/.local/bin`, so it is on `PATH` in the
VM. Each `--FLAG` runs the script of the same name in `try-omarchy.d/` with the
remaining arguments; `try-omarchy` alone (or `--help`) lists the flags with the
`# omarchy:summary=` line of each script, so a new script in `try-omarchy.d/`
is a new flag. `try-omarchy --backup --help` and so on show each command's
options. Until 2026-09-28 these were three separate commands,
`try-omarchy-snapshot`, `try-omarchy-rebuild` and `try-omarchy-repack`. Do not
confuse `--backup`/`--restore` with Try Omarchy's stock `try-omarchy-backup` /
`try-omarchy-restore` in `/usr/local/bin`, which this kit does not use. The
scripts sit on the Mac share (`/mnt/mac`, `~/linux-share`) so they
outlive any VM.

## 1. The commands

### try-omarchy --backup

```
try-omarchy --backup [--no-home] [--no-aur-files] [DESTINATION_DIR]
```

Writes a self-contained snapshot directory (default
`/mnt/mac/omarchy-rebuild/snapshot`):

| File / folder | What it holds |
|---|---|
| `manifest.json` | timestamp, host, runtime versions, theme, font, lists of plugins, themes, web apps, packages, plus linked plugins/icons, bar widgets, mailto handler, agents state and `~/Projects/Linux` git checkouts |
| `inventory.md` | the same as a readable summary |
| `packages-repo.txt` | explicitly installed repo packages that the factory image did not ship |
| `packages-aur.txt` | foreign packages (AUR or built by hand) |
| `aur-sources.txt` | how each foreign package is restored: `file:` (prebuilt), `aur`, or `github:` |
| `aur-packages/` | one prebuilt `.pkg.tar.*` per foreign package: kept from the previous snapshot while the installed version matches, else found in yay's cache, `~/Projects/Linux` or `/mnt/mac/Work`, else rebuilt from the installed files by `try-omarchy --repack` |
| `pkgbuilds/` | PKGBUILD trees from `~/Projects/Linux` for the packages built by hand |
| `flatpaks.txt`, `flatpak-remotes.txt` | Flathub apps and remotes |
| `flatpak-overrides/` | per-app overrides, including the fontconfig crash fix |
| `system/` | enabled services, unowned udev rules, unowned `/usr/local/bin` files, groups, login shell, default browser, `mailto-handler.txt` |
| `home.tar.zst` | `$HOME` minus caches, package stores and rebuildable trees |
| `lerd-databases/` | SQL dump per registered Lerd site, when Lerd is set up |

Excluded from the home archive on purpose, because the rebuild recreates
them: `~/.cache`, `~/.npm`, `~/.local/share/{flatpak,mise,fnm,containers}`,
`~/.local/share/qmk-venv`, `~/qmk_firmware`, `~/.local/share/nvim/lazy`,
browser and Electron caches, `node_modules`, and build artefacts under
`~/Projects/Linux/*`.

The stock `try-omarchy-backup` is not used. Its archive keeps the flatpak
and mise stores, `qmk_firmware` and browser caches, which makes it several
gigabytes larger for no gain. Note that `/mnt/mac/try-omarchy-backup` and
`/mnt/mac/try-omarchy-restore` are old copies of the stock scripts, not
backup folders, so the stock tool's default destination collides with them.

### try-omarchy --repack

```
try-omarchy --repack [-o OUTDIR] PACKAGE...
```

Rebuilds a `.pkg.tar.zst` for an installed package from the files on disk
and pacman's local database (`/var/lib/pacman/local/<name>-<version>/`):
`.PKGINFO` is generated from `desc` and `files`, `.MTREE` and `.INSTALL` are
copied as they are, and the package's paths are archived from `/` with
`bsdtar`. It replaces `bacman`, which pacman-contrib no longer ships. Run
`pacman -Qkk PACKAGE` first if it matters that nothing changed after the
install (all twelve foreign packages reported 0 altered files on
2026-09-16). The snapshot calls it automatically for any foreign package
without a built file, so a rebuilt VM, whose yay cache is empty, still
produces a self-contained snapshot. Before this existed, the snapshot wiped
`aur-packages/` and refilled it from yay's cache only; the first snapshot in
the rebuilt VM therefore deleted ten prebuilt files, which were regenerated
with this script (three originals were still in `/mnt/mac/Work`).

### try-omarchy --restore

```
try-omarchy --restore [--only STEP,..] [--skip STEP,..] [--yes] [SOURCE_DIR]
```

Runs these steps in order. Failures are collected and printed at the end
instead of aborting, so a rerun with `--only <step>` picks up where it
stopped.

1. `packages`: repo packages through `omarchy-pkg-add`, which knows the
   aarch64 repositories.
2. `aur`: foreign packages. Prebuilt files are installed with `pacman -U`
   in one transaction. ZenNotes is downloaded from its GitHub release as
   the aarch64 `.pacman` and installed with `--assume-installed
   http-parser` (a stale dependency Arch no longer ships). Anything without
   a file goes through `omarchy-pkg-aur-add`. The 1Password desktop app
   comes from `omarchy install service 1password`.
3. `flatpaks`: user-installation Flathub apps, then the overrides are
   copied back.
4. `home`: unpacks `home.tar.zst` over `$HOME` (asks first unless
   `--yes`) and recreates the `~/linux-share` symlink.
5. `system`: enables `pcscd.socket` and `tailscaled.service` if they were
   enabled, installs unowned udev rules (`50-qmk.rules`) and any
   `/usr/local/bin` file from the snapshot that the fresh VM lacks (the
   hand-made `ghostty` and `1password` wrappers; Try Omarchy's own scripts
   already exist there and are skipped), restores group membership, login
   shell and default browser.
6. `tools`: `mise install` for the toolchains in `~/.config/mise/config.toml`,
   recreates the QMK CLI venv and runs `qmk setup`, refreshes the font cache,
   runs `omarchy-refresh-applications`.
7. `launchers`: deletes the stock web app launchers that should not be in
   the menu (Basecamp, Google Contacts, Google Maps, Google Messages, Google
   Photos, HEY, YouTube; list `REMOVE_LAUNCHERS` in the script) and hides
   the Chromium PWA copy of the Lerd dashboard (`HIDE_LAUNCHERS`), which
   otherwise appears as a second "Lerd" next to the Lerd package's own
   launcher. The same lists are written to
   `~/.config/omarchy/hooks/post-update.d/prune-launchers.hook`, because
   `omarchy-refresh-applications` (run by `omarchy update`, by migrations
   and by the `tools` step) copies every stock launcher back into
   `~/.local/share/applications`. Edit the lists in the script, then rerun
   `try-omarchy --restore --only launchers`.
8. `theme`: applies the snapshot's theme, reloads Hyprland, restarts the
   shell. The font is only set when `omarchy font current` differs from
   the snapshot, and foot's `font=` line is preserved across it:
   `omarchy font set` rewrites that line as `<name>:size=9`, which is what
   made foot's text tiny after the first rebuild while Ghostty (whose size
   the tool leaves alone) was fine.
9. `verify`: checks that the restored pieces line up. It validates every
   symlinked plugin and every user plugin dir with a manifest, checks that
   every bar widget id in `shell.json` has a plugin dir, enables
   `maillander` if it is not already enabled, compares the `mailto` default
   with the snapshot's `system/mailto-handler.txt` (and re-registers
   `maillander.desktop` with `register-mailto.sh --claim-default` when it is
   the handler), looks for dangling icon-theme symlinks under
   `~/.local/share/icons/hicolor`, checks that the two agents collectors are
   executable and compile, that `~/.local/share/opencode/auth.json` and
   `~/.local/state/omarchy/agents/opencode-console.json` exist and that
   `secret-tool` finds a `maillander` keyring entry, and finally rescans the
   plugins and restarts the shell. Everything it cannot fix is a note, not a
   failure.
10. `lerd`: imports the site databases once `lerd install` has been run.
11. `todo`: prints the manual checklist (section 4).

## 2. Rebuild procedure

1. Create the new Try Omarchy VM from the Mac app and enable the shared
   Mac folder in its start menu, so `/mnt/mac` is mounted.
2. In the new VM:

   ```
   /mnt/mac/omarchy-rebuild/bin/try-omarchy --restore
   ```

   Expect several sudo prompts and one polkit dialog (browser colour
   policy during the theme step). Package downloads and `qmk setup` take
   the longest.
3. Log out and back in.
4. Work through the manual checklist in section 4.
5. Take a fresh snapshot whenever something new is installed:

   ```
   try-omarchy --backup
   ```

## 3. What was added on top of the factory image

This is the record of how the machine got to its current state. The
snapshot captures all of it; this list explains why each item is there.

### Applications (repo packages)

Browsers and comms: `firefox`, `vivaldi`, `signal-desktop`,
`telegram-desktop` (Thunderbird was removed on 2026-09-22; MailLander is the mail client). Editors and dev: `visual-studio-code-bin`,
`sublime-text-4`, `lazygit`, `gdb`, `ruby`, `tree-sitter-cli`, `luacheck`,
`rpm-tools`. Terminals: `ghostty` plus its shell integration and terminfo.
Media and images: `vlc`, `curtail` (ImageOptim replacement, with `oxipng`,
`pngquant`, `jpegoptim`). System: `flatpak`, `tailscale`, `yubikey-manager`,
`1password-cli`, `atuin`, `zsh` with autosuggestions and syntax
highlighting, `ttf-ubuntu-font-family`, `yaru-icon-theme`, `showmethekey`
(KeyCastr replacement), `dos2unix`, `which`.

QMK toolchain: `avr-gcc`, `avr-libc`, `avrdude`, `dfu-programmer`,
`dfu-util`. The ARM side is `gcc-arm-none-eabi-bin` from the AUR. There is
no `qmk` package on Arch Linux ARM, so the CLI lives in a Python venv at
`~/.local/share/qmk-venv` with `~/.local/bin/qmk` linked to it, and the
firmware checkout is `~/qmk_firmware`. The udev rules come from
`~/qmk_firmware/util/install_udev.sh`.

### Foreign packages

From the AUR via yay, cached as built files: `brave-bin`, `brave-beta-bin`,
`google-chrome`, `zen-browser-bin`, `freetube-bin`, `gcc-arm-none-eabi-bin`,
`otf-san-francisco-mono`, `1password-cli`. `figma-linux-bin` was installed
for a while and removed on 2026-09-14 in favour of the Figma web app (see
"Web apps" below).

Built by hand from PKGBUILDs kept in `~/Projects/Linux`: `tableplus`,
`slack-desktop-arm64`, `spatie-ray-bin`, `linksaurus` (the default browser,
a link router).

Not from the AUR: `ZenNotes` (the AUR package is x86-64 only; the upstream
GitHub release ships an aarch64 `.pacman`), and the 1Password desktop app
(tarball into `/opt/1Password`, installed by Omarchy's service installer).

### Flatpaks (user installation, Flathub)

RustDesk, FileZilla, Postman (Betterbird was removed on 2026-09-22). Postman crashes at launch
on this host and was left as is. RustDesk and FileZilla run on
the 25.08 runtime, which crashes in fontconfig on this machine; each has a
`FONTCONFIG_FILE` override pointing at a fonts.conf under
`~/.var/app/<id>/config/fontconfig/`. The overrides are in the snapshot,
the fonts.conf files are in the home archive.

### Web apps (Omarchy launchers, Chromium app mode)

Discord, WhatsApp, Spotify, Trello, Tailscale admin, X, Figma. Each is a
`.desktop` file in `~/.local/share/applications` with an icon in
`~/.local/share/icons/hicolor`, both in the home archive.

Figma replaced the `figma-linux-bin` desktop client on 2026-09-14. The web
app needs WebGL, and this VM's virtual GPU only offers GLES 2.0, so
`~/.config/chromium-flags.conf` and `~/.config/brave-flags.conf` carry
`--enable-unsafe-swiftshader` next to the existing `--disable-gpu` to allow
Chromium's bundled software renderer. The Super+Ctrl+F12 binding, the
workspace 6 window rule (matched on the `figma.com` title) and the bar
glyphs in the `moonlander.*` plugins were retargeted from the `figma-linux`
class to the web app. All of it is in the home archive.

### VirGL workarounds and per-app fixes (2026-09-14)

The VM's VirGL GPU exposes only OpenGL 2.1 compat / GLES 3.0, and Chromium's
GPU process cannot create a context on it at all. Hence:

- **Ghostty**: `/usr/local/bin/ghostty` wrapper exports
  `LIBGL_ALWAYS_SOFTWARE=1` and execs `/usr/bin/ghostty` (in `system/usr-local-bin/`).
  The stock desktop entry hardcodes `/usr/bin/ghostty`, so
  `~/.local/share/applications/com.mitchellh.ghostty.desktop` (Exec via
  PATH, `DBusActivatable=false`) and
  `~/.local/share/dbus-1/services/com.mitchellh.ghostty.service` route
  launcher and D-Bus starts through the wrapper. Kitty and Alacritty are
  not installed. `mesa-utils` was added for `glxinfo`.
- **Vivaldi**: `~/.config/vivaldi-stable.conf` no longer carries
  `--ozone-platform=wayland`; the Try Omarchy-patched launcher
  `/opt/vivaldi/vivaldi` injects `--ozone-platform=wayland --disable-gpu`
  itself on this VM (`OMARCHY_BROWSER_KEEP_GPU=1` opts out, but the GPU
  process then crashes).
- **Chromium web apps** (`~/.config/chromium-flags.conf`): two documented
  modes. Mode A, `--disable-gpu --enable-unsafe-swiftshader`: smooth video,
  but WebGL contexts requested with `failIfMajorPerformanceCaveat`
  (TensorFlow.js, i.e. Zoom blur / virtual background) are refused. Mode B,
  currently active: `--use-gl=angle --use-angle=swiftshader
  --ignore-gpu-blocklist --disable-gpu-compositing
  --enable-unsafe-swiftshader` plus the `zoom-webgl-spoof` extension;
  Zoom blur and backgrounds work but all Zoom video runs on the CPU and
  lags. Switching instructions are in the file's comment block.
- **`~/.local/share/zoom-webgl-spoof/`**: unpacked MV3 extension, content
  script in the main world for `https://*.zoom.us/*` only, that makes
  `WEBGL_debug_renderer_info` report an NVIDIA renderer instead of
  SwiftShader (Zoom hides backgrounds when it sees SwiftShader). Loaded via
  the `--load-extension` line in the Chromium flags file.
- **Signal**: video calls need Signal's own media permissions, which this
  build has no UI toggle for. `~/.config/Signal/config.json` carries
  `"mediaPermissions": true, "mediaCameraPermissions": true` (set with
  Signal closed). Note `~/.config/Signal` is in the home archive, so the
  linked device state comes back too; a relink may still be required.
- **TablePlus**: added to the workspace 2 window rule in
  `~/.config/hypr/hyprland.lua` (class `TablePlus`).

### Shell plugins (`~/.config/omarchy/plugins`)

- `moonlander.workspaces`: workspace pills with per-app glyphs from
  sketchybar-app-font, focused app in the accent colour, six workspaces.
- `moonlander.active-window`: app glyph plus a curated app name.
- `moonlander.group-strip`: vertical icon strip for the focused Hyprland
  group (a sketchybar port).
- `moonlander.force-quit` (2026-09-16): macOS-style Force Quit. Bar icon
  next to the tray, or Ctrl+Alt+Backspace (`bindings.lua`, calls
  `omarchy-shell moonlander.force-quit toggle`). Lists every app with a
  Hyprland window grouped by process (Chromium web apps share one process
  and show as one row), flags "Not responding" when Hyprland's own ANR
  manager has its dialog up for one of the app's windows, plus stopped,
  zombie, stuck-in-kernel or gone processes. Quit asks Hyprland to close
  the windows; Force Quit sends SIGKILL after a confirm. Keys: j/k, Enter or
  x force quit, q quit, r refresh, Esc close. Data comes from
  `~/.local/bin/omarchy-force-quit-list` (python, no dependencies; CPU
  percent between runs is kept in `$XDG_RUNTIME_DIR`). `AppNames.js` and
  `AppFontIcons.js` are copies of the active-window plugin's files, because
  the plugin validator rejects symlinks.
- `moonlander.agents`: two-column Claude Code usage panel (DB and MM
  accounts) with API-equivalent dollar figures. It reads the records written
  by `~/.local/bin/claude-usage-accounts` and `~/.local/bin/opencode-usage`
  into `~/.local/state/omarchy/agents/accounts/`; `opencode-usage` also needs
  `~/.local/share/opencode/auth.json` and, for the Zen credit, the
  device-flow token in
  `~/.local/state/omarchy/agents/opencode-console.json` (`opencode-usage
  --login` once it has expired). Optional config:
  `~/.config/omarchy/agents/opencode.json`.
- `maillander` (replaced `omamail` on 2026-09-21): MailLander as a bar
  widget. The plugin dir is a symlink to the git checkout
  `~/Projects/Linux/maillander` (branch `profiles`, a fork of omamail); the
  old install is parked at
  `~/.config/omarchy/plugin-backups/omamail.bak.*`. On top of omamail it
  adds profiles (named account lists switched from the keyboard, with a
  tint), a rail that folds each mailbox into per-account rows, avatar cards
  with sender favicons and previews on IMAP rows, message bodies on a white
  sheet, and its own icon. Data: accounts, profiles and window
  state in `~/.config/maillander/{accounts,profiles,window}.json`, mailbox
  passwords in the GNOME keyring service `maillander` (under
  `~/.local/share/keyrings`, unlocking with the login password), and a
  regenerable cache at `~/.cache/maillander` (excluded from the archive).
  Desktop entry `~/.local/share/applications/maillander.desktop` with
  absolute paths into the plugin dir; the default `mailto:` handler is
  `x-scheme-handler/mailto=maillander.desktop` in
  `~/.config/mimeapps.list`.

The group-strip, active-window and force-quit plugins map the `maillander`
window title to the icon-theme links under
`~/.local/share/icons/hicolor` (`scalable/apps/maillander.svg` and
`256x256/apps/maillander-symbolic.png`, both symlinks into the plugin dir).

The stock `omarchy.agents` and `omarchy.workspaces` are disabled in favour
of the clones. Plugin edits need `omarchy restart shell`; the shell does not
hot-reload plugin code.

### Themes, fonts, look

- Fifteen user themes under `~/.config/omarchy/themes`, ported from the
  macOS dotfiles with `~/.local/bin/port-dotfiles-theme` (colors.toml,
  icons.theme, neovim.lua) and five Wallhaven wallpapers each. Ayu Dark is
  current.
- Theme bridge to the macOS theme dir (added 2026-09-16): `~/.config/theme`
  is a Linux port of the Mac's `~/.config/theme`, with `bin/theme-switch` and
  the per-theme `tmux/*.conf` palettes copied from the dotfiles.
  `~/.config/omarchy/hooks/theme-set.d/theme-switch` runs on every
  `omarchy theme set`, maps the Omarchy name to the nvim slug (`catppuccin`
  to `catppuccin-mocha`, `matte-black` to `matteblack`, `white` is skipped;
  the user themes already use the nvim slugs) and calls `theme-switch`. That
  writes `~/.config/theme/current` (read by nvim's `lua/core/theme.lua`),
  flips `~/.config/theme/tmux/current.conf`, sets the starship palette and
  live-reloads tmux and every running nvim. Before this, nvim never followed
  the OS theme. nvim's own theme picker calls `omarchy-theme-set` when the
  theme exists in Omarchy, so picking inside nvim changes the desktop too.
  The rebuild's `theme` step triggers the hook, so nothing extra is needed
  after a restore.
- `~/.config/omarchy/themed/shell.toml.tpl`: user copy of the shell
  template with two changes, notifications on `dark_background` and the
  menu border on `hyprland.active-border`. Re-copy it after an Omarchy
  update if upstream adds keys.
- `~/.config/omarchy/shell.toml`: font base-size 14, bar 34px, no
  notification border, menu border 2px.
- Fonts in `~/.local/share/fonts`: Dank Mono (system font),
  sketchybar-app-font (bar glyphs).
- Hyprland (`~/.config/hypr/*.lua`): app launch keys on Super+Ctrl+F5 to
  F14, workspace rules per app, floating rules for 1Password and Show Me The
  Key, group settings, no transparency.

### Terminal and shell

zsh with a Linux port of the macOS zshrc: starship, atuin, Omarchy
aliases, `oprun` for secrets, `ccdb`/`ccmm`/`ccswap` for the two Claude
accounts, and `claude` shadowed to remind you to pick one. tmux with
plugins, neovim config, lazygit, btop, kitty/alacritty/ghostty configs that
include the Omarchy theme files.

tmux (`~/.config/tmux/tmux.conf`, plugins under `~/.config/tmux/plugins`,
TPM at `~/.tmux/plugins/tpm`): sources `~/.config/theme/tmux/current.conf`
for the `@thm_*` palette (the Mac line, re-enabled 2026-09-16). tmux-yank's
line-copy key is moved to `prefix Y` (`@yank_line`) because its default
`prefix y` shadowed the fzf "jump to window" popup; `prefix u` is the
"jump to session" popup and lists only sessions you are not attached to.

neovim (`~/.config/nvim`): `lua/core/utils.lua` has `hl()`, a link-following
highlight reader that `lua/core/theme.lua` and `lua/core/autocmds.lua` use
instead of `nvim_get_hl(0, { link = false })`. On Neovim 0.12 the latter
resolves through the focused window's winhighlight, so inside the Snacks
explorer "CursorLine" read back as the explorer row (linked to Visual) and
every WinEnter lightened it further until it was near white. theme.lua also
pins `SnacksPickerListCursorLine` to the CursorLine colour for palettes
without an explicit `cursorline`. Plugins under `~/.local/share/nvim/lazy`
are not in the archive; lazy.nvim reinstalls them from `lazy-lock.json` on
first launch.

### Audio routing (2026-09-16)

The Mac's audio devices reach the VM as PipeWire loopback sinks/sources
named `omarchy_host_output_<hash>` / `omarchy_host_input_<hash>`
(descriptions "Mac System Default", "JBL TUNE760NC", "USB Condenser
Microphone", ...). Default sink: Mac System Default. Default source: USB
Condenser Microphone (set with `wpctl set-default`, persisted by
WirePlumber in `~/.local/state/wireplumber/default-nodes`; the JBL's own
mic is never used). Per-app output (e.g. JBL TUNE760NC for Slack and Zoom)
is chosen inside each app's own audio settings, not pinned system-wide. A
PipeWire `stream.rules` file that hard-routed Slack to the JBL was tried on
2026-09-16 and removed the next day by preference. If ever needed again:
`pipewire-pulse.conf.d` `stream.rules` matching `application.name` +
`media.class = "Stream/Output/Audio"` with `target.object`; WirePlumber's
`stream.rules` cannot route and `pulse.rules` cannot tell playback from
capture.

### Developer tooling

- mise: node, claude, codex, gh, varlock (`~/.config/mise/config.toml`).
- Lerd (Laravel dev environment, factory package) with podman containers;
  site databases are dumped by the snapshot.
- opencode, pi, playwright and other CLIs under `~/.local/bin`.
- 1Password secrets workflow: `~/.config/secrets/.env.schema` (varlock
  pointers into vault "Dotfiles", item "dotfiles"), `secrets-sync` (writes
  `~/.npmrc` via `op inject`), `make-env-tpl`.

### Agents widget collectors

The `moonlander.agents` widget reads per-account JSON records that two
collectors write into `~/.local/state/omarchy/agents/accounts/`:
`~/.local/bin/claude-usage-accounts` (the two Claude Code accounts, from
the restored `~/.claude*` state) and `~/.local/bin/opencode-usage` (opencode
and its Zen credit). `opencode-usage` reads
`~/.local/share/opencode/auth.json` and the device-flow token in
`~/.local/state/omarchy/agents/opencode-console.json`; the token expires, so
`opencode-usage --login` re-runs the flow. Optional widget config lives in
`~/.config/omarchy/agents/opencode.json`. All of it is under `$HOME`, so the
home archive carries it; the rebuild's `verify` step checks the two scripts
compile, that both credential files exist and that the widget's plugin dir
is present.

### Claude Code

Two accounts: `db` is `~/.claude` (with `~/.claude-db` as a symlink to it)
and `mm` is `~/.claude-mm`. Skill `switch-account` in both. Session
transcripts are in the home archive.

### System-level changes

- `pcscd.socket` enabled (YubiKey), `tailscaled.service` enabled.
- `/etc/udev/rules.d/50-qmk.rules`.
- `/usr/local/bin/ghostty` (software-GL wrapper) and `/usr/local/bin/1password`;
  captured in `system/usr-local-bin/`.
- Login shell zsh. Groups: users, video, audio, wheel.
- Browser colour policies under `/etc/opt/{chrome,vivaldi}` are written by
  `omarchy theme set` and need no restoring.
- NativePHP builds (2026-09-23): `~/.local/bin/mac-native`, Mutagen in
  `~/.local/lib/mutagen` and the `mutagen.service` user unit come back with the
  home archive; the Mac keeps its own `~/.mutagen` agent and `~/NativeBuilds`.
- Lerd tray (2026-09-22): upstream ships no `lerd-tray` for Linux arm64, so it
  is built locally (`~/.local/bin/lerd-tray-build`, Go via mise, cgo against
  libayatana-appindicator) into `~/.local/bin/lerd-tray`; the binary, the
  helper and the user unit come back with the home archive, and a lerd
  upgrade needs the helper run again.
- TubeLander (2026-09-22): the YouTube plugin at `~/Projects/Linux/tubelander`
  (home archive) needs a current `yt-dlp`; the rebuild's `system` step runs
  `uv tool install yt-dlp` when `~/.local/bin/yt-dlp` is missing.
- Printing (2026-09-22): `cups.service` enabled; one driverless queue,
  `HP_LaserJet_P2035`, pointing at the Mac host's shared printer
  (`ipp://DBM3RPX.local:631/printers/HP_LaserJet_P2035`, macOS Printer
  Sharing, the Mac renders). The rebuild's `system` step re-creates it with
  `lpadmin -m everywhere`, which needs the Mac awake with sharing on; the
  per-user A4 default (`~/.cups/lpoptions`) comes back with the home archive.

## 4. Manual steps after a rebuild

These need credentials or hardware and cannot be scripted:

1. Log out and back in.
2. 1Password: sign in, then Settings > Developer > "Integrate with 1Password
   CLI" and enable the SSH agent. `op vault list` confirms it.
3. Run `secrets-sync` to regenerate `~/.npmrc`.
4. `ccmm` then `/login` for the MM Claude account. `ccdb` needs nothing.
5. `sudo tailscale up`.
6. Signal relink, and any 2FA prompts in the restored browser profiles.
7. Plug the keyboard in and run `qmk doctor`.
8. Postman, if you want it, still needs a fix for its launch crash.
9. MailLander: the keyring unlocks with your login password. If the
   mailboxes are missing, add them on MailLander's setup page (the IMAP app
   passwords are in 1Password).
10. Agents widget: if opencode's Zen credit is missing, run `opencode-usage
    --login`; the Claude accounts come from `ccdb`/`ccmm` then `/login`
    (item 4).

## 5. Gotchas specific to this machine

- It is aarch64. `qmk`, `flutter`/`fvm`, Vial, and many `-bin` AUR
  packages are x86-64 only. Prefer Flathub or upstream aarch64 releases.
- A stale package database causes `failed retrieving file ... 404`. Run
  `sudo pacman -Syu` before installing.
- Three failed sudo or polkit attempts lock the account for ten minutes
  (pam_faillock). Every attempt during the lock counts as a failure, so
  wait it out rather than retrying.
- `op whoami` reports "not signed in" under the app integration even when
  `op vault list` works. Use the latter as the check.
- `omarchy plugin clone` replaces the source widget's bar entry; re-add the
  original in `~/.config/omarchy/shell.json` if both should show.
- Removed stock web apps come back after `omarchy update`: it runs
  `omarchy-refresh-applications`, which recopies everything in
  `~/.local/share/omarchy/applications`. The `launchers` step and its
  post-update hook exist for that reason.
- `omarchy font set <name>` rewrites `~/.config/foot/foot.ini` to
  `font=<name>:size=9` (Ghostty, kitty and alacritty only get the family
  swapped). The correct line is
  `font=Dank Mono:size=16, JetBrainsMono Nerd Font Mono:size=16`.
- Chromium regenerates the `.desktop` files of its installed PWAs
  (`chrome-<id>-Default.desktop`) after a Chromium upgrade, so a hand-added
  `NoDisplay=true` can be lost until the next `omarchy update` runs the hook.
