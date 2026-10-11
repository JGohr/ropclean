# ropclean

Interactive drive cleanup for Windows. Pick a drive, review what's taking up space, and send what you don't need to the Recycle Bin.

> **Disclaimer:** ropclean is not responsible for any data that is lost. Use this tool at your own risk.

## Requirements
- Windows 10 or 11
- Windows PowerShell 5.1 (built in, so there's nothing to install)

## Setup
1. **Download** this repo: click **Code → Download ZIP** and extract it, or run:
   ```
   git clone https://github.com/JGohr/ropclean.git
   ```
2. **Move** the `ropclean` folder somewhere permanent, for example `C:\Tools\ropclean`.
3. **Add it to your PATH.** Open PowerShell and run this, replacing the path with your folder:
   ```powershell
   $dir = "C:\Tools\ropclean"
   [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User').TrimEnd(';') + ";$dir", 'User')
   ```
4. **Open a new terminal** and type:
   ```
   ropclean
   ```

## Usage
1. Accept the disclaimer.
2. Choose a drive.
3. Review the two lists, largest first:
   - **Caches**: app and Windows caches that apps rebuild on their own.
   - **Other items**: games, large personal files and folders. Review these carefully.
4. Pick by number (`1,3,5-7`), type `all`, or press Enter to skip a list.
5. Type `YES` to confirm.

Everything is sent to the **Recycle Bin**, so you can restore anything from there. Space is freed once you empty the bin. If Windows says an item is too big for the bin, choose **No** to keep it.

Items marked `[admin]` need administrator rights. Choose `A` on the drive screen to relaunch ropclean as admin.

## Options
```
ropclean -Drive C      # skip the drive menu
ropclean -ScanOnly     # list only, change nothing
```
