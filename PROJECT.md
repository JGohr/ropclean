# ropclean

Interactive CLI drive cleaner. Run `ropclean` from any terminal.

## Behavior
- Launch screen shows disclaimer: ropclean is not responsible for any data lost; use at own risk.
- User picks a drive, then ropclean scans and lists, largest first:
  - **Caches**: known app/system cache folders (contents only, folders kept). Shown at 10 MB or more.
  - **Other items**: Steam games and workshop mods, Epic games, large items in personal folders (500 MB or more), and non-system drive-root folders (1 GB or more), plus the hibernation file.
- User selects by number, range, or `all`, then must type `YES`.
- Everything is sent to the **Recycle Bin** (never permanently deleted). If an item is too big for the bin, Windows warns before deleting it permanently, and the user can decline.
- `[admin]` items are skipped unless elevated. Option `A` on the drive screen relaunches as admin.
- Hibernation file is the exception: it's handled with `powercfg /h off` (undo with `powercfg /h on`).

## Files
- `ropclean.ps1`: the tool (PowerShell 5.1, no dependencies)
- `ropclean.cmd`: launcher; this folder is on the user PATH

## Flags
- `-Drive C`: skip the drive menu
- `-ScanOnly`: list only, no prompts or changes
