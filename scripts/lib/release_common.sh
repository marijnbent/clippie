#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE_CONFIG="$ROOT_DIR/release/Release.plist"
RELEASE_ENTITLEMENTS="$ROOT_DIR/release/App.entitlements"
BUILD_DIR="$ROOT_DIR/build/Release"
TMP_DIR="$ROOT_DIR/build/tmp"

release::print() {
  printf '[release] %s\n' "$*"
}

release::fail() {
  printf '[release] ERROR: %s\n' "$*" >&2
  exit 1
}

release::require_file() {
  local path="$1"
  [[ -f "$path" ]] || release::fail "Missing file: $path"
}

release::config() {
  local key="$1"
  /usr/libexec/PlistBuddy -c "Print :$key" "$RELEASE_CONFIG" 2>/dev/null
}

release::require_config() {
  local key="$1"
  local value
  value="$(release::config "$key" || true)"
  [[ -n "$value" ]] || release::fail "Missing release config key: $key"
  printf '%s\n' "$value"
}

release::bool_tag() {
  local raw
  raw="$(release::require_config "$1")"
  case "$raw" in
    true|yes|1) printf 'true' ;;
    false|no|0) printf 'false' ;;
    *) release::fail "Expected boolean for $1, got: $raw" ;;
  esac
}

