# WSL Manager

A dark-themed PowerShell/WPF desktop app for managing Windows Subsystem for Linux (WSL 2) instances: create, clone, start, stop, rename and delete them, give them friendly names, and set CPU/memory/swap per instance.

No installation, no admin rights, no external modules: just Windows PowerShell 5.1 and WSL.

---

## Features

| Area | What you can do |
|---|---|
| **Overview** | See all instances with display name, real name, state (live, refreshed every 5 s), OS, WSL version, disk size and resource profile. ★ marks the default instance. |
| **Naming** | Give each instance a friendly **display name** and a **description**, shown as `Display Name (real-name)`. You can also **rename** the real WSL name while the instance is stopped. |
| **OS detection** | Reads `/etc/os-release` and the kernel version. The result is cached, so stopped instances still show their OS. |
| **Create** | **New (online)**: install from the official online catalog (`wsl --list --online`).<br>**Clone**: copy an existing instance; it keeps the same default user and resource profile.<br>**Import VHDX**: register an existing `.vhdx` in place, with an optional default user. |
| **Lifecycle** | Start / Stop / Restart, **Shutdown WSL** (all instances), **Terminal** (opens Windows Terminal, or double-click a row) and **Files** (opens `\\wsl.localhost\<name>` in Explorer). |
| **Resources** | Per-instance CPU / memory / swap profiles (see below), a default profile, and maximum virtual disk size (resize). |
| **Storage** | Choose a default folder where new instances are created (`<folder>\<name>`). |
| **Safety** | Delete asks you to type the instance name. `.wslconfig` is backed up to `.wslconfig.bak` before each change. Metadata is backed up on every save. |

---

## Requirements

- Windows 10 22H2 / Windows 11
- **WSL 2.4 or newer** (`wsl --version`). Earlier versions don't support `--install --name/--location` or `--manage`. Update with `wsl --update`.
- Windows PowerShell 5.1 (built into Windows)
- Optional: Windows Terminal (otherwise a plain console window is used)

---

## Getting started

1. Extract the zip to any folder, e.g. `C:\Tools\WSLManager`.
2. If you downloaded the zip, unblock the files once (PowerShell):
   ```powershell
   Get-ChildItem -Recurse C:\Tools\WSLManager | Unblock-File
   ```
3. Double-click **`Start-WSLManager.cmd`**.

   Or from PowerShell:
   ```powershell
   powershell -STA -ExecutionPolicy Bypass -File .\WSLManager.ps1
   ```
4. On first start you're asked to choose the **default storage location** for new instances. This step is required; declining closes the app. The suggested folder is `D:\WSL`, or `%LOCALAPPDATA%\WSL` if there is no D: drive. Change it later with **🗄 Storage location**.

---

## How resource profiles work

WSL 2 runs **all instances inside one shared virtual machine**. Its CPU, memory and swap limits are set globally in `%USERPROFILE%\.wslconfig`, so they can't be capped per instance at the same time.

WSL Manager solves this with **profile switching**:

1. In the detail panel, enter CPUs / Memory / Swap for an instance (e.g. `4`, `8GB`, `2GB`) and click **💾 Save**.
2. When you **Start** or **Restart** that instance, the app compares its profile with the active `.wslconfig`.
3. If they differ, you're asked to confirm. The confirmation lists any running instances that will be stopped. The app then writes the new values to `.wslconfig` (other settings such as `networkingMode` are preserved), runs `wsl --shutdown`, and starts the instance.
4. The status bar shows the active profile and which instance it was applied for.

Notes:
- Leave **all three fields blank** to have no preference: the instance never triggers a restart and uses whatever is active.
- Fields left blank in a **partial** profile are filled from the **⚙ Default profile**.
- **Terminal** and **Files** don't apply profiles; use **Start** first if the profile matters.
- Swap `0` disables swap.

---

## Tips

- **New (online)** opens a console window for the installation, where you create the Linux user on first start. The instance appears in the list once it is registered.
- **Clone** stops the source instance during export. The copy is written directly to the new folder, so it needs as much free space as the source disk.
- **Rename** changes the name used by `wsl -d <name>`. Update your scripts and Windows Terminal profiles yourself. If WSL still reports the old name, click **Shutdown WSL**.
- **Resize** sets the *maximum* size of the virtual disk; the instance must be stopped.
- To move an existing instance to another folder, run:
  ```powershell
  wsl --shutdown
  wsl --manage <name> --move <new-folder>
  ```
- To use a different storage folder for one session only:
  ```powershell
  .\WSLManager.ps1 -StorageRoot E:\WSL
  ```

---

## Files

| Path | Purpose |
|---|---|
| `Start-WSLManager.cmd` | Double-click launcher (no console window) |
| `WSLManager.ps1` | Main script: window logic, dialogs, actions |
| `WSLManager.xaml` | Main window layout |
| `Theme.xaml` | Dark theme (colors and control styles). Edit the colors at the top to restyle. |
| `lib\Wsl.psm1` | Wrappers around `wsl.exe` and the WSL registry key |
| `lib\Metadata.psm1` | Display names, descriptions, cached OS info, profiles and settings |
| `lib\WslConfig.psm1` | Reads and writes the resource keys in `.wslconfig` |

### Data written by the app

| Location | Content |
|---|---|
| `%APPDATA%\WSLManager\wslmanager.json` (+ `.bak`) | Display names, descriptions, OS cache, profiles, default profile, storage location |
| `%USERPROFILE%\.wslconfig` (+ `.bak`) | `processors`, `memory`, `swap` under `[wsl2]`. Only when a profile is applied. |
| `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss` | Only on **Rename** (`DistributionName`) and **Clone** (`DefaultUid`) |

To remove the app, delete its folder and `%APPDATA%\WSLManager`. Your WSL instances are not affected.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Window doesn't appear | Run `powershell -STA -ExecutionPolicy Bypass -File .\WSLManager.ps1` from a console to see errors. Make sure the files are unblocked. |
| "Invalid command line option" errors | Update WSL: `wsl --update` |
| Instance stops right after Start | Check `wsl -d <name>` in a terminal; the distro may fail to boot. |
| Profile not applied | Profiles apply on **Start/Restart** from the app, not when WSL is started elsewhere. |
