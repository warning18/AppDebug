# AppDebug: Firebase Events Live

Live, QA-friendly view of the Firebase Analytics events fired by an Android app, next to a
mirror of the phone. A UI version of the `firebase_debug.ps1` QA script.

## Requirements
- Windows/macOS/Linux. Node 18+ and `adb`, either installed or fetched by `setup.bat` into the folder.
- Android phone with Developer options; a staging/debug build using Firebase.

## Run
**Windows, no Node.js at all (PowerShell only):** put `platform-tools\` next to the files and double-click
`AppDebug.bat` (runs `AppDebug.ps1`, same web page, same features, no install, no admin rights).

**Windows, nothing installed (recommended for work PCs):**
1. Download the repo ZIP and unzip it to any folder.
2. Double-click `setup.bat` once: downloads portable Node.js and adb into `runtime\` (no admin rights).
   If downloads are blocked on that PC, run it on another PC and copy the whole folder over.
3. Double-click `start.bat`: opens http://localhost:4455.

**Any OS with Node 18+ and adb installed:** `node server.js`, then open http://localhost:4455.

No `npm install`. Everything stays on your computer. If `runtime\platform-tools\adb.exe` exists it is used
automatically, otherwise `adb` from PATH (or the `ADB` environment variable).

## Use
1. Connect by USB, or click **Wi-Fi…** (Wireless debugging: pair, then connect).
2. Pick the device, type or pick the **target package**, choose a mode, click **Start capture**.
3. Use the app. Events show as cards:
   - **Batches + screenshots** (default, like the QA script): events are read from `FA-SVC` upload
     batches. Each batch gets a screenshot cropped to the app window, shown beside its events.
     Skipped if the app is not in the foreground.
   - **Instant events**: events as soon as they are logged (`FA` tag), no screenshots.
4. **hide system params** hides `_o`, `firebase_screen*`, `ga_*`, `engagement_time_msec`, etc.
   Filter, pause, flat list, click a screenshot to zoom, download any side-by-side PNG.
5. **Stop & save** writes the session folder.

## Output (`sessions/QA_Run_<timestamp>/`)
- `firebase_report.csv` (`;` separated: Time, EventName, Screenshot, AnnotatedScreenshot,
  one column per parameter, FullObject)
- `screenshots/<time>_batch_<n>events.png` (app only) and `..._sidebyside.png`
  (side-by-side images are rendered by the browser, so keep the page open while capturing).

## How it works
No traffic interception or certificates. It sets `debug.firebase.analytics.app=<package>` and
verbose `FA` / `FA-SVC` log tags, then parses `adb logcat`. Stop resets the property.
Android only.

## Windows without admin rights (manual)
- `platform-tools\` (adb) may sit in the AppDebug folder or in `runtime\`: it is found automatically.
- Node without installing: put the Node `.msi` in the folder, then in cmd:
  `msiexec /a node-v26.13.1-x64.msi /qn TARGETDIR="%CD%\node"` and double-click `start.bat`.
  (If an installer is allowed, just install the MSI and double-click `start.bat`.)
