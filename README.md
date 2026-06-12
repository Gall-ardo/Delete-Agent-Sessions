# Delete Agent Sessions

`delses`

A tiny macOS CLI to safely archive, restore, and purge local Codex and Claude Code sessions.

## Commands

`delses codex`  
`delses claude`  
`delses restore`  
`delses purge`

## Install

```bash
git clone https://github.com/Gall-ardo/Delete-Agent-Sessions.git
cd Delete-Agent-Sessions
scripts/install.sh
```

## Requirements

`macOS 13+`  
`Xcode Command Line Tools / Swift toolchain`

## macOS compatibility

- macOS 13+ is targeted.
- Apple Silicon M1/M2/M3/M4 is supported.
- Intel Mac is supported if Swift toolchain or Xcode Command Line Tools is installed.
- The install script performs a local build, so the binary is compiled for the user's own architecture.
- Universal release is not included currently; it can be added later if needed.

## Pagination

`n`, `p`, `/word`, `/clear`, `q`

## Multiple selection

`1 2` or `1,2`

## Data paths

`~/.delses/trash`  
`~/.delses/manifests`  
`~/.delses/logs`

## Uninstall

```bash
scripts/uninstall.sh
```

## Safety note

Source Codex and Claude files are not permanently deleted directly. `delses purge` only removes the archived copy inside `~/.delses/trash`.
