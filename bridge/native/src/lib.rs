use std::ffi::{CStr, CString, c_char, c_void};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use idevice::dvt::{
    location_simulation::LocationSimulationClient,
    remote_server::RemoteServerClient,
};
use idevice::remote_pairing::{
    PairableHost, PairableHostInfo, PeerDevice, RemotePairingClient, RpPairingFile,
    RpPairingSocket, connect_tls_psk_tunnel_native,
};
use idevice::rsd::RsdHandshake;
use idevice::{RsdService, tcp};
use tokio::net::{TcpListener, TcpStream};
use tokio::time::{Instant, sleep, timeout};

const DEFAULT_HOST_NAME: &str = "WLOC";
const DEFAULT_HOST_MODEL: &str = "Mac17,7";
const DEFAULT_PEER_ADDRESS: &str = "10.7.0.1";
const IO_TIMEOUT: Duration = Duration::from_secs(15);

pub type PairingReadyCallback = Option<
    extern "C" fn(
        context: *mut c_void,
        service_identifier: *const c_char,
        port: u16,
        txt_keys: *const *const c_char,
        txt_values: *const *const c_char,
        txt_count: usize,
    ),
>;

pub type PairingPinCallback = Option<extern "C" fn(context: *mut c_void, pin: *const c_char)>;
pub type LocationStartedCallback = Option<extern "C" fn(context: *mut c_void)>;

#[repr(C)]
pub struct PairingResult {
    pub error_message: *mut c_char,
    pub pairing_record: *mut u8,
    pub pairing_record_length: usize,
    pub host_alt_irk: *mut u8,
    pub host_alt_irk_length: usize,
}

impl PairingResult {
    fn empty() -> Self {
        Self {
            error_message: ptr::null_mut(),
            pairing_record: ptr::null_mut(),
            pairing_record_length: 0,
            host_alt_irk: ptr::null_mut(),
            host_alt_irk_length: 0,
        }
    }
}

#[repr(C)]
pub struct LocationResult {
    pub error_message: *mut c_char,
}

#[repr(C)]
pub struct PairingSession {
    cancelled: Arc<AtomicBool>,
}

#[repr(C)]
pub struct LocationSession {
    cancelled: Arc<AtomicBool>,
    coordinates: Arc<Mutex<Coordinates>>,
}

#[derive(Clone, Copy, PartialEq)]
struct Coordinates {
    latitude: f64,
    longitude: f64,
}

impl Coordinates {
    fn validate(latitude: f64, longitude: f64) -> Result<Self, String> {
        if latitude.is_finite()
            && longitude.is_finite()
            && (-90.0..=90.0).contains(&latitude)
            && (-180.0..=180.0).contains(&longitude)
        {
            Ok(Self { latitude, longitude })
        } else {
            Err("Coordinates are outside the valid range.".to_string())
        }
    }
}

struct PairingCallbacks {
    ready: PairingReadyCallback,
    pin: PairingPinCallback,
    context: *mut c_void,
}

unsafe impl Send for PairingCallbacks {}

struct CompletedPairing {
    pairing_record: Vec<u8>,
    host_alt_irk: Vec<u8>,
}

