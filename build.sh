#!/bin/bash
# Builds "Sheet Viewer.app" into ~/Applications: one fast window per spreadsheet
# with a tab per page, columns that sort on a click, a search box, light editing
# (cells, rows, pages, colors) and export to CSV or Excel. CSV is read and
# written by the app itself; Excel and Numbers files go through read.py and
# write.py, in the Python venv set up below.
#
#   ./build.sh            build and install
#   ./build.sh --default  also make it the app that opens CSV, Excel and Numbers files
set -euo pipefail
cd "$(dirname "$0")"

name="Sheet Viewer"
app="$HOME/Applications/$name.app"
support="$HOME/Library/Application Support/$name"
bundle_id="com.chris.sheetviewer"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$support"
[ -x "$support/venv/bin/python" ] || uv venv "$support/venv" --python 3.12 -q
uv pip install -q --python "$support/venv/bin/python" openpyxl python-calamine numbers-parser

bundle="$tmp/$name.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
swiftc -O -swift-version 5 -o "$bundle/Contents/MacOS/SheetViewer" main.swift
"$bundle/Contents/MacOS/SheetViewer" --selftest
cp read.py write.py "$bundle/Contents/Resources/"

if [ ! -f AppIcon.icns ]; then
  swift make_icon.swift "$tmp/icon.png"
  mkdir "$tmp/AppIcon.iconset"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$tmp/AppIcon.iconset" -o AppIcon.icns
fi
cp AppIcon.icns "$bundle/Contents/Resources/"

# Editor for what it can write back (CSV, Excel); viewer for what it can only read (Numbers, OpenDocument).
doc_type() {
  printf '<dict><key>CFBundleTypeName</key><string>%s</string><key>CFBundleTypeRole</key><string>%s</string>' "$1" "$2"
  printf '<key>LSHandlerRank</key><string>%s</string><key>LSItemContentTypes</key><array>' "$3"
  shift 3
  printf '<string>%s</string>' "$@"
  printf '</array></dict>\n'
}
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleDisplayName</key><string>$name</string>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleExecutable</key><string>SheetViewer</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDocumentTypes</key><array>
$(doc_type "Delimited Text" Editor Default public.comma-separated-values-text public.tab-separated-values-text)
$(doc_type "Excel Workbook" Editor Default org.openxmlformats.spreadsheetml.sheet org.openxmlformats.spreadsheetml.sheet.macroenabled \
  com.microsoft.excel.xls com.microsoft.excel.sheet.binary.macroenabled org.openxmlformats.spreadsheetml.template)
$(doc_type "Numbers Spreadsheet" Viewer Default com.apple.iwork.numbers.sffnumbers com.apple.iwork.numbers.numbers)
$(doc_type "OpenDocument Spreadsheet" Viewer Alternate org.oasis-open.opendocument.spreadsheet)
</array>
</dict></plist>
PLIST
plutil -lint "$bundle/Contents/Info.plist" >/dev/null

# A real identity keeps the Files and Folders grants across rebuilds.
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
if ! signing=$(codesign --force --deep -s "${identity:--}" "$bundle" 2>&1); then
  echo "$signing" >&2
  exit 1
fi

mkdir -p "$(dirname "$app")"
rm -rf "${app:?}"
mv "$bundle" "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
codesign -v "$app"

if [ "${1:-}" != "--default" ]; then
  echo "Installed $app"
  echo "Run ./build.sh --default to also make it the app that opens spreadsheets."
  exit 0
fi

swift - "$bundle_id" <<'SWIFT'
import CoreServices
import Foundation
let id = CommandLine.arguments[1] as CFString
for uti in ["public.comma-separated-values-text", "public.tab-separated-values-text",
            "com.apple.iwork.numbers.sffnumbers", "com.apple.iwork.numbers.numbers",
            "org.openxmlformats.spreadsheetml.sheet",
            "org.openxmlformats.spreadsheetml.sheet.macroenabled", "com.microsoft.excel.xls",
            "com.microsoft.excel.sheet.binary.macroenabled"] {
    let status = LSSetDefaultRoleHandlerForContentType(uti as CFString, .all, id)
    print(uti, status == 0 ? "-> Sheet Viewer" : "failed (\(status))")
}
SWIFT
