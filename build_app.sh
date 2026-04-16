#!/bin/bash
# Build Savanna.app — self-contained macOS application
# Usage: bash build_app.sh

set -e

echo "Building Savanna.app..."

# 1. Build release binary
swift build -c release --product savanna-app
echo "  Binary: OK"

# 2. Create .app bundle
rm -rf Savanna.app
mkdir -p Savanna.app/Contents/{MacOS,Resources}

# 3. Copy binary
cp .build/release/savanna-app Savanna.app/Contents/MacOS/Savanna
chmod +x Savanna.app/Contents/MacOS/Savanna
echo "  Executable: OK"

# 4. Copy Info.plist (create if missing)
if [ -f Savanna.app.plist ]; then
    cp Savanna.app.plist Savanna.app/Contents/Info.plist
else
    cat > Savanna.app/Contents/Info.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Savanna</string>
    <key>CFBundleIdentifier</key><string>com.norayr.savanna</string>
    <key>CFBundleName</key><string>Savanna</string>
    <key>CFBundleDisplayName</key><string>Savanna — Digital Serengeti</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.4.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Norayr Matevosyan + Claude. GPL v3. 2026.</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
</dict>
</plist>
PLIST
fi
echo "  Info.plist: OK"

# 5. Copy Metal shader bundle
if [ -d .build/release/Savanna_Savanna.bundle ]; then
    cp -r .build/release/Savanna_Savanna.bundle Savanna.app/Contents/Resources/
    echo "  Shaders: OK"
fi

# 6. Copy scenarios
mkdir -p Savanna.app/Contents/Resources/scenarios
cp scenarios/*.json Savanna.app/Contents/Resources/scenarios/ 2>/dev/null
echo "  Scenarios: OK"

# 7. Generate icon if iconutil available and no icon exists
if [ ! -f Savanna.app/Contents/Resources/AppIcon.icns ]; then
    echo "  Icon: MISSING (run icon generator separately)"
fi

# 8. Summary
SIZE=$(du -sh Savanna.app | cut -f1)
echo ""
echo "╔══════════════════════════════════════╗"
echo "║  Savanna.app built successfully      ║"
echo "║  Size: $SIZE                        ║"
echo "║  Double-click to launch              ║"
echo "╚══════════════════════════════════════╝"
echo ""
echo "Install: cp -r Savanna.app /Applications/"
