# Delete Agent Sessions

CLI name: `delses`

A tiny macOS CLI to safely archive, restore, and purge local Codex and Claude Code sessions.

## Commands

`delses codex`  
`delses claude`  
`delses restore`  
`delses purge`

## Controls

`n`, `p`, `/word`, `/clear`, `q`  
`1`, `1 2`, `1,2` selection  
archive/restore confirmation: `yes`  
purge confirmation: `purge`

## Install

```bash
git clone https://github.com/Gall-ardo/Delete-Agent-Sessions.git
cd Delete-Agent-Sessions
scripts/install.sh
```

## Requirements

`macOS 13+`  
`Xcode Command Line Tools / Swift toolchain`  
Apple Silicon and Intel Mac supported via local build

## Data paths

`~/.delses/trash`  
`~/.delses/manifests`  
`~/.delses/logs`

## Safety

`delses` does not permanently delete from Codex/Claude source directories.  
`delses purge` only removes archived copies under `~/.delses/trash`.  
No shell integration, no telemetry, no network, no background daemon.

## Uninstall

```bash
scripts/uninstall.sh
```

Note: uninstall does not remove `~/.delses` archive data.

## Development

```bash
swift test
swift build -c release
```
