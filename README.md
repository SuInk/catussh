# catussh

**English** · [简体中文](./README.zh-Hans.md) · [繁體中文](./README.zh-Hant.md)

A native macOS app for the Linux and macOS servers you look after: an SSH terminal
built on [Ghostty](https://ghostty.org), SFTP file transfer and a live resource
monitor, side by side for every server.

[![License](https://img.shields.io/badge/license-MIT-blue)](./LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![Swift](https://img.shields.io/badge/Swift-6.2-orange)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./Resources/Screenshots/home-dark.jpg">
  <img alt="catussh's Home page: Quick Connect at the top and a grid of saved servers, each with Connect, Files and Monitor buttons." src="./Resources/Screenshots/home-light.jpg">
</picture>

## Install

This fork includes an SSH setup guide for macOS. To try it, build this repository using the steps below. The Homebrew cask installs the upstream release.

```sh
brew install --cask mizorewww/tap/catussh
```

Requires macOS 13 or later. The app is universal, signed and notarized. You can also
download the disk image from [Releases](https://github.com/mizorewww/catussh/releases).

## Features

- **Terminal, Files and Monitor for every server**, one click each, with a toolbar
  switcher between them.
- **A native Ghostty terminal**: GPU rendering, 600+ themes, translucent background.
- **Visual terminal settings**: installed fonts with their real styles, recorded
  keyboard shortcuts, a live color preview.
- **Quick Connect**: type `user@host:port` and press Return.
- **Cloudflare Access**: reach servers behind a Cloudflare Tunnel, as
  `ssh -o ProxyCommand='cloudflared access ssh --hostname %h'` does, without
  installing cloudflared. Service tokens are supported.
- **Server monitor** for Linux and macOS: CPU, memory, disks, network and NVIDIA GPUs,
  using native system tools with no agent to install.
- **Identities** (passwords or keys) shared across servers, **snippets** run on many
  servers at once, **port forwarding**, and a **menu bar** monitor.
- An iPhone and iPad app with the same terminal and settings, built from source.

## Screenshots

### Servers

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./Resources/Screenshots/servers-dark.jpg">
  <img alt="The Servers table grouped into Production, CI and Home Lab, with Files, Monitor and Connect on each row." src="./Resources/Screenshots/servers-light.jpg">
</picture>

### Terminal text settings

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./Resources/Screenshots/text-dark.jpg">
  <img alt="Settings, Text: a font picker, style menus, a size slider with a number field, and stroke thickening." src="./Resources/Screenshots/text-light.jpg">
</picture>

### Colors with live preview

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./Resources/Screenshots/colors-dark.jpg">
  <img alt="Settings, Colors: a live terminal preview above the theme gallery." src="./Resources/Screenshots/colors-light.jpg">
</picture>

### Keyboard shortcuts

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./Resources/Screenshots/keyboard-dark.jpg">
  <img alt="Settings, Keyboard: shortcuts as key caps with plain-language actions, grouped by purpose." src="./Resources/Screenshots/keyboard-light.jpg">
</picture>

## Using catussh

The setup guide shows which config file it reads, normally `~/.ssh/config`. Review the username, address, port, key file and jump host, then choose **Import Selected**. Selecting a target also selects its new jump host. Reopen the guide from **Servers → Import from This Mac…**.

The guide recognizes an explicit `IdentityFile` or a single available default key. It saves the file location on this Mac and uses the key when connecting. For an encrypted file, enter its passphrase for this session in **Identities → Local key file**. Hosts with no key file can use SSH Agent. An agent login from an earlier import can be selected for **Update login**. An existing username-only bookmark can also receive a key when you select the update. Bookmarks with configured credentials keep their login. Jump chains and ambiguous keys are listed for manual setup.

1. **Add a server**: **New Server** on Home (⇧⌘N).
2. **Connect**: click a server's tile. **Files** opens SFTP and **Monitor** opens live
   usage; the toolbar switcher moves between the three.
3. **Quick Connect**: type `user@host`, `user@host:2222` or a full `ssh` command on Home.
4. **Settings** (⌘,) cover the app and the terminal. Ghostty coverage is described in
   [CONFIGURATION.md](Foundation/CatusshTerminal/CONFIGURATION.md).

## Build from source

Needs Xcode 26 or later (Swift 6.2).

```sh
git clone https://github.com/SuInk/catussh.git
cd catussh
bash Workflow/Scripts/install-macos.sh   # Release build, installed to /Applications
```

Or open `App.xcworkspace` and run the **catussh** scheme (macOS) or **mCatussh** (iOS 16+).

## Contributing

Bugs and ideas go to [issues](https://github.com/mizorewww/catussh/issues). Pull
requests are welcome; run the terminal tests first:

```sh
swift test --package-path Foundation/CatusshTerminal
```

## License

[MIT](./LICENSE). Third-party licenses are listed in [Resources/LICENSE](./Resources/LICENSE).
