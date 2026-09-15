# WLOC CoreDevice native bridge

This directory is the native engine planned for the iOS 27 WLOC route.

It is intentionally independent from Roam-Control source code. It depends directly on the MIT-licensed `jkcoxson/idevice` crate at a pinned revision and exposes a small C ABI for Swift.

Implemented paths:

```text
on-device pairing
  TcpListener
  -> PairableHost
  -> RPPairing record

location session
  LocalDevVPN peer (default 10.7.0.1)
  -> RemotePairing pair verify
  -> TLS-PSK tunnel
  -> RSD
  -> DVT RemoteServer
  -> LocationSimulation.set()
  -> periodic refresh / coordinate update
  -> LocationSimulation.clear()
```

## Host-side validation

```sh
cargo check --manifest-path bridge/native/Cargo.toml
```

CI runs this check in addition to the Worker tests.

## iOS build target

The final WLOC-enabled LocalDevVPN build should produce a static library for `aarch64-apple-ios` and expose `include/wloc_coredevice.h` to Swift. The Xcode packaging step is intentionally not committed yet because it must be validated against the actual LocalDevVPN signing/target layout on macOS.

A typical Rust-side build on a Mac with the target installed will start with:

```sh
rustup target add aarch64-apple-ios
cargo build --manifest-path bridge/native/Cargo.toml --release --target aarch64-apple-ios
```

Do not treat a host `cargo check` as proof that the iOS static library has been linked successfully. The next milestone is an Xcode/LocalDevVPN integration build followed by iOS 27 hardware testing.

## FFI lifetime

- Pairing and location sessions are opaque pointers created/destroyed by matching C functions.
- Result-owned strings and byte buffers must be freed with the corresponding `*_result_destroy` function.
- `wloc_location_session_run` is blocking and should run on a non-main queue.
- `wloc_location_session_update` can replace the target coordinates while a session is active.
- `wloc_location_session_cancel` asks the worker to clear the simulated location and finish.

Pairing records and AltIRK are sensitive local secrets. Swift must store them in Keychain and never place them in URL callbacks, Worker requests or analytics.
