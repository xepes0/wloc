#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 /path/to/LocalDevVPN [device|simulator]" >&2
  exit 2
fi

LOCALDEVVPN_ROOT="$(cd "$1" && pwd)"
MODE="${2:-device}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WLOC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_DIR="$LOCALDEVVPN_ROOT/LocalDevVPN"
NATIVE_OUT="$LOCALDEVVPN_ROOT/WLOCNative"

if [[ ! -f "$LOCALDEVVPN_ROOT/LocalDevVPN.xcodeproj/project.pbxproj" ]]; then
  echo "error: not a LocalDevVPN checkout: $LOCALDEVVPN_ROOT" >&2
  exit 1
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: iOS integration build must run on macOS" >&2
  exit 1
fi

case "$MODE" in
  device)
    RUST_TARGET="aarch64-apple-ios"
    ;;
  simulator)
    case "$(uname -m)" in
      arm64) RUST_TARGET="aarch64-apple-ios-sim" ;;
      x86_64) RUST_TARGET="x86_64-apple-ios" ;;
      *) echo "error: unsupported macOS architecture: $(uname -m)" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "error: mode must be device or simulator" >&2
    exit 2
    ;;
esac

echo "[wloc] building native bridge for $RUST_TARGET"
rustup target add "$RUST_TARGET"
cargo build \
  --manifest-path "$WLOC_ROOT/bridge/native/Cargo.toml" \
  --release \
  --target "$RUST_TARGET"

mkdir -p "$NATIVE_OUT"
cp "$WLOC_ROOT/bridge/native/target/$RUST_TARGET/release/libwloc_coredevice.a" \
   "$NATIVE_OUT/libwloc_coredevice.a"
cp "$WLOC_ROOT/bridge/native/include/wloc_coredevice.h" \
   "$APP_DIR/wloc_coredevice.h"

for source in \
  WLOCBridgeProtocol.swift \
  WLOCBridgeCoordinator.swift \
  WLOCKeychainStore.swift \
  WLOCBonjourDiscovery.swift \
  WLOCNativePairingController.swift \
  WLOCNativeLocationController.swift \
  WLOCBackgroundKeepAlive.swift \
  WLOCNativeExecutor.swift \
  TunnelManager+WLOC.swift \
  WLOCLocalDevVPNBridgeHost.swift \
  WLOCBridgeApprovalView.swift
do
  cp "$SCRIPT_DIR/$source" "$APP_DIR/$source"
done

python3 - "$LOCALDEVVPN_ROOT" <<'PY'
from pathlib import Path
import plistlib
import sys

root = Path(sys.argv[1])
app = root / "LocalDevVPN"

# Bridging header: expose the Rust C ABI to the app target.
bridging = app / "LocalDevVPN-Bridging-Header.h"
text = bridging.read_text()
include = '#include "wloc_coredevice.h"'
if include not in text:
    if not text.endswith("\n"):
        text += "\n"
    text += include + "\n"
    bridging.write_text(text)

# Info.plist: Remote Pairing needs local-network Bonjour. The first PoC keeps
# the DVT session alive in the host app with background CoreLocation updates;
# those coordinates are never used as WLOC's control source.
plist_path = app / "Info.plist"
with plist_path.open("rb") as fh:
    plist = plistlib.load(fh)
plist.setdefault(
    "NSLocalNetworkUsageDescription",
    "WLOC uses the local device tunnel to pair with and control this iPhone for development location testing.",
)
plist.setdefault(
    "NSLocationWhenInUseUsageDescription",
    "WLOC uses low-accuracy location updates only to keep an active development location-simulation session running in the background.",
)
services = list(plist.get("NSBonjourServices", []))
for service in [
    "_apple-mobdev2._tcp",
    "_remotepairing-pairable-host._tcp",
    "_remotepairing._tcp",
]:
    if service not in services:
        services.append(service)
plist["NSBonjourServices"] = services
background_modes = list(plist.get("UIBackgroundModes", []))
if "location" not in background_modes:
    background_modes.append("location")
plist["UIBackgroundModes"] = background_modes
with plist_path.open("wb") as fh:
    plistlib.dump(plist, fh, fmt=plistlib.FMT_XML, sort_keys=False)

# App scene: keep the original enable/disable deep links and intercept only
# localdevvpn://wloc/... for the WLOC bridge.
app_swift = app / "LocalDevVPNApp.swift"
text = app_swift.read_text()
state_marker = "    @StateObject private var wlocBridge = WLOCLocalDevVPNBridgeHost()\n"
if state_marker not in text:
    needle = "struct LocalDevVPNApp: App {\n"
    if needle not in text:
        raise SystemExit("LocalDevVPNApp.swift shape changed: App declaration not found")
    text = text.replace(needle, needle + state_marker, 1)

old = '''            ContentView()\n                .onOpenURL { url in\n                    handleURL(url)\n                }'''
new = '''            ZStack(alignment: .bottom) {\n                ContentView()\n                WLOCBridgeApprovalView(host: wlocBridge)\n            }\n            .onOpenURL { url in\n                if !wlocBridge.handleURL(url) {\n                    handleURL(url)\n                }\n            }'''
if new not in text:
    if old not in text:
        raise SystemExit("LocalDevVPNApp.swift shape changed: ContentView/onOpenURL block not found")
    text = text.replace(old, new, 1)
app_swift.write_text(text)

# WLOC's CoreDevice/RemotePairing transport is a modern-iOS feature. Upstream
# LocalDevVPN currently hard-codes iOS 14 in its Xcode project. A value appended
# only to Build.xcconfig is not sufficient because explicit Xcode build settings
# take precedence over the xcconfig. Patch this temporary checkout to iOS 17 so
# CI and real-device builds use the same deployment floor without modifying the
# upstream repository.
project_path = root / "LocalDevVPN.xcodeproj" / "project.pbxproj"
project_text = project_path.read_text()
old_target = "IPHONEOS_DEPLOYMENT_TARGET = 14.0;"
replacement_target = "IPHONEOS_DEPLOYMENT_TARGET = 17.0;"
count = project_text.count(old_target)
if count == 0 and replacement_target not in project_text:
    raise SystemExit("LocalDevVPN project shape changed: deployment target setting not found")
if count:
    project_text = project_text.replace(old_target, replacement_target)
    project_path.write_text(project_text)
    print(f"[wloc] raised {count} Xcode deployment-target setting(s) to iOS 17.0")

# Link the Rust static library from a root-level folder. Keep the xcconfig value
# too so inherited settings and ad-hoc build invocations agree with the project.
xcconfig = root / "Build.xcconfig"
text = xcconfig.read_text()
marker = "// WLOC CoreDevice bridge"
block = '''\n// WLOC CoreDevice bridge\nIPHONEOS_DEPLOYMENT_TARGET = 17.0\nHEADER_SEARCH_PATHS = $(inherited) "$(SRCROOT)/LocalDevVPN"\nLIBRARY_SEARCH_PATHS = $(inherited) "$(SRCROOT)/WLOCNative"\nOTHER_LDFLAGS = $(inherited) -lwloc_coredevice\n'''
if marker not in text:
    if not text.endswith("\n"):
        text += "\n"
    text += block
    xcconfig.write_text(text)
PY

echo "[wloc] LocalDevVPN integration prepared at: $LOCALDEVVPN_ROOT"
echo "[wloc] mode: $MODE ($RUST_TARGET)"
echo "[wloc] next: build the LocalDevVPN scheme with Xcode/xcodebuild"
