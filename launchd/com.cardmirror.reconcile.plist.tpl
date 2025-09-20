<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.cardmirror.reconcile</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>-lc</string>
    <string>__REPO_ROOT__/bin/reconcile-all.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>3</integer>
    <key>Minute</key><integer>30</integer>
  </dict>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/card-reconcile.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/card-reconcile.err.log</string>
  <key>Nice</key><integer>1</integer>
</dict>
</plist>
