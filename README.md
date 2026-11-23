# AppDebug: Firebase Events Live

Live, QA-friendly view of the Firebase Analytics events fired by an Android app, next to a
mirror of the phone. A UI version of the `firebase_debug.ps1` QA script.

## Requirements
- Node 18+ and `adb` (Android platform-tools) on your computer.
- Android phone with Developer options; a staging/debug build using Firebase.

## Run
```
node server.js        # then open http://localhost:4455
```
No `npm install`. Everything stays on your computer.

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
