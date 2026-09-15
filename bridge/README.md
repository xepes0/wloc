# WLOC iOS 27 bridge

The `bridge/` tree is the native/on-device control layer for the experimental iOS 27 backend.

Unlike the legacy WLOC scripts, these files do **not** MITM Apple location responses. The control path is:

```text
WLOC web UI
  -> localdevvpn://wloc/...
  -> WLOC-enabled LocalDevVPN
  -> 10.7.0.1 self tunnel
  -> RemotePairing
  -> TLS-PSK / RSD
  -> DVT
  -> LocationSimulation
```

## Layout

- `native/` — Rust static library using the MIT `idevice` crate.
- `localdevvpn/` — Swift URL bridge, Keychain storage, RemotePairing Bonjour discovery/publishing, native session controllers, approval UI and integration script.
- `LICENSE` — MIT license for the standalone bridge files in this directory.

The parent WLOC project keeps its existing licensing. This bridge is separately MIT-licensed so it can be proposed upstream or embedded in a compatible LocalDevVPN build without pulling the legacy WLOC AGPL web/scripts into that app binary.

## Reproducible LocalDevVPN integration

On macOS:

```sh
git clone https://github.com/jkcoxson/LocalDevVPN.git
bash bridge/localdevvpn/integrate-localdevvpn.sh ./LocalDevVPN device
open ./LocalDevVPN/LocalDevVPN.xcodeproj
```

For an iOS Simulator compile-only check:

```sh
bash bridge/localdevvpn/integrate-localdevvpn.sh ./LocalDevVPN simulator
```

The script:

1. builds `libwloc_coredevice.a` for the requested Apple target;
2. copies the public C header and Swift bridge into the LocalDevVPN app target;
3. adds the RemotePairing Bonjour service declarations and local-network usage text;
4. extends the existing `localdevvpn://` URL handler with the WLOC bridge host;
5. links the native static library through `Build.xcconfig`.

GitHub Actions runs the simulator integration build on every branch update. A green simulator build proves the Swift/C/Rust/Xcode integration compiles; it is **not** a substitute for iOS 27 hardware validation of RemotePairing and LocationSimulation.

## Distribution note

LocalDevVPN's own license permits modification but contains attribution and branding/redistribution conditions. Do not publish a modified app under the LocalDevVPN name/branding without satisfying its license and obtaining any permission its branding clause requires. For development, prefer an upstream contribution or a clearly identified local test build.
