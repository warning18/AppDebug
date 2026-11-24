# First-run checklist: AppDebug.ps1 (PowerShell edition)

The PowerShell server has not been run by its author on Windows yet. Walk through this once;
note the first step that fails and send the red text from the window.

1. Double-click `AppDebug.bat`. Expect `Firebase Events Live: http://localhost:4455` and a browser tab.
   - "Cannot listen on port": another program uses 4455. Run `powershell -File AppDebug.ps1 -Port 4466`.
2. Page header shows your device in the first dropdown. Empty? Run `.\platform-tools\adb devices`.
3. Click the package field: installed apps are suggested.
4. Phone panel on the left shows the live screen (updates about 3 times a second).
5. Choose "Instant events", Start capture, open the app: events appear in a few seconds.
6. Choose "Batches + screenshots", Start capture, use the app, wait for the upload (up to a minute,
   or force it by sending the app to the background): a card with a screenshot appears.
7. "Stop & save": the page shows the session folder. Check `sessions\QA_Run_*\firebase_report.csv`
   and `screenshots\*.png` (clean and `_sidebyside`).
8. Close the window: `debug.firebase.analytics.app` is reset (`adb shell getprop debug.firebase.analytics.app`
   prints `.none.`).

Where problems are most likely: quoting of the `dumpsys` command (step 6: "Skipped" on every batch
while the app is open), JSON output of one-item lists (steps 2 and 3), and the logcat line format of
your Android version (steps 5 and 6: nothing appears; send 5 lines of `adb logcat -v time -s FA-SVC:V`).
