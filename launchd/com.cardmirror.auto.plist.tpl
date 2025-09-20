<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.cardmirror.auto</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>-lc</string>
    <string>__REPO_ROOT__/bin/card-mirror-run.sh</string>
  </array>
  <key>WatchPaths</key>
  <array>
    <string>/Volumes</string>
  </array>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/card-mirror.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/card-mirror.err.log</string>
  <key>Nice</key><integer>1</integer>
</dict>
</plist>