#[unsafe(no_mangle)]
pub extern "C" fn wloc_pairing_session_create() -> *mut PairingSession {
    Box::into_raw(Box::new(PairingSession {
        cancelled: Arc::new(AtomicBool::new(false)),
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn wloc_pairing_session_cancel(session: *mut PairingSession) {
    if let Some(session) = unsafe { session.as_ref() } {
        session.cancelled.store(true, Ordering::Release);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn wloc_pairing_session_destroy(session: *mut PairingSession) {
    if !session.is_null() {
        unsafe { drop(Box::from_raw(session)) };
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn wloc_pairing_session_run(
    session: *mut PairingSession,
    host_name: *const c_char,
    host_model: *const c_char,
    ready_callback: PairingReadyCallback,
    pin_callback: PairingPinCallback,
    context: *mut c_void,
    result: *mut PairingResult,
) -> i32 {
    if session.is_null() || result.is_null() {
        return 2;
    }

    unsafe { *result = PairingResult::empty() };
    let session = unsafe { &*session };
    session.cancelled.store(false, Ordering::Release);

    let host_name = unsafe { optional_c_string(host_name, DEFAULT_HOST_NAME) };
    let host_model = unsafe { optional_c_string(host_model, DEFAULT_HOST_MODEL) };
    let callbacks = PairingCallbacks {
        ready: ready_callback,
        pin: pin_callback,
        context,
    };
    let cancellation = Arc::clone(&session.cancelled);

    let execution = catch_unwind(AssertUnwindSafe(|| {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|_| "Could not start the pairing runtime.".to_string())?;

        runtime.block_on(run_pairing(host_name, host_model, callbacks, cancellation))
    }));

    match execution {
        Ok(Ok(completed)) => {
            let result = unsafe { &mut *result };
            let (record, record_len) = owned_bytes(completed.pairing_record);
            result.pairing_record = record;
            result.pairing_record_length = record_len;
            let (irk, irk_len) = owned_bytes(completed.host_alt_irk);
            result.host_alt_irk = irk;
            result.host_alt_irk_length = irk_len;
            0
        }
        Ok(Err(message)) => {
            unsafe { (*result).error_message = owned_c_string(message) };
            1
        }
        Err(_) => {
            unsafe { (*result).error_message = owned_c_string("Pairing stopped unexpectedly.") };
            1
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn wloc_pairing_result_destroy(result: *mut PairingResult) {
    let Some(result) = (unsafe { result.as_mut() }) else { return };
    if !result.error_message.is_null() {
        unsafe { drop(CString::from_raw(result.error_message)) };
    }
    unsafe {
        destroy_bytes(result.pairing_record, result.pairing_record_length);
        destroy_bytes(result.host_alt_irk, result.host_alt_irk_length);
    }
    *result = PairingResult::empty();
}

#[unsafe(no_mangle)]
pub extern "C" fn wloc_location_session_create() -> *mut LocationSession {
    Box::into_raw(Box::new(LocationSession {
        cancelled: Arc::new(AtomicBool::new(false)),
        coordinates: Arc::new(Mutex::new(Coordinates {
            latitude: 0.0,
            longitude: 0.0,
        })),
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn wloc_location_session_update(
    session: *mut LocationSession,
    latitude: f64,
    longitude: f64,
) -> i32 {
    let Some(session) = (unsafe { session.as_ref() }) else { return 2 };
    let Ok(next) = Coordinates::validate(latitude, longitude) else { return 1 };
    let Ok(mut current) = session.coordinates.lock() else { return 2 };
    *current = next;
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn wloc_location_session_cancel(session: *mut LocationSession) {
    if let Some(session) = unsafe { session.as_ref() } {
        session.cancelled.store(true, Ordering::Release);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn wloc_location_session_destroy(session: *mut LocationSession) {
    if !session.is_null() {
        unsafe { drop(Box::from_raw(session)) };
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn wloc_location_session_run(
    session: *mut LocationSession,
    pairing_record: *const u8,
    pairing_record_length: usize,
    peer_address: *const c_char,
    remote_pairing_port: u16,
    service_identifier: *const c_char,
    auth_tag: *const c_char,
    latitude: f64,
    longitude: f64,
    started_callback: LocationStartedCallback,
    context: *mut c_void,
    result: *mut LocationResult,
) -> i32 {
    if session.is_null()
        || result.is_null()
        || pairing_record.is_null()
        || pairing_record_length == 0
    {
        return 2;
    }

    unsafe { (*result).error_message = ptr::null_mut() };
    let session = unsafe { &*session };
    session.cancelled.store(false, Ordering::Release);

    let Ok(initial) = Coordinates::validate(latitude, longitude) else {
        unsafe { (*result).error_message = owned_c_string("Coordinates are outside the valid range.") };
        return 1;
    };
    if let Ok(mut current) = session.coordinates.lock() {
        *current = initial;
    }

    let pairing_record = unsafe {
        std::slice::from_raw_parts(pairing_record, pairing_record_length).to_vec()
    };
    let peer_address = unsafe { optional_c_string(peer_address, DEFAULT_PEER_ADDRESS) };
    let service_identifier = unsafe { optional_c_string(service_identifier, "") };
    let auth_tag = unsafe { optional_c_string(auth_tag, "") };
    let cancellation = Arc::clone(&session.cancelled);
    let coordinates = Arc::clone(&session.coordinates);
    let context_bits = context as usize;

    let execution = catch_unwind(AssertUnwindSafe(|| {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(3)
            .enable_all()
            .build()
            .map_err(|_| "Could not start the CoreDevice runtime.".to_string())?;

        runtime.block_on(run_location(
            pairing_record,
            peer_address,
            remote_pairing_port,
            service_identifier,
            auth_tag,
            coordinates,
            cancellation,
            started_callback,
            context_bits,
        ))
    }));

    match execution {
        Ok(Ok(())) => 0,
        Ok(Err(message)) => {
            unsafe { (*result).error_message = owned_c_string(message) };
            1
        }
        Err(_) => {
            unsafe { (*result).error_message = owned_c_string("Location session stopped unexpectedly.") };
            1
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn wloc_location_result_destroy(result: *mut LocationResult) {
    let Some(result) = (unsafe { result.as_mut() }) else { return };
    if !result.error_message.is_null() {
        unsafe { drop(CString::from_raw(result.error_message)) };
    }
    result.error_message = ptr::null_mut();
}

async fn run_pairing(
    host_name: String,
    host_model: String,
    callbacks: PairingCallbacks,
    cancellation: Arc<AtomicBool>,
) -> Result<CompletedPairing, String> {
    if cancellation.load(Ordering::Acquire) {
        return Err("Pairing was cancelled.".to_string());
    }

    let listener = TcpListener::bind(SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0))
        .await
        .map_err(|_| "Could not open a local pairing listener.".to_string())?;
    let port = listener
        .local_addr()
        .map_err(|_| "Could not read the pairing listener port.".to_string())?
        .port();

    let mut pairing_file = RpPairingFile::generate(&host_name);
    let host_info = PairableHostInfo::generate(&host_name, &host_model);
    let host_alt_irk = host_info.alt_irk.to_vec();
    publish_pairing_ready(&callbacks, &pairing_file.identifier, port, &host_info);

    let (stream, _) = tokio::select! {
        accepted = listener.accept() => {
            accepted.map_err(|_| "The iPhone could not connect to the pairing listener.".to_string())?
        }
        _ = wait_cancelled(Arc::clone(&cancellation)) => {
            return Err("Pairing was cancelled.".to_string());
        }
    };

    let pin_callback = callbacks.pin;
    let context_bits = callbacks.context as usize;
    let socket = RpPairingSocket::new_device(stream);
    let mut host = PairableHost::new(socket, host_info);
    let _peer = tokio::select! {
        outcome = host.accept(&mut pairing_file, move |pin| async move {
            if let Some(callback) = pin_callback
                && let Ok(pin) = CString::new(pin)
            {
                callback(context_bits as *mut c_void, pin.as_ptr());
            }
        }) => outcome.map_err(|_| "The iPhone could not complete remote pairing.".to_string())?,
        _ = wait_cancelled(Arc::clone(&cancellation)) => {
            return Err("Pairing was cancelled.".to_string());
        }
    };

    Ok(CompletedPairing {
        pairing_record: pairing_file.to_bytes(),
        host_alt_irk,
    })
}

#[allow(clippy::too_many_arguments)]
async fn run_location(
    pairing_record_bytes: Vec<u8>,
    peer_address: String,
    remote_pairing_port: u16,
    service_identifier: String,
    auth_tag: String,
    coordinates: Arc<Mutex<Coordinates>>,
    cancellation: Arc<AtomicBool>,
    started_callback: LocationStartedCallback,
    callback_context: usize,
) -> Result<(), String> {
    if remote_pairing_port == 0 || service_identifier.is_empty() || auth_tag.is_empty() {
        return Err("Remote pairing service identity is incomplete.".to_string());
    }

    let mut pairing_file = RpPairingFile::from_bytes(&pairing_record_bytes)
        .map_err(|_| "Saved pairing record is invalid.".to_string())?;
    let alt_irk = pairing_file
        .alt_irk()
        .ok_or_else(|| "Saved pairing record does not contain an AltIRK.".to_string())?;
    if !PeerDevice::validate_auth_tag(alt_irk, &service_identifier, &auth_tag) {
        return Err("Discovered remote pairing service does not match this iPhone.".to_string());
    }

    check_cancelled(&cancellation)?;
    let peer_ip: IpAddr = peer_address
        .parse()
        .map_err(|_| "Peer address is invalid.".to_string())?;
    let pairing_socket_address = SocketAddr::new(peer_ip, remote_pairing_port);
    let stream = timeout(IO_TIMEOUT, TcpStream::connect(pairing_socket_address))
        .await
        .map_err(|_| "Remote pairing connection timed out.".to_string())?
        .map_err(|_| "Could not reach the iPhone through LocalDevVPN.".to_string())?;

    let socket = RpPairingSocket::new(stream);
    let mut remote_pairing = RemotePairingClient::new(socket, DEFAULT_HOST_NAME);
    timeout(IO_TIMEOUT, remote_pairing.attempt_pair_verify())
        .await
        .map_err(|_| "Pair verify timed out.".to_string())?
        .map_err(|_| "The iPhone rejected pair verify.".to_string())?;
    timeout(IO_TIMEOUT, remote_pairing.validate_pairing(&mut pairing_file))
        .await
        .map_err(|_| "Pairing validation timed out.".to_string())?
        .map_err(|_| "Saved pairing record is no longer valid.".to_string())?;

    check_cancelled(&cancellation)?;
    let tunnel_port = timeout(IO_TIMEOUT, remote_pairing.create_tcp_listener())
        .await
        .map_err(|_| "Secure tunnel listener creation timed out.".to_string())?
        .map_err(|_| "The iPhone could not create a secure tunnel listener.".to_string())?;

    let tunnel_stream = timeout(
        IO_TIMEOUT,
        TcpStream::connect(SocketAddr::new(peer_ip, tunnel_port)),
    )
    .await
    .map_err(|_| "Secure tunnel connection timed out.".to_string())?
    .map_err(|_| "Could not connect to the secure device tunnel.".to_string())?;

    let tunnel = timeout(
        IO_TIMEOUT,
        connect_tls_psk_tunnel_native(tunnel_stream, remote_pairing.encryption_key()),
    )
    .await
    .map_err(|_| "TLS-PSK tunnel setup timed out.".to_string())?
    .map_err(|_| "Could not establish the TLS-PSK device tunnel.".to_string())?;

    let client_ip: IpAddr = tunnel
        .info
        .client_address
        .parse()
        .map_err(|_| "CoreDevice returned an invalid client address.".to_string())?;
    let server_ip: IpAddr = tunnel
        .info
        .server_address
        .parse()
        .map_err(|_| "CoreDevice returned an invalid server address.".to_string())?;
    let rsd_port = tunnel.info.server_rsd_port;

    let adapter = tcp::adapter::Adapter::new(Box::new(tunnel.into_inner()), client_ip, server_ip);
    let mut handle = adapter.to_async_handle();
    let rsd_stream = timeout(IO_TIMEOUT, handle.connect(rsd_port))
        .await
        .map_err(|_| "RSD connection timed out.".to_string())?
        .map_err(|_| "Could not connect to RSD.".to_string())?;
    let mut handshake = timeout(IO_TIMEOUT, RsdHandshake::new(rsd_stream))
        .await
        .map_err(|_| "RSD handshake timed out.".to_string())?
        .map_err(|_| "RSD handshake failed.".to_string())?;

    let mut dvt = timeout(
        IO_TIMEOUT,
        RemoteServerClient::connect_rsd(&mut handle, &mut handshake),
    )
    .await
    .map_err(|_| "DVT connection timed out.".to_string())?
    .map_err(|_| "The iPhone did not expose DVT RemoteServer.".to_string())?;

    timeout(IO_TIMEOUT, dvt.read_message(0))
        .await
        .map_err(|_| "DVT readiness timed out.".to_string())?
        .map_err(|_| "DVT RemoteServer did not become ready.".to_string())?;

    let mut location = timeout(IO_TIMEOUT, LocationSimulationClient::new(&mut dvt))
        .await
        .map_err(|_| "LocationSimulation open timed out.".to_string())?
        .map_err(|_| "Could not open LocationSimulation.".to_string())?;

    let mut applied = current_coordinates(&coordinates)?;
    location
        .set(applied.latitude, applied.longitude)
        .await
        .map_err(|_| "The iPhone rejected the simulated location.".to_string())?;

    if let Some(callback) = started_callback {
        callback(callback_context as *mut c_void);
    }

    let mut last_refresh = Instant::now();
    while !cancellation.load(Ordering::Acquire) {
        sleep(Duration::from_millis(200)).await;
        if cancellation.load(Ordering::Acquire) {
            break;
        }
        let latest = current_coordinates(&coordinates)?;
        if latest != applied || last_refresh.elapsed() >= Duration::from_secs(4) {
            location
                .set(latest.latitude, latest.longitude)
                .await
                .map_err(|_| "The active LocationSimulation session ended.".to_string())?;
            applied = latest;
            last_refresh = Instant::now();
        }
    }

    timeout(IO_TIMEOUT, location.clear())
        .await
        .map_err(|_| "LocationSimulation clear timed out.".to_string())?
        .map_err(|_| "Could not clear simulated location.".to_string())?;

    Ok(())
}

fn publish_pairing_ready(
    callbacks: &PairingCallbacks,
    service_identifier: &str,
    port: u16,
    host_info: &PairableHostInfo,
) {
    let Some(callback) = callbacks.ready else { return };
    let Ok(identifier) = CString::new(service_identifier) else { return };
    let records = host_info.mdns_txt_records(service_identifier);

    let keys: Vec<CString> = records
        .iter()
        .filter_map(|(key, _)| CString::new(key.as_str()).ok())
        .collect();
    let values: Vec<CString> = records
        .iter()
        .filter_map(|(_, value)| CString::new(value.as_str()).ok())
        .collect();
    if keys.len() != records.len() || values.len() != records.len() {
        return;
    }

    let key_ptrs: Vec<*const c_char> = keys.iter().map(|value| value.as_ptr()).collect();
    let value_ptrs: Vec<*const c_char> = values.iter().map(|value| value.as_ptr()).collect();

    callback(
        callbacks.context,
        identifier.as_ptr(),
        port,
        key_ptrs.as_ptr(),
        value_ptrs.as_ptr(),
        records.len(),
    );
}

fn current_coordinates(coordinates: &Arc<Mutex<Coordinates>>) -> Result<Coordinates, String> {
    let current = coordinates
        .lock()
        .map_err(|_| "Location state lock failed.".to_string())?;
    Coordinates::validate(current.latitude, current.longitude)
}

fn check_cancelled(cancelled: &Arc<AtomicBool>) -> Result<(), String> {
    if cancelled.load(Ordering::Acquire) {
        Err("Location session was cancelled.".to_string())
    } else {
        Ok(())
    }
}

async fn wait_cancelled(cancelled: Arc<AtomicBool>) {
    while !cancelled.load(Ordering::Acquire) {
        sleep(Duration::from_millis(150)).await;
    }
}

unsafe fn optional_c_string(value: *const c_char, fallback: &str) -> String {
    if value.is_null() {
        return fallback.to_string();
    }
    unsafe { CStr::from_ptr(value) }
        .to_str()
        .ok()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(fallback)
        .to_string()
}

fn owned_c_string(value: impl Into<String>) -> *mut c_char {
    CString::new(value.into())
        .unwrap_or_else(|_| CString::new("WLOC error").expect("static CString"))
        .into_raw()
}

fn owned_bytes(mut bytes: Vec<u8>) -> (*mut u8, usize) {
    let len = bytes.len();
    if len == 0 {
        return (ptr::null_mut(), 0);
    }
    let pointer = bytes.as_mut_ptr();
    std::mem::forget(bytes);
    (pointer, len)
}

unsafe fn destroy_bytes(pointer: *mut u8, length: usize) {
    if pointer.is_null() || length == 0 {
        return;
    }
    unsafe { drop(Vec::from_raw_parts(pointer, length, length)) };
}
