# MacHosts user guide

This guide describes the current development build (version 0.1.0). It covers what the
app does today and states plainly what it does not do yet. Interface names are given in
English; the German interface uses the corresponding translated labels.

> **This build cannot change your system hosts file.** It edits, previews, imports and
> exports profiles and shows the current `/etc/hosts` read-only. Applying changes to the
> system needs macOS authorization and a verified write path, and both are still being
> built (see [Activation](#activation)). The window says so in its status bar:
> "System changes are not available in this build."

## Contents

- [Install and first launch](#install-and-first-launch)
- [Profiles and the editor](#profiles-and-the-editor)
- [Activation](#activation)
- [Preview and conflicts](#preview-and-conflicts)
- [System file status and external changes](#system-file-status-and-external-changes)
- [Remote profiles](#remote-profiles)
- [Import, export and backups](#import-export-and-backups)
- [Menu bar, login start and settings](#menu-bar-login-start-and-settings)
- [TLS and name resolution limits](#tls-and-name-resolution-limits)
- [Data storage, migration and recovery](#data-storage-migration-and-recovery)
- [Complete removal](#complete-removal)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Limits](#limits)

## Install and first launch

MacHosts needs macOS 27 or later on Apple Silicon. It has no Apple Developer ID
signature and is not notarized: it carries an ad-hoc signature only.

1. Copy `MacHosts.app` to `/Applications`.
2. Open it once. macOS blocks the first launch of an app without a Developer ID. Open
   **System Settings → Privacy & Security** and allow MacHosts there, then open it again.
3. MacHosts creates its private workspace (see [Data storage](#data-storage-migration-and-recovery))
   and starts reading `/etc/hosts`. It reads only: there is no administrator prompt and
   no write at launch, and no profile is created or activated automatically.

The hosts file applies to the whole Mac, for every user, and stays in effect after an app
quits. MacHosts treats every change to it as a deliberate, previewed step.

## Profiles and the editor

A profile is a named piece of hosts text, for example:

```
# Staging shop
203.0.113.42 shop.example www.shop.example
```

- **New profile** (⌘N) creates an empty local profile. Name it in the field above the
  editor and choose **Rename**.
- The editor is a native text view with line numbers, syntax colors, undo/redo, and
  **Find in profile…** (⌘F) / **Replace in profile…** (⌥⌘F). Line endings and Unicode text
  are kept exactly.
- Drafts save automatically. **Save drafts** (⌘S) saves immediately. If saving fails, the
  window says so and offers to retry; quitting first tries to save.
- Problems such as invalid addresses or hostnames, duplicates and reserved MacHosts
  markers are listed under the editor. Choose a listed line to jump to it. At most 20
  are listed at once.
- **Entry switches** lists the profile's entries. Filter them by text or state and switch
  matching entries on or off together. A switched-off entry stays in the text with a
  `# machosts-disabled: ` prefix.
- **Search all profiles** (⇧⌘F) finds text across every profile and jumps to the line.
- Folders (**Folders**) organize the sidebar. They do not control activation.
- **Duplicate as local profile**, **Move up/down**, **Move to folder** and
  **Move to trash** are in the **Profiles** menu and the sidebar context menu. **Trash**
  shows deleted profiles read-only and can restore them as inactive profiles.
- **New window** (⇧⌘N) opens another workspace window. Windows share the same drafts;
  selection and undo are per window.

## Activation

The **Desired active** switch on a profile, and **Desired activation (draft)** in the
menu bar, mark which profiles you want in the system file. This is a draft setting:
it does not change `/etc/hosts`.

The planned workflow is: preview the complete change, approve it with macOS system
authorization, and have MacHosts write only its own marked section of `/etc/hosts`, then
read it back before reporting success. In this build the final step is not available,
and MacHosts never claims a profile is applied without a verified write. The menu bar's
**Applied profiles** section therefore shows "None verified" until a future build
completes an apply. Removing all MacHosts entries will use the same previewed and
authorized path. It will remove only the managed section, never other content.

## Preview and conflicts

**Preview changes** (⇧⌘P) builds a frozen, read-only plan from all enabled drafts against
the current contents of `/etc/hosts`:

- mappings that would be added or removed, with the profile each comes from;
- conflicts, for example one hostname mapped to different addresses, with every source;
- parser problems in enabled profiles, linked to their lines;
- the complete current and proposed file text.

Entries outside the MacHosts section are always kept unchanged. The preview is marked
out of date as soon as drafts or the system file change. Choose
**Prepare preview again** to rebuild it.

## System file status and external changes

**System file status** shows `/etc/hosts` read-only, with line numbers, syntax colors and
the MacHosts section highlighted, plus its observation state. MacHosts watches the file
and its folder without polling and notices edits by Terminal, VPN clients or other apps.
If the file cannot be read, is too large, is a link or unusual file, or changed during a
read, the status names the reason. **Check again** rereads it; **Restart observation**
restarts watching, for example after sleep.

## Remote profiles

**New remote profile…** takes a name and an `https://` address and downloads it once:

- HTTPS only, without user name or password in the address. Redirects must stay on
  HTTPS without credentials, with at most three hops. The normal macOS certificate
  checks apply. Downloads are limited to 1 MiB.
- A remote profile is read-only in the editor and has a lock icon. Use
  **Duplicate as local profile** to edit a copy.
- **Refresh remote profiles** (⇧⌘R) downloads again. A failed or invalid download keeps
  the last valid content; the profile shows the error.
- Downloads change only the draft and are never applied automatically.

## Import, export and backups

Open **Import / Export…** from the toolbar or the File menu.

- **`.hosts` text**: import a UTF-8 hosts file as a new inactive profile after reviewing
  its full text and problems; export a profile's full text or only its enabled entries.
- **MacHosts JSON**: export all profiles and folders, or import a MacHosts JSON file
  ([format](JSON-EXCHANGE.md)). Choose which profiles to include. An import appends
  inactive copies with fresh identities. **Replace workspace…** replaces all drafts
  after writing a backup.
- **Restore draft from backup…** lists backups newest first and restores one as a new
  draft revision, after backing up the current draft first.
- Exports never overwrite an existing file.
- SwitchHosts import is not available yet.

Backups are files named `workspace.backup-<UTC time>-<id>.json` in the workspace folder.
MacHosts never deletes them; remove old ones yourself in Finder when no longer needed.

## Menu bar, login start and settings

The menu bar item shows pending draft changes, verified applied profiles, desired
activation switches, **Preview changes…**, **Refresh remote profiles**,
**System file status…**, **Diagnostics…**, **Open MacHosts** and **Quit MacHosts**.
Closing all windows keeps MacHosts in the menu bar. Quitting never changes the system file.

**Settings** (⌘,):

- **Open at login** registers the app as a login item through macOS. If macOS asks for
  approval, **Open Login Items** opens the right page in System Settings.
- **Show in menu bar** hides or shows the menu bar item.
- **Refresh when MacHosts starts** and **Refresh while running** (never, hourly, every
  6 or 24 hours) control remote refreshes. They run only while the app is open.

**Diagnostics…** shows a report with app and macOS versions, workspace and system file
states, and counts (profiles, folders, remote failures by category). It contains no
profile names, profile text, hostnames, addresses or remote URLs. **Copy report** copies
it to the clipboard. MacHosts sends no telemetry.

## TLS and name resolution limits

- A hosts entry only changes which address a name resolves to. The server at that
  address must present a valid certificate for the name. MacHosts does not change ports,
  URLs, certificates or proxies.
- Browsers and other apps may cache DNS answers or keep connections open. After a
  change, reload or restart the app if it still reaches the old address.
- Software that uses its own resolver, DNS over HTTPS, a VPN or a proxy may ignore
  `/etc/hosts` entirely.

## Data storage, migration and recovery

All data lives in `~/Library/Application Support/MacHosts/`:

| File | Content |
| --- | --- |
| `workspace.json` | Drafts, folders, trash, remote origins and cached downloads, applied state |
| `workspace.previous.json` | The snapshot before the most recent save, used for recovery |
| `workspace.backup-*.json` | Backups from replacement and restore |
| `workspace.recovery-*.json` | Exact copies of originals kept by recovery and format upgrades |
| `.workspace.lock` | Prevents two MacHosts processes from writing at once |

Older workspace formats are upgraded on first open, after their exact old bytes have
been archived as a `workspace.recovery-*.json` file. Older app versions refuse newer formats instead of damaging
them.

If `workspace.json` is damaged, MacHosts opens read-only, says why, keeps the damaged
file and offers **Review previous workspace**. Restoring the previous snapshot is an
explicit choice. Editing and autosave resume after restoring.

## Complete removal

1. In **Settings**, turn off **Open at login**.
2. Quit MacHosts from the menu bar (**Quit MacHosts**).
3. Delete `/Applications/MacHosts.app`.
4. Delete `~/Library/Application Support/MacHosts/` to remove drafts and backups. Export
   anything you want to keep first.
5. Optionally delete the settings with `defaults delete de.machosts.app` in Terminal.

This build never writes `/etc/hosts`, so removal leaves it as it is. Builds that can
apply will provide **Disable all MacHosts entries** to remove their section before
uninstalling.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New profile | ⌘N |
| New window | ⇧⌘N |
| Save drafts | ⌘S |
| Find in profile | ⌘F |
| Replace in profile | ⌥⌘F |
| Search all profiles | ⇧⌘F |
| Preview changes | ⇧⌘P |
| Refresh remote profiles | ⇧⌘R |
| Settings | ⌘, |
| Close a sheet | Esc |

## Limits

| Item | Limit |
| --- | --- |
| Profiles, including the trash | 500 |
| Profile text | 1 MiB, 50,000 lines |
| Whole workspace | 32 MiB |
| Folder depth | 16 |
| System file read | 4 MiB, 50,000 lines |
| Remote download | 1 MiB |

MacHosts rejects changes that would exceed a limit and says so. It never truncates
anything silently.