release::xml_escape() {
  printf '%s' "$1" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

release::plist_string_entry() {
  local key="$1"
  local value="$2"
  printf '    <key>%s</key>\n    <string>%s</string>\n' \
    "$key" \
    "$(release::xml_escape "$value")"
}

release::app_name() {
  release::require_config AppName
}

release::build_bundle_path() {
  printf '%s/%s.app\n' "$BUILD_DIR" "$(release::app_name)"
}

release::installed_bundle_path() {
  printf '/Applications/%s.app\n' "$(release::app_name)"
}

release::prepare_build_directories() {
  rm -rf "$BUILD_DIR" "$TMP_DIR"
  mkdir -p "$BUILD_DIR" "$TMP_DIR"
}

release::verify_identity() {
  local identity
  identity="$(release::require_config SigningIdentity)"
  security find-identity -v -p codesigning | grep -Fq "\"$identity\"" || release::fail "Signing identity is not installed: $identity"
}

release::quit_running_app() {
  local app_name="$1"
  local app_path pattern attempt
  for app_path in "$(release::installed_bundle_path)" "$(release::build_bundle_path)"; do
    pattern="^$app_path/Contents/MacOS/$app_name( |$)"
    if pgrep -f "$pattern" >/dev/null; then
      osascript -e "tell application \"$app_path\" to quit" || release::fail "Could not quit $app_path"
      for attempt in {1..20}; do
        pgrep -f "$pattern" >/dev/null || break
        sleep 0.25
      done
      if pgrep -f "$pattern" >/dev/null; then
        release::fail "$app_name is still open. Close its dialogs and quit before installing."
      fi
    fi
  done
}

release::normalize_bundle() {
  local bundle="$1"
  chmod -R u+w "$bundle"
  xattr -cr "$bundle"
  find "$bundle" -name '._*' -delete
}

release::copy_swiftpm_resource_bundles() {
  local bin_dir="$1"
  local resources_dir="$2"
  local bundle

  shopt -s nullglob
  local bundles=("$bin_dir"/*.bundle)
  shopt -u nullglob

  for bundle in "${bundles[@]}"; do
    cp -R "$bundle" "$resources_dir/"
  done
}

release::copy_swiftpm_frameworks() {
  local bin_dir="$1"
  local frameworks_dir="$2"
  local executable_path="$3"

  shopt -s nullglob
  local frameworks=("$bin_dir"/*.framework)
  shopt -u nullglob

  if [[ ${#frameworks[@]} -eq 0 ]]; then
    return 0
  fi

  cp -R "${frameworks[@]}" "$frameworks_dir/"
  chmod -R a+rX "$frameworks_dir"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$executable_path"
}

release::install_icon() {
  local resources_dir="$1"
  local icon_source_rel
  icon_source_rel="$(release::config IconSource || true)"

  if [[ -z "$icon_source_rel" ]]; then
    return 0
  fi

  local icon_source="$ROOT_DIR/$icon_source_rel"
  local icon_target="$resources_dir/Icon.icns"

  [[ -e "$icon_source" ]] || release::fail "Missing icon source: $icon_source"

  case "$icon_source" in
    *.icns)
      cp "$icon_source" "$icon_target"
      ;;
    *.iconset)
      iconutil --convert icns --output "$icon_target" "$icon_source"
      ;;
    *.png)
      local iconset_dir="$TMP_DIR/icon.iconset"
      rm -rf "$iconset_dir"
      mkdir -p "$iconset_dir"
      sips -z 16 16 "$icon_source" --out "$iconset_dir/icon_16x16.png" >/dev/null
      sips -z 32 32 "$icon_source" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
      sips -z 32 32 "$icon_source" --out "$iconset_dir/icon_32x32.png" >/dev/null
      sips -z 64 64 "$icon_source" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
      sips -z 128 128 "$icon_source" --out "$iconset_dir/icon_128x128.png" >/dev/null
      sips -z 256 256 "$icon_source" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
      sips -z 256 256 "$icon_source" --out "$iconset_dir/icon_256x256.png" >/dev/null
      sips -z 512 512 "$icon_source" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
      sips -z 512 512 "$icon_source" --out "$iconset_dir/icon_512x512.png" >/dev/null
      sips -z 1024 1024 "$icon_source" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null
      iconutil --convert icns --output "$icon_target" "$iconset_dir"
      ;;
    *)
      release::fail "Unsupported icon source type: $icon_source"
      ;;
  esac

  printf 'Icon\n'
}

release::write_info_plist() {
  local plist_path="$1"
  local icon_name="${2:-}"
  local app_name bundle_id marketing_version build_number minimum_system_version
  local lsui_tag copyright_text

  app_name="$(release::require_config AppName)"
  bundle_id="$(release::require_config BundleIdentifier)"
  marketing_version="$(release::require_config MarketingVersion)"
  build_number="$(release::require_config BuildNumber)"
  minimum_system_version="$(release::require_config MinimumSystemVersion)"
  lsui_tag="$(release::bool_tag LSUIElement)"
  copyright_text="$(release::config Copyright || true)"

  cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
$(release::plist_string_entry "CFBundleDevelopmentRegion" "en")
$(release::plist_string_entry "CFBundleExecutable" "$app_name")
$(release::plist_string_entry "CFBundleDisplayName" "$app_name")
$(release::plist_string_entry "CFBundleIdentifier" "$bundle_id")
$(release::plist_string_entry "CFBundleInfoDictionaryVersion" "6.0")
$(release::plist_string_entry "CFBundleName" "$app_name")
$(release::plist_string_entry "CFBundlePackageType" "APPL")
$(release::plist_string_entry "CFBundleShortVersionString" "$marketing_version")
$(release::plist_string_entry "CFBundleVersion" "$build_number")
$(release::plist_string_entry "LSMinimumSystemVersion" "$minimum_system_version")
    <key>LSUIElement</key>
    <${lsui_tag}/>
EOF

  if [[ -n "$icon_name" ]]; then
    printf '%s\n' "$(release::plist_string_entry "CFBundleIconFile" "$icon_name")" >> "$plist_path"
  fi

  local optional_keys=(
    NSAccessibilityUsageDescription
    NSInputMonitoringUsageDescription
    NSAppleEventsUsageDescription
    NSMicrophoneUsageDescription
    NSCameraUsageDescription
    NSUserNotificationAlertStyle
  )

  local key
  for key in "${optional_keys[@]}"; do
    local value
    value="$(release::config "$key" || true)"
    if [[ -n "$value" ]]; then
      printf '%s\n' "$(release::plist_string_entry "$key" "$value")" >> "$plist_path"
    fi
  done

  if [[ -n "$copyright_text" ]]; then
    printf '%s\n' "$(release::plist_string_entry "NSHumanReadableCopyright" "$copyright_text")" >> "$plist_path"
  fi

  cat >> "$plist_path" <<'EOF'
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

  plutil -lint "$plist_path" >/dev/null
}

release::sign_bundle() {
  local bundle="$1"
  local entitlements_path="$2"
  local signing_identity
  signing_identity="$(release::require_config SigningIdentity)"
  local codesign_args=(--force --timestamp --options runtime --sign "$signing_identity")
  local framework_binary
  local framework_dir

  if [[ -d "$bundle/Contents/Frameworks" ]]; then
    while IFS= read -r -d '' framework_binary; do
      codesign "${codesign_args[@]}" "$framework_binary"
    done < <(find "$bundle/Contents/Frameworks" -type f -perm -111 -print0)

    while IFS= read -r -d '' framework_dir; do
      codesign "${codesign_args[@]}" "$framework_dir"
    done < <(find "$bundle/Contents/Frameworks" -maxdepth 1 -type d -name '*.framework' -print0)
  fi

  codesign "${codesign_args[@]}" --entitlements "$entitlements_path" "$bundle"
}

release::verify_bundle() {
  local bundle="$1"
  codesign --verify --deep --strict "$bundle"
  plutil -lint "$bundle/Contents/Info.plist" >/dev/null
}

release::install_bundle() {
  local bundle="$1"
  local destination
  destination="$(release::installed_bundle_path)"
  rm -rf "$destination"
  ditto "$bundle" "$destination"
  release::verify_bundle "$destination"
  open "$destination"
  release::print "Installed $destination"
}

release::build_swiftpm_app() {
  local product_name bin_dir binary_path app_bundle contents_dir
  local macos_dir resources_dir frameworks_dir icon_name

  product_name="$(release::config ProductName || true)"
  if [[ -z "$product_name" ]]; then
    product_name="$(release::app_name)"
  fi

  release::require_file "$RELEASE_ENTITLEMENTS"
  release::verify_identity
  release::prepare_build_directories

  (
    cd "$ROOT_DIR"
    swift build -c release
  )
  bin_dir="$(
    cd "$ROOT_DIR"
    swift build -c release --show-bin-path
  )"
  binary_path="$bin_dir/$product_name"
  [[ -f "$binary_path" ]] || release::fail "Missing SwiftPM product: $binary_path"

  app_bundle="$(release::build_bundle_path)"
  contents_dir="$app_bundle/Contents"
  macos_dir="$contents_dir/MacOS"
  resources_dir="$contents_dir/Resources"
  frameworks_dir="$contents_dir/Frameworks"

  mkdir -p "$macos_dir" "$resources_dir" "$frameworks_dir"
  cp "$binary_path" "$macos_dir/$(release::app_name)"
  chmod +x "$macos_dir/$(release::app_name)"

  release::copy_swiftpm_resource_bundles "$bin_dir" "$resources_dir"
  release::copy_swiftpm_frameworks "$bin_dir" "$frameworks_dir" "$macos_dir/$(release::app_name)"
  icon_name="$(release::install_icon "$resources_dir")"
  release::write_info_plist "$contents_dir/Info.plist" "$icon_name"
  release::normalize_bundle "$app_bundle"
  release::sign_bundle "$app_bundle" "$RELEASE_ENTITLEMENTS"
  release::verify_bundle "$app_bundle"

  release::print "Built $app_bundle"
}

release::build_release_app() {
  local backend
  backend="$(release::require_config BuildBackend)"

  case "$backend" in
    swiftpm)
      release::build_swiftpm_app
      ;;
    *)
      release::fail "Unsupported BuildBackend: $backend"
      ;;
  esac
}
