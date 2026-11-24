//! `fluxvale mcp serve` (#886): the bridge between an MCP client's
//! stdio and the remote MCP server's streamable HTTP transport. Each
//! stdin line is one JSON-RPC message, forwarded verbatim as one POST
//! with the stored access token. The bridge renews the pair itself, so
//! the client never holds a credential, and sends that token to one
//! server only: the one the stored sign-in is bound to. stdout is the
//! protocol channel: one writer thread, one message per line.

use crate::config;
use crate::token::{McpCredentials, McpTokenStore};
use fluxvale_api::{McpHttpClient, McpReply, OAuthTokenPair, RefreshError, Token};
use serde_json::Value;
use std::fs::{File, OpenOptions, TryLockError};
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex, PoisonError, RwLock};
use std::time::{Duration, Instant};

/// JSON-RPC parse error: the client wrote a line that is not JSON.
const PARSE_ERROR: i64 = -32700;
/// JSON-RPC internal error: what a request gets when the bridge could not get the server's answer.
const INTERNAL_ERROR: i64 = -32603;
/// An access token this close to its expiry is renewed before it is used.
const EXPIRY_LEEWAY_SECS: u64 = 60;
/// Where a request states its protocol version, under `params._meta`.
const META_PROTOCOL_VERSION: &str = "io.modelcontextprotocol/protocolVersion";
/// The first protocol version for which the server requires a request
/// that carries it as a header to state it under `params._meta` too.
const PER_REQUEST_META_FROM: &str = "2026-07-28";
/// What a client reads when the stored sign-in can no longer be renewed.
const SIGN_IN_LOST: &str = "MCP sign-in is no longer valid. Run `fluxvale mcp login`.";
/// Every line the bridge writes to stderr starts with this.
const PREFIX: &str = "fluxvale: ";
/// Why the sign-in is lost when a reload finds nothing: someone ran `fluxvale mcp logout`.
const SIGN_IN_REMOVED: &str = "the stored sign-in was removed";
/// Why the sign-in is lost when the server refuses a pair it has just renewed.
const RENEWED_TOKEN_REFUSED: &str = "the server refused the renewed token";
/// Why the sign-in is lost when the store now holds a pair minted for another server.
const SIGN_IN_MOVED: &str = "the stored sign-in is now for";
/// What a request is told when its renewal failed for a reason that passes.
const RENEWAL_FAILED: &str = "could not renew the MCP access token";
/// How long a renewal waits for the cross-process lock by default. The
/// token client's own timeout is 30 seconds, so a renewal that is still
/// running after this is not going to finish.
const RENEWAL_LOCK_WAIT: Duration = Duration::from_secs(45);
/// How often a renewal waiting for the cross-process lock tries again.
const RENEWAL_LOCK_POLL: Duration = Duration::from_millis(25);

/// The one MCP endpoint the bridge talks to, and the only one the stored
/// pair's token may go to.
///
/// The pair's token only ever goes to the resource it was minted for,
/// named by the stored `resource` or, when there is none, by the
/// environment's own MCP server. `--url` can only confirm it. A flag
/// that names another server is refused, because the pair offers no way
/// to be sent anywhere else.
pub fn resolve_url(
    flag_url: Option<&str>,
    stored_resource: Option<&str>,
    base_url: &str,
) -> anyhow::Result<String> {
    let bound = bound_resource(stored_resource, base_url);
    match (flag_url, bound) {
        (Some(flag), Some(bound)) => {
            let url = flag.trim_end_matches('/').to_string();
            if url != bound {
                anyhow::bail!(
                    "the stored MCP pair is bound to {bound}. Run `fluxvale mcp login --resource {url}` to pair it with that server, or pass --url {bound}."
                );
            }
            Ok(url)
        }
        (Some(_), None) => anyhow::bail!(
            "cannot derive the MCP server URL from base URL {base_url}, so --url cannot be checked against the stored sign-in. Run `fluxvale mcp login --resource <URL>` for the MCP server you want, then run `fluxvale mcp serve` without --url."
        ),
        (None, Some(bound)) => Ok(bound),
        (None, None) => anyhow::bail!(
            "cannot derive the MCP server URL from base URL {base_url}. Run `fluxvale mcp login --resource <URL>`."
        ),
    }
}

/// Where the stored pair's token may go: the resource it was minted for
/// when `fluxvale mcp login` was given one, else the environment's own
/// MCP server. `None` when neither names one.
///
/// A login without `--resource` stores none, and the platform then binds
/// the pair to its default resource, which for the known environments is
/// exactly the URL derived here.
pub fn bound_resource(stored: Option<&str>, base_url: &str) -> Option<String> {
    stored
        .map(|resource| resource.trim_end_matches('/').to_string())
        .or_else(|| environment_url(base_url))
}

/// The MCP server that serves an environment, from the API's host, when
/// the environment is one this bridge knows.
fn environment_url(base_url: &str) -> Option<String> {
    let mcp_host = match config::host_from_base_url(base_url).as_str() {
        "fluxvale.com" => "mcp.fluxvale.com",
        "staging.fluxvale.com" => "mcp-staging.fluxvale.com",
        _ => return None,
    };
    Some(format!("https://{mcp_host}/mcp"))
}

/// One answered POST, however it was made. [`McpHttpClient`] is the real one.
pub trait McpTransport: Send + Sync + 'static {
    /// POST one JSON-RPC message with the access token as the bearer.
    fn post(
        &self,
        access_token: &Token,
        body: &str,
        protocol_version: Option<&str>,
    ) -> anyhow::Result<McpReply>;
}

impl McpTransport for McpHttpClient {
    fn post(
        &self,
        access_token: &Token,
        body: &str,
        protocol_version: Option<&str>,
    ) -> anyhow::Result<McpReply> {
        McpHttpClient::post(self, access_token, body, protocol_version)
    }
}

/// Where the stored pair is read and written. [`McpTokenStore`] is the real one.
pub trait McpPairStore: Send + Sync + 'static {
    /// The stored pair for `host`, when there is one.
    fn load(&self, host: &str) -> anyhow::Result<Option<McpCredentials>>;
    /// Replace the stored pair for `host`.
    fn save(&self, host: &str, pair: &McpCredentials) -> anyhow::Result<()>;
}

impl McpPairStore for McpTokenStore {
    fn load(&self, host: &str) -> anyhow::Result<Option<McpCredentials>> {
        Ok(McpTokenStore::load(self, host)?.map(|(pair, _)| pair))
    }

    fn save(&self, host: &str, pair: &McpCredentials) -> anyhow::Result<()> {
        McpTokenStore::save(self, host, pair)
    }
}

/// Whether a renewal holds the cross-process lock.
pub enum Held {
    /// The lock is held until this value is dropped.
    Locked(Box<dyn Send>),
    /// The lock could not be taken. The renewal goes ahead without it.
    Unavailable(String),
}

/// Held across one renewal, by every process that shares the stored pair.
pub trait RenewalLock: Send + Sync + 'static {
    /// An error means the wait ran out: this attempt failed and a later one may succeed.
    fn hold(&self) -> Result<Held, RefreshError>;
}

/// One lock file, taken around every renewal by each process that shares
/// the stored pair. Nothing is ever written to it and it is never
/// deleted: only the lock on it matters.
#[derive(Debug, Clone)]
pub struct FileRenewalLock {
    path: PathBuf,
    wait: Duration,
}

impl FileRenewalLock {
    /// The lock at `path`, waited on for [`RENEWAL_LOCK_WAIT`].
    pub fn new(path: impl Into<PathBuf>) -> Self {
        FileRenewalLock {
            path: path.into(),
            wait: RENEWAL_LOCK_WAIT,
        }
    }

    /// How long [`hold`](RenewalLock::hold) waits for another process to finish its renewal.
    pub fn with_wait(mut self, wait: Duration) -> Self {
        self.wait = wait;
        self
    }

    /// The lock file.
    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl RenewalLock for FileRenewalLock {
    fn hold(&self) -> Result<Held, RefreshError> {
        let file = match open_lock_file(&self.path) {
            Ok(file) => file,
            Err(why) => return Ok(Held::Unavailable(why.to_string())),
        };
        let waited_since = Instant::now();
        loop {
            match file.try_lock() {
                Ok(()) => return Ok(Held::Locked(Box::new(file))),
                Err(TryLockError::WouldBlock) => {}
                Err(TryLockError::Error(why)) => return Ok(Held::Unavailable(why.to_string())),
            }
            if waited_since.elapsed() >= self.wait {
                return Err(RefreshError::Transient(format!(
                    "another fluxvale process has held the renewal lock for {:?}",
                    self.wait
                )));
            }
            std::thread::sleep(RENEWAL_LOCK_POLL);
        }
    }
}

/// The lock file, created if it does not exist yet and never truncated,
/// since another process may be holding it.
fn open_lock_file(path: &Path) -> std::io::Result<File> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut options = OpenOptions::new();
    options.create(true).truncate(false).read(true).write(true);
    // Only this user has any business renewing this sign-in.
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o600);
    }
    options.open(path)
}

/// Runs the bridge and returns its exit code: 0 when stdin closed, 1
/// when the stored sign-in was missing or could no longer be renewed.
///
/// Everything the bridge touches is a parameter, so tests drive it
/// without a keychain or a network. `reader` is stdin, `writer` is
/// stdout, `err` receives whole stderr lines (newline included),
/// `connect` builds the transport for the resolved URL and may refuse
/// it, `store` holds the pair, `lock` is held around each renewal by
/// every process that shares the pair, `refresh` is the token endpoint,
/// `now` is the clock.
#[allow(clippy::too_many_arguments)]
pub fn serve<R, W, E, C, T, S, L, F, N>(
    flag_url: Option<&str>,
    base_url: &str,
    host: &str,
    reader: R,
    writer: W,
    err: E,
    connect: C,
    store: S,
    lock: L,
    refresh: F,
    now: N,
) -> anyhow::Result<i32>
where
    R: BufRead + Send + 'static,
    W: Write + Send + 'static,
    E: Fn(&str) + Send + Sync + 'static,
    C: FnOnce(&str) -> anyhow::Result<T>,
    T: McpTransport,
    S: McpPairStore,
    L: RenewalLock,
    F: Fn(&Token, Option<&str>) -> Result<OAuthTokenPair, RefreshError> + Send + Sync + 'static,
    N: Fn() -> u64 + Send + Sync + 'static,
{
    let err: Arc<ErrSink> = Arc::new(err);
    let now: Arc<Clock> = Arc::new(now);
    let Some(pair) = store.load(host)? else {
        err(&format!(
            "not signed in for MCP on {host}, run `fluxvale mcp login` first\n"
        ));
        return Ok(1);
    };
    let url = resolve_url(flag_url, pair.resource.as_deref(), base_url)?;
    let nearly_expired = pair.is_expired_within(now(), EXPIRY_LEEWAY_SECS);
    let (out, lines) = mpsc::channel();
    let bridge = Arc::new(Bridge {
        transport: Arc::new(connect(&url)?),
        store: Arc::new(store),
        lock: Arc::new(lock),
        refresh: Arc::new(refresh),
        now,
        err: err.clone(),
        host: host.to_owned(),
        url,
        base_url: base_url.to_owned(),
        current: RwLock::new(pair.clone()),
        negotiated: RwLock::new(None),
        renewal: Mutex::new(()),
        lost: Mutex::new(None),
        dead: AtomicBool::new(false),
        out,
    });
    // A token about to expire is renewed before anything is forwarded.
    if nearly_expired {
        match bridge.renew(&pair) {
            Ok(_) => {}
            // The sign-in is still good: say so and serve on. The first
            // request draws a 401 and tries again.
            Err(RefreshError::Transient(why)) => {
                err(&format!("{PREFIX}{RENEWAL_FAILED} yet: {why}\n"));
            }
            Err(RefreshError::Permanent(why)) => {
                err(&sign_in_lost(&why));
                return Ok(1);
            }
        }
    }

    let reading = {
        let bridge = bridge.clone();
        let mut reader = reader;
        std::thread::spawn(move || bridge.read_lines(&mut reader))
    };
    let writing = std::thread::spawn(move || write_lines(writer, lines));
    // This thread holds no sender: once the reader and its forwards are
    // done, the channel closes and the writer exits.
    drop(bridge);
    let written = writing
        .join()
        .map_err(|_| anyhow::anyhow!("the stdout writer panicked"))?;
    let Some(stderr) = written? else {
        reading
            .join()
            .map_err(|_| anyhow::anyhow!("the stdin reader panicked"))??;
        return Ok(0);
    };
    // The reader may still be blocked on stdin: the caller exits the process.
    err(&stderr);
    Ok(1)
}

/// What the reader and its forwards hand to the writer thread.
enum ToWriter {
    /// One protocol message, already JSON text.
    Line(String),
    /// The last message, then the line for stderr: the sign-in is lost.
    Fatal {
        line: Option<String>,
        stderr: String,
    },
}

/// The token endpoint's refresh call.
type Renew = dyn Fn(&Token, Option<&str>) -> Result<OAuthTokenPair, RefreshError> + Send + Sync;
/// The clock, in seconds since the Unix epoch.
type Clock = dyn Fn() -> u64 + Send + Sync;
/// Where whole stderr lines go.
type ErrSink = dyn Fn(&str) + Send + Sync;

/// The state the reader thread and every forward share.
struct Bridge {
    transport: Arc<dyn McpTransport>,
    store: Arc<dyn McpPairStore>,
    lock: Arc<dyn RenewalLock>,
    refresh: Arc<Renew>,
    now: Arc<Clock>,
    err: Arc<ErrSink>,
    host: String,
    /// The one server this bridge's token may go to.
    url: String,
    /// Where the environment's own MCP server is derived from.
    base_url: String,
    /// The pair new forwards start from. A renewal replaces it.
    current: RwLock<McpCredentials>,
    /// The protocol version an `initialize` answer negotiated.
    negotiated: RwLock<Option<String>>,
    /// Held across a renewal only, so two refusals at once in this
    /// process renew once.
    renewal: Mutex<()>,
    /// Why the sign-in was lost, once a renewal has failed for good.
    lost: Mutex<Option<String>>,
    /// Set once the sign-in is lost: nothing more is forwarded.
    dead: AtomicBool,
    out: Sender<ToWriter>,
}

impl Bridge {
    /// The reader thread: forwards each stdin line, and returns at end
    /// of input once every forward it started has finished.
    fn read_lines<R: BufRead>(&self, reader: &mut R) -> anyhow::Result<()> {
        let mut bytes = Vec::new();
        std::thread::scope(|forwards| {
            loop {
                bytes.clear();
                let read = reader
                    .read_until(b'\n', &mut bytes)
                    .map_err(|err| anyhow::anyhow!("could not read stdin: {err}"))?;
                if read == 0 || self.dead.load(Ordering::Relaxed) {
                    return Ok(());
                }
                let line = trim_newline(&bytes);
                if line.is_empty() || line.iter().all(u8::is_ascii_whitespace) {
                    continue;
                }
                let Some((line, message)) = parse_line(line) else {
                    self.emit(error_line(&Value::Null, PARSE_ERROR, "parse error"));
                    continue;
                };
                forwards.spawn(move || self.forward(&line, &message));
            }
        })
    }

    /// Forwards one message and hands the answers to the writer.
    fn forward(&self, line: &str, message: &Value) {
        let id = request_id(message);
        let version = self.header_version(message);
        let mut pair = self.pair();
        let mut renewed = false;
        let outcome = loop {
            let reply = match self
                .transport
                .post(&pair.access_token, line, version.as_deref())
            {
                Err(err) => break Outcome::Failed(err.to_string()),
                Ok(reply) => reply,
            };
            if reply.status == 401 {
                // One renewal per message. Refused again with a pair
                // that was just renewed: the pair is no good.
                if renewed {
                    break Outcome::SignedOut(String::from(RENEWED_TOKEN_REFUSED));
                }
                pair = match self.renew(&pair) {
                    Ok(pair) => pair,
                    // The sign-in is still good, only this attempt failed:
                    // answer this one request and stay up.
                    Err(RefreshError::Transient(why)) => {
                        break Outcome::Failed(format!("{RENEWAL_FAILED}: {why}"));
                    }
                    Err(RefreshError::Permanent(why)) => break Outcome::SignedOut(why),
                };
                renewed = true;
                continue;
            }
            // Only an `initialize` answer negotiates, and it is recorded
            // before the writer sees it, so the next POST can carry it.
            if method_is(message, "initialize") {
                self.negotiate(&reply.messages);
            }
            break answer_to(reply, id.is_some());
        };
        match (outcome, id) {
            (Outcome::Answered(messages), _) => {
                for message in messages {
                    self.emit(message.to_string());
                }
            }
            (Outcome::Failed(why), Some(id)) => self.emit(error_line(id, INTERNAL_ERROR, &why)),
            (Outcome::Failed(why), None) => {
                (self.err)(&format!("{PREFIX}dropped a message: {why}\n"));
            }
            (Outcome::SignedOut(lost), id) => self.sign_out(id, &lost),
        }
    }

    /// The pair new forwards start from.
    fn pair(&self) -> McpCredentials {
        self.current.read().unwrap_or_else(ignore_poison).clone()
    }

    /// The `MCP-Protocol-Version` header for one outgoing message.
    ///
    /// `initialize` carries none: the server refuses a header that
    /// differs from the body's `params.protocolVersion`, and no header at
    /// all is accepted.
    ///
    /// A message that states its own version under `params._meta` gets
    /// that one, whatever was negotiated: the server refuses a header
    /// that differs from it. Otherwise the version an `initialize`
    /// answer negotiated is sent, as long as it is below
    /// `2026-07-28`. From that version on the server requires `_meta` on
    /// any request whose header says so, and a bare message has none, so
    /// a negotiated `2026-07-28` or later is never sent on a message that
    /// does not state its own.
    fn header_version(&self, message: &Value) -> Option<String> {
        if method_is(message, "initialize") {
            return None;
        }
        if let Some(version) = meta_protocol_version(message) {
            return Some(version.to_owned());
        }
        let negotiated = self.negotiated.read().unwrap_or_else(ignore_poison);
        negotiated
            .as_deref()
            .filter(|version| *version < PER_REQUEST_META_FROM)
            .map(str::to_owned)
    }

    fn negotiate(&self, messages: &[Value]) {
        if let Some(version) = negotiated_version(messages) {
            *self.negotiated.write().unwrap_or_else(ignore_poison) = Some(version);
        }
    }

    /// Renews the pair a `401` refused, and returns the pair to retry
    /// with, which new forwards start from too.
    ///
    /// Only one renewal runs at a time, in this process and across
    /// processes. Refresh tokens rotate and the server treats a second
    /// use of one as theft, so a request refused with a pair another
    /// request has already renewed reuses that renewal instead of
    /// presenting the same refresh token again.
    ///
    /// The failure says whether the sign-in is still good. A token
    /// endpoint that could not be reached, or was not itself, refuses
    /// nothing, and so does a lock this renewal could not get in time. A
    /// refresh token it refused, a pair a logout removed, a pair a login
    /// minted for another server, and a renewed pair that could not be
    /// stored are gone for good: each is recorded while both locks are
    /// still held, so a request waiting on them never presents the
    /// refused token again.
    fn renew(&self, refused: &McpCredentials) -> Result<McpCredentials, RefreshError> {
        // Every process takes them in this order, so none waits on the other.
        let _one_at_a_time = self.renewal.lock().unwrap_or_else(ignore_poison);
        let _across_processes = match self.lock.hold() {
            Ok(Held::Locked(guard)) => Some(guard),
            Ok(Held::Unavailable(why)) => {
                // The lock is coordination against a rare race, not a
                // boundary: a machine where it cannot exist must still renew.
                (self.err)(&format!(
                    "{PREFIX}could not take the renewal lock ({why}), renewing without it\n"
                ));
                None
            }
            Err(waited_out) => return Err(waited_out),
        };
        if let Some(reason) = self.lost.lock().unwrap_or_else(ignore_poison).clone() {
            return Err(RefreshError::Permanent(reason));
        }
        let outcome = self.renew_holding(refused);
        if let Err(RefreshError::Permanent(reason)) = &outcome {
            *self.lost.lock().unwrap_or_else(ignore_poison) = Some(reason.clone());
            self.dead.store(true, Ordering::Relaxed);
        }
        outcome
    }

    /// The renewal itself, under both locks.
    fn renew_holding(&self, refused: &McpCredentials) -> Result<McpCredentials, RefreshError> {
        let stored = self
            .store
            .load(&self.host)
            .map_err(|err| RefreshError::Permanent(err.to_string()))?
            // Renewing from memory would put back what a logout removed.
            .ok_or_else(|| RefreshError::Permanent(String::from(SIGN_IN_REMOVED)))?;
        // The store is keyed by the API host alone, so a login for another
        // server puts a different pair there. Its token is not this
        // server's to have.
        let bound = bound_resource(stored.resource.as_deref(), &self.base_url);
        if bound.as_deref() != Some(self.url.as_str()) {
            return Err(RefreshError::Permanent(format!(
                "{SIGN_IN_MOVED} {}",
                bound.as_deref().unwrap_or("an unknown server")
            )));
        }
        let pair = if stored.refresh_token != refused.refresh_token {
            stored
        } else {
            let reply = (self.refresh)(&refused.refresh_token, refused.resource.as_deref())?;
            let pair = McpCredentials {
                access_token: reply.access_token,
                refresh_token: reply.refresh_token,
                expires_at_unix: (self.now)().saturating_add(reply.expires_in),
                scope: reply.scope,
                resource: refused.resource.clone(),
            };
            self.store
                .save(&self.host, &pair)
                .map_err(|err| RefreshError::Permanent(err.to_string()))?;
            pair
        };
        *self.current.write().unwrap_or_else(ignore_poison) = pair.clone();
        Ok(pair)
    }

    fn emit(&self, line: String) {
        let _ = self.out.send(ToWriter::Line(line));
    }

    /// The sign-in is lost: answer the request if there is one, tell
    /// stderr, and forward nothing more.
    fn sign_out(&self, id: Option<&Value>, lost: &str) {
        self.dead.store(true, Ordering::Relaxed);
        let line = id.map(|id| error_line(id, INTERNAL_ERROR, SIGN_IN_LOST));
        let _ = self.out.send(ToWriter::Fatal {
            line,
            stderr: sign_in_lost(lost),
        });
    }
}

/// How a reply that is not a `401` reads, for a request (`waits` is
/// true) or a notification.
///
/// Messages are the server's answer on any status: its own JSON-RPC
/// error on a 400 is a real answer. A `2xx` with none acknowledges a
/// notification and leaves a request waiting, so the request is told. Any
/// other status with none is not an answer at all.
fn answer_to(reply: McpReply, waits: bool) -> Outcome {
    let accepted = (200..300).contains(&reply.status);
    match (reply.messages.is_empty(), accepted, waits) {
        (false, _, _) => Outcome::Answered(reply.messages),
        (true, true, false) => Outcome::Answered(Vec::new()),
        (true, true, true) => Outcome::Failed(format!(
            "the MCP server answered HTTP {} with no JSON-RPC message",
            reply.status
        )),
        (true, false, _) => {
            Outcome::Failed(format!("the MCP server answered HTTP {}", reply.status))
        }
    }
}

/// How one forward ended.
enum Outcome {
    /// The server's messages, written as they came.
    Answered(Vec<Value>),
    /// No answer: the server could not be reached, or answered with nothing to pass on.
    Failed(String),
    /// The stored sign-in can no longer be renewed.
    SignedOut(String),
}

/// The writer thread, the only one that touches stdout: one message per
/// line, flushed. Returns the stderr line of a lost sign-in, when there was one.
fn write_lines<W: Write>(
    mut writer: W,
    messages: Receiver<ToWriter>,
) -> anyhow::Result<Option<String>> {
    let mut stderr = None;
    for message in messages {
        match message {
            ToWriter::Line(line) => write_line(&mut writer, &line)?,
            ToWriter::Fatal { line, stderr: lost } => {
                if let Some(line) = line {
                    write_line(&mut writer, &line)?;
                }
                stderr = Some(lost);
                break;
            }
        }
    }
    Ok(stderr)
}

/// A line, a newline, a flush. A closed pipe means the client is gone,
/// which is how every session ends, not an error.
fn write_line<W: Write>(writer: &mut W, line: &str) -> anyhow::Result<()> {
    match writeln!(writer, "{line}").and_then(|()| writer.flush()) {
        Err(err) if err.kind() == std::io::ErrorKind::BrokenPipe => Ok(()),
        written => written.map_err(Into::into),
    }
}

/// An error response the bridge writes itself.
fn error_line(id: &Value, code: i64, message: &str) -> String {
    let message = Value::String(message.to_owned());
    format!(r#"{{"jsonrpc":"2.0","id":{id},"error":{{"code":{code},"message":{message}}}}}"#)
}

fn sign_in_lost(lost: &str) -> String {
    format!("{PREFIX}MCP sign-in is no longer valid ({lost}). Run `fluxvale mcp login`.\n")
}

/// The id of a message that waits for an answer: an object with an
/// `id` and neither a `result` nor an `error`.
fn request_id(message: &Value) -> Option<&Value> {
    let object = message.as_object()?;
    match object.contains_key("result") || object.contains_key("error") {
        true => None,
        false => object.get("id"),
    }
}

/// Whether a message's `method` is `method`.
fn method_is(message: &Value, method: &str) -> bool {
    message.get("method").and_then(Value::as_str) == Some(method)
}

/// The protocol version a message states under `params._meta`.
fn meta_protocol_version(message: &Value) -> Option<&str> {
    message
        .get("params")?
        .get("_meta")?
        .get(META_PROTOCOL_VERSION)?
        .as_str()
}

/// The protocol version an answer negotiated: `result.protocolVersion`.
fn negotiated_version(messages: &[Value]) -> Option<String> {
    messages
        .iter()
        .find_map(|message| message.get("result")?.get("protocolVersion")?.as_str())
        .map(str::to_owned)
}

/// A line without its terminator: `\n`, or `\r\n` from a Windows client.
fn trim_newline(line: &[u8]) -> &[u8] {
    let line = line.strip_suffix(b"\n").unwrap_or(line);
    line.strip_suffix(b"\r").unwrap_or(line)
}

/// The message a line carries, as JSON text and parsed, or `None` when
/// the line is not one. The text is the line as it came, for the wire.
fn parse_line(line: &[u8]) -> Option<(String, Value)> {
    let text = std::str::from_utf8(line).ok()?;
    let message = serde_json::from_str(text).ok()?;
    Some((text.to_owned(), message))
}

/// A lock a panicking thread left behind still guards a whole value, so it is used as is.
fn ignore_poison<T>(poisoned: PoisonError<T>) -> T {
    poisoned.into_inner()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::collections::BTreeMap;
    use std::io;
    use std::sync::mpsc::RecvTimeoutError;
    use std::time::{Duration, Instant};

    const NOW: u64 = 1_700_000_000;
    const HOST: &str = "fluxvale.com";
    const BASE_URL: &str = "https://fluxvale.com";
    const MCP_URL: &str = "https://mcp.fluxvale.com/mcp";
    /// The version the mock `initialize` result negotiates.
    const PROTOCOL: &str = "2025-11-25";
    /// How long a test waits for the bridge before failing instead of hanging.
    const WAIT: Duration = Duration::from_secs(10);
    /// The token endpoint, not reached for a moment.
    const DIAL: &str = "connection failed: dial timeout";

    // Secrets with a shape a leak would show. Every test ends by proving none reached a byte of output.
    const ACCESS: &str = "fvoat_secret_access_token_never_leaked";
    const REFRESH: &str = "fvort_secret_refresh_token_never_leaked";
    const DEVICE_CODE: &str = "dc_secret_device_code_never_leaked_123456";
    const NEXT_ACCESS: &str = "fvoat_secret_next_access_token_never_leaked";
    const NEXT_REFRESH: &str = "fvort_secret_next_refresh_token_never_leaked";

    /// The stderr line that ends a bridge whose sign-in was lost.
    fn lost(why: &str) -> String {
        format!("fluxvale: MCP sign-in is no longer valid ({why}). Run `fluxvale mcp login`.\n")
    }

    /// The stdout line that ends a request whose sign-in was lost.
    fn lost_line(id: &Value) -> String {
        format!(
            r#"{{"jsonrpc":"2.0","id":{id},"error":{{"code":-32603,"message":"MCP sign-in is no longer valid. Run `fluxvale mcp login`."}}}}"#
        )
    }

    /// A request as a client writes it. A notification has no id.
    fn request(id: impl Into<Value>, method: &str) -> String {
        json!({"jsonrpc": "2.0", "id": id.into(), "method": method}).to_string()
    }

    fn notification(method: &str) -> String {
        json!({"jsonrpc": "2.0", "method": method}).to_string()
    }

    /// The answer the mock server gives a request: its own id and method back.
    fn answer(id: impl Into<Value>, method: &str) -> String {
        json!({"jsonrpc": "2.0", "id": id.into(), "result": {"method": method}}).to_string()
    }

    fn initialize() -> String {
        initialize_as(PROTOCOL)
    }

    /// An `initialize` request whose body asks for `version`.
    fn initialize_as(version: &str) -> String {
        json!({
            "jsonrpc": "2.0", "id": 0, "method": "initialize",
            "params": {"protocolVersion": version, "capabilities": {}, "clientInfo": {"name": "test", "version": "0"}}
        })
        .to_string()
    }

    /// A mock `initialize` result that negotiates `version`.
    fn initialize_result_negotiating(version: &str) -> Value {
        json!({
            "jsonrpc": "2.0", "id": 0,
            "result": {"protocolVersion": version, "capabilities": {"tools": {}}, "serverInfo": {"name": "fluxvale", "version": "0"}}
        })
    }

    fn initialize_result() -> Value {
        initialize_result_negotiating(PROTOCOL)
    }

    /// A request that states its protocol version the way the 2026-07-28 revision does.
    fn with_meta_version(id: impl Into<Value>, version: &str) -> String {
        json!({
            "jsonrpc": "2.0", "id": id.into(), "method": "tools/list",
            "params": {"_meta": {"io.modelcontextprotocol/protocolVersion": version}}
        })
        .to_string()
    }

    /// A pair as `fluxvale mcp login` stores it: valid for `expires_in` more seconds from [`NOW`].
    fn pair(
        access: &str,
        refresh: &str,
        expires_in: u64,
        resource: Option<&str>,
    ) -> McpCredentials {
        McpCredentials {
            access_token: Token::new(access),
            refresh_token: Token::new(refresh),
            expires_at_unix: NOW + expires_in,
            scope: "instances:read".to_string(),
            resource: resource.map(str::to_owned),
        }
    }

    /// The token endpoint's answer to a refresh.
    fn renewed() -> OAuthTokenPair {
        OAuthTokenPair {
            access_token: Token::new(NEXT_ACCESS),
            refresh_token: Token::new(NEXT_REFRESH),
            expires_in: 3600,
            scope: "instances:read wallet:read".to_string(),
        }
    }

    /// A refresh failure no later attempt can fix.
    fn permanent(why: &str) -> RefreshError {
        RefreshError::Permanent(why.to_string())
    }

    /// A refresh failure that passes: the token endpoint was not itself.
    fn blip(why: &str) -> RefreshError {
        RefreshError::Transient(why.to_string())
    }

    /// A renewal that hits a network blip once, then goes through.
    fn blip_then_renewed(_: &Seen, index: usize) -> Result<OAuthTokenPair, RefreshError> {
        match index {
            0 => Err(blip(DIAL)),
            _ => Ok(renewed()),
        }
    }

    /// A request's `-32603` answer when the server's reply was no answer.
    fn not_answered(id: impl Into<Value>, why: &str) -> String {
        error_line(&json!(id.into()), INTERNAL_ERROR, why)
    }

    /// How long a test lets a renewal wait for a lock another process holds.
    const HELD_FOR: Duration = Duration::from_millis(200);

    /// The gateway's own error, which is not a JSON-RPC message.
    const INSUFFICIENT_SCOPE: &str =
        r#"{"error":"insufficient_scope","error_description":"missing instances:read"}"#;
    /// A JSON:API error document, which is not one either.
    const UPSTREAM_DOWN: &str = r#"{"errors":[{"detail":"upstream down"}]}"#;

    /// A request's `-32603` answer when its renewal failed for a passing reason.
    fn not_renewed(id: &str, why: &str) -> String {
        error_line(
            &json!(id),
            INTERNAL_ERROR,
            &format!("{RENEWAL_FAILED}: {why}"),
        )
    }

    /// The tokens the mock transport was handed, in order.
    fn tokens(h: &Harness) -> Vec<Token> {
        h.posts()
            .iter()
            .map(|post| post.access_token.clone())
            .collect()
    }

    fn refused() -> McpReply {
        McpReply {
            status: 401,
            messages: Vec::new(),
        }
    }

    fn answered(messages: Vec<Value>) -> McpReply {
        McpReply {
            status: 200,
            messages,
        }
    }

    /// What the mock server answers a request: its own id and method back.
    fn echo(post: &Post) -> McpReply {
        answered(vec![json!({
            "jsonrpc": "2.0",
            "id": message(post)["id"],
            "result": {"method": method(post)}
        })])
    }

    fn message(post: &Post) -> Value {
        serde_json::from_str(&post.body).unwrap()
    }

    fn method(post: &Post) -> String {
        message(post)["method"].as_str().unwrap_or("").to_string()
    }

    /// One forwarded POST as the mock transport received it.
    #[derive(Clone, Debug, PartialEq, Eq)]
    struct Post {
        access_token: Token,
        body: String,
        protocol_version: Option<String>,
    }

    /// What one bridge did, shared with the threads it runs on.
    #[derive(Default)]
    struct Seen {
        stdout: Mutex<String>,
        stderr: Mutex<String>,
        /// `Debug` forms of the secrets the bridge handled.
        debug: Mutex<String>,
        /// Each URL `connect` was asked for, one per line.
        urls: Mutex<String>,
        posts: Mutex<Vec<Post>>,
        /// Refreshes and forwards in the order they started.
        events: Mutex<Vec<String>>,
    }

    fn push(into: &Mutex<String>, text: &str) {
        into.lock().unwrap().push_str(text);
    }

    /// Blocks until `condition` holds. False once `limit` passed, so a stuck bridge fails the test instead of hanging it.
    fn wait_up_to(limit: Duration, mut condition: impl FnMut() -> bool) -> bool {
        let deadline = Instant::now() + limit;
        while !condition() {
            if Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        true
    }

    /// How a test's script answers one forwarded POST.
    type Answer = dyn Fn(&Seen, &Post) -> Result<McpReply, String> + Send + Sync;
    /// How it answers one refresh call, counted from zero across every
    /// bridge that shares the token endpoint.
    type Renewal = dyn Fn(&Seen, usize) -> Result<OAuthTokenPair, RefreshError> + Send + Sync;

    /// The injected transport: every POST is recorded, then answered by the test's script.
    struct MockTransport {
        seen: Arc<Seen>,
        answer: Box<Answer>,
    }

    impl McpTransport for MockTransport {
        fn post(
            &self,
            access_token: &Token,
            body: &str,
            protocol_version: Option<&str>,
        ) -> anyhow::Result<McpReply> {
            let post = Post {
                access_token: access_token.clone(),
                body: body.to_owned(),
                protocol_version: protocol_version.map(str::to_owned),
            };
            // Recorded before the answer, so an answer can wait on what else has arrived.
            self.seen.posts.lock().unwrap().push(post.clone());
            self.seen.events.lock().unwrap().push("post".to_owned());
            (self.answer)(&self.seen, &post).map_err(anyhow::Error::msg)
        }
    }

    /// The pair store, in memory: one pair per host, readable while the
    /// bridge runs. A test can empty it, or make it refuse, from another thread.
    #[derive(Clone, Default)]
    struct MemoryStore {
        pairs: Arc<Mutex<BTreeMap<String, McpCredentials>>>,
        faults: Arc<Mutex<Faults>>,
    }

    /// What the store refuses next, one call each.
    #[derive(Default)]
    struct Faults {
        load: Vec<String>,
        save: Vec<String>,
    }

    impl McpPairStore for MemoryStore {
        fn load(&self, host: &str) -> anyhow::Result<Option<McpCredentials>> {
            if let Some(why) = self.faults.lock().unwrap().load.pop() {
                return Err(anyhow::Error::msg(why));
            }
            Ok(self.pairs.lock().unwrap().get(host).cloned())
        }

        fn save(&self, host: &str, pair: &McpCredentials) -> anyhow::Result<()> {
            if let Some(why) = self.faults.lock().unwrap().save.pop() {
                return Err(anyhow::Error::msg(why));
            }
            self.pairs
                .lock()
                .unwrap()
                .insert(host.to_owned(), pair.clone());
            Ok(())
        }
    }

    /// What bridges that share a sign-in share, as two processes would:
    /// one store, one token endpoint, one lock file. Shared the way
    /// [`Seen`] is, through an `Arc` every bridge holds.
    struct World {
        host: &'static str,
        store: MemoryStore,
        endpoint: Mutex<Endpoint>,
        /// The directory the lock file lives in. Removed when the last
        /// bridge sharing the world is gone.
        dir: PathBuf,
        lock: PathBuf,
        lock_wait: Duration,
    }

    /// The token endpoint as a test scripts it: one script, and every
    /// call every bridge sharing it has made.
    struct Endpoint {
        script: Arc<Renewal>,
        calls: Vec<(Token, Option<String>)>,
    }

    impl World {
        /// A sign-in stored for `host`, renewed by `script`, renewed
        /// under a lock file of its own in a temp directory.
        fn new(host: &'static str, stored: Option<McpCredentials>, script: Box<Renewal>) -> Self {
            let dir = temp_dir();
            let world = World {
                host,
                store: MemoryStore::default(),
                endpoint: Mutex::new(Endpoint {
                    script: script.into(),
                    calls: Vec::new(),
                }),
                lock: dir.join("mcp-renewal.lock"),
                dir,
                lock_wait: RENEWAL_LOCK_WAIT,
            };
            if let Some(pair) = &stored {
                world.store.save(host, pair).unwrap();
            }
            world
        }

        /// How long a renewal of this sign-in waits for the lock file.
        fn with_lock_wait(mut self, wait: Duration) -> Self {
            self.lock_wait = wait;
            self
        }

        /// Where the lock file is, instead of in its own temp directory.
        fn with_lock_path(mut self, path: PathBuf) -> Self {
            self.lock = path;
            self
        }

        /// The lock every renewal of this sign-in goes through.
        fn renewal_lock(&self) -> FileRenewalLock {
            FileRenewalLock::new(self.lock.clone()).with_wait(self.lock_wait)
        }

        /// The token endpoint: it records the call, then answers it with
        /// the script. The script sees the calling bridge's own activity,
        /// so it can wait on that.
        fn refresh(
            &self,
            seen: &Seen,
            token: &Token,
            resource: Option<&str>,
        ) -> Result<OAuthTokenPair, RefreshError> {
            let (script, index) = {
                let mut endpoint = self.endpoint.lock().unwrap();
                let index = endpoint.calls.len();
                endpoint
                    .calls
                    .push((token.clone(), resource.map(str::to_owned)));
                (endpoint.script.clone(), index)
            };
            seen.events.lock().unwrap().push("refresh".to_owned());
            let outcome = script(seen, index);
            // Whatever came back is kept in its Debug form for the secrets check: a failure's text reaches stderr.
            match &outcome {
                Ok(renewed) => push(&seen.debug, &format!("{renewed:?} ")),
                Err(failure) => push(&seen.debug, &format!("{failure:?} ")),
            }
            outcome
        }

        /// Every refresh call the endpoint has had, across every bridge
        /// that shares it.
        fn refreshes(&self) -> Vec<(Token, Option<String>)> {
            self.endpoint.lock().unwrap().calls.clone()
        }
    }

    impl Drop for World {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    /// stdin's stand-in: each line the test sends becomes readable in turn. A dropped sender is end of input.
    struct ClientStdin {
        lines: Receiver<Vec<u8>>,
        pending: Vec<u8>,
    }

    impl io::Read for ClientStdin {
        fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
            if self.pending.is_empty() {
                match self.lines.recv_timeout(WAIT) {
                    Ok(line) => self.pending = line,
                    Err(RecvTimeoutError::Disconnected) => return Ok(0),
                    Err(RecvTimeoutError::Timeout) => {
                        return Err(io::Error::new(
                            io::ErrorKind::TimedOut,
                            "the test client went quiet",
                        ));
                    }
                }
            }
            let length = self.pending.len().min(out.len());
            out[..length].copy_from_slice(&self.pending[..length]);
            self.pending.drain(..length);
            Ok(length)
        }
    }

    /// stdout's stand-in: everything the bridge writes, kept for the assertions.
    struct ClientStdout(Arc<Seen>);

    impl Write for ClientStdout {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            let text = std::str::from_utf8(buf).expect("the bridge writes UTF-8");
            push(&self.0.stdout, text);
            Ok(buf.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    /// A loopback HTTP server with scripted answers, for a bridge whose
    /// transport is the real client. One answer per request, in order.
    struct Wire {
        base_url: String,
        /// Every request the server saw, head and body, as it arrived.
        requests: Arc<Mutex<Vec<String>>>,
    }

    fn wire(responses: Vec<String>) -> Wire {
        use std::io::Read as _;

        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let captured = requests.clone();
        std::thread::spawn(move || {
            for response in responses {
                let Ok((mut stream, _)) = listener.accept() else {
                    break;
                };
                let mut raw = Vec::new();
                let mut buf = [0u8; 8192];
                while let Ok(read) = stream.read(&mut buf) {
                    if read == 0 {
                        break;
                    }
                    raw.extend_from_slice(&buf[..read]);
                    let head_end = raw.windows(4).position(|w| w == b"\r\n\r\n");
                    if let Some(end) = head_end {
                        let length = String::from_utf8_lossy(&raw[..end])
                            .to_ascii_lowercase()
                            .lines()
                            .find_map(|line| line.strip_prefix("content-length: "))
                            .and_then(|value| value.trim().parse::<usize>().ok())
                            .unwrap_or(0);
                        if raw.len() >= end + 4 + length {
                            break;
                        }
                    }
                }
                captured
                    .lock()
                    .unwrap()
                    .push(String::from_utf8_lossy(&raw).into_owned());
                let _ = stream.write_all(response.as_bytes());
                let _ = stream.flush();
            }
        });
        Wire {
            base_url: format!("http://{addr}"),
            requests,
        }
    }

    /// A whole HTTP answer: the status line, the content type, the body.
    fn http(status: &str, content_type: &str, body: &str) -> String {
        format!(
            "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
    }

    /// The transport a started bridge ended up with.
    type Connected = Arc<dyn McpTransport>;
    /// What a started bridge builds its transport with.
    type Connecting = Box<dyn FnOnce(&str) -> anyhow::Result<Connected> + Send>;

    /// The real client is the transport wherever any other transport is.
    impl McpTransport for Arc<dyn McpTransport> {
        fn post(
            &self,
            access_token: &Token,
            body: &str,
            protocol_version: Option<&str>,
        ) -> anyhow::Result<McpReply> {
            (**self).post(access_token, body, protocol_version)
        }
    }

    /// What a test gives the bridge before it starts.
    struct Script {
        /// The sign-in this bridge shares, with its store, its token
        /// endpoint and its lock file. `None` builds one from `stored`
        /// and `renew`, which are then the only ones read.
        world: Option<Arc<World>>,
        /// The pair already stored for `host`.
        stored: Option<McpCredentials>,
        host: &'static str,
        base_url: &'static str,
        flag_url: Option<&'static str>,
        /// Everything the client writes up front, one line each, after
        /// which its stdin closes. `None` leaves the test to write line
        /// by line.
        input: Option<String>,
        /// Answers each forwarded POST.
        answer: Box<Answer>,
        /// Answers each refresh call.
        renew: Box<Renewal>,
        /// Whole HTTP answers from a loopback server, for a bridge whose
        /// transport is the real client. `None` uses the mock transport.
        wire: Option<Vec<String>>,
    }

    /// The plain setup: a healthy pair for `fluxvale.com`, every POST
    /// answered, every refresh granted. The stored pair lives two hours
    /// and a renewal one, so the two expiries are never mistaken.
    fn script() -> Script {
        Script {
            world: None,
            stored: Some(pair(ACCESS, REFRESH, 7200, Some(MCP_URL))),
            host: HOST,
            base_url: BASE_URL,
            flag_url: None,
            input: None,
            answer: Box::new(|_, post| Ok(echo(post))),
            renew: Box::new(|_, _| Ok(renewed())),
            wire: None,
        }
    }

    /// The plain setup as a world, for a test that keeps a handle on the
    /// store or on the lock file before the bridge starts.
    fn plain_world() -> World {
        let plain = script();
        World::new(plain.host, plain.stored, plain.renew)
    }

    fn world() -> Arc<World> {
        Arc::new(plain_world())
    }

    /// Refuses the stored access token and answers the renewed one, as a
    /// server does while the pair is stale.
    fn refuse_old() -> Box<Answer> {
        Box::new(|_, post| {
            if post.access_token == Token::new(ACCESS) {
                Ok(refused())
            } else {
                Ok(echo(post))
            }
        })
    }

    /// A bridge running on its own thread, driven the way a client would.
    struct Harness {
        seen: Arc<Seen>,
        world: Arc<World>,
        /// The loopback server, when the bridge runs on the real client.
        wire: Option<Arc<Wire>>,
        stdin: Option<Sender<Vec<u8>>>,
        bridge: Option<std::thread::JoinHandle<anyhow::Result<i32>>>,
    }

    fn start(script: Script) -> Harness {
        let seen = Arc::new(Seen::default());
        let world = script
            .world
            .unwrap_or_else(|| Arc::new(World::new(script.host, script.stored, script.renew)));
        let (stdin, lines) = mpsc::channel::<Vec<u8>>();
        let preset = script.input.is_some();
        for line in script.input.unwrap_or_default().lines() {
            stdin.send(format!("{line}\n").into_bytes()).unwrap();
        }
        let stdin = if preset { None } else { Some(stdin) };

        let transport = MockTransport {
            seen: seen.clone(),
            answer: script.answer,
        };
        let on_wire = script.wire.map(|responses| Arc::new(wire(responses)));
        let connect: Connecting = match on_wire.clone() {
            Some(server) => {
                let url = format!("{}/mcp", server.base_url);
                Box::new(move |_| Ok(Arc::new(McpHttpClient::new(&url)?)))
            }
            None => Box::new(move |_| Ok(Arc::new(transport))),
        };
        let renew = {
            let seen = seen.clone();
            let world = world.clone();
            move |token: &Token, resource: Option<&str>| world.refresh(&seen, token, resource)
        };
        let (host, base_url, flag_url) = (script.host, script.base_url, script.flag_url);
        let store = world.store.clone();
        // The real lock, on a file of this world's own.
        let lock = world.renewal_lock();

        let written = seen.clone();
        let urls = seen.clone();
        let stderr = seen.clone();
        let bridge = std::thread::spawn(move || {
            serve(
                flag_url,
                base_url,
                host,
                io::BufReader::new(ClientStdin {
                    lines,
                    pending: Vec::new(),
                }),
                ClientStdout(written),
                move |line| push(&stderr.stderr, line),
                move |url: &str| {
                    push(&urls.urls, &format!("{url}\n"));
                    connect(url)
                },
                store,
                lock,
                renew,
                || NOW,
            )
        });
        Harness {
            seen,
            world,
            wire: on_wire,
            stdin,
            bridge: Some(bridge),
        }
    }

    impl Harness {
        /// The client writes one line.
        fn send(&self, line: &str) {
            self.stdin
                .as_ref()
                .expect("this script writes line by line")
                .send(format!("{line}\n").into_bytes())
                .expect("the bridge is still reading");
        }

        /// The client writes these bytes, as they are.
        fn send_bytes(&self, bytes: &[u8]) {
            self.stdin
                .as_ref()
                .expect("this script writes line by line")
                .send(bytes.to_vec())
                .expect("the bridge is still reading");
        }

        /// The client closes its end.
        fn close_stdin(&mut self) {
            self.stdin.take();
        }

        /// Waits for the bridge to exit by itself.
        fn exit(&mut self) -> anyhow::Result<i32> {
            let bridge = self.bridge.take().expect("the bridge runs once");
            assert!(
                wait_up_to(WAIT, || bridge.is_finished()),
                "the bridge did not exit"
            );
            bridge.join().unwrap()
        }

        fn exit_code(&mut self) -> i32 {
            self.exit().expect("the bridge ended without an error")
        }

        /// Closes stdin, then waits for the exit code.
        fn finish(&mut self) -> i32 {
            self.close_stdin();
            self.exit_code()
        }

        fn stdout_lines(&self) -> Vec<String> {
            self.seen
                .stdout
                .lock()
                .unwrap()
                .lines()
                .map(str::to_owned)
                .collect()
        }

        /// Waits until stdout holds `count` lines.
        fn stdout_after(&self, count: usize) -> Vec<String> {
            assert!(
                wait_up_to(WAIT, || self.stdout_lines().len() >= count),
                "stdout never reached {count} lines, got {:?}",
                self.stdout_lines()
            );
            self.stdout_lines()
        }

        /// Waits until stderr holds `count` lines.
        fn stderr_after(&self, count: usize) -> String {
            assert!(
                wait_up_to(WAIT, || self.stderr().lines().count() >= count),
                "stderr never reached {count} lines, got {:?}",
                self.stderr()
            );
            self.stderr()
        }

        fn stderr(&self) -> String {
            self.seen.stderr.lock().unwrap().clone()
        }

        /// The URLs the bridge asked a transport for, in order.
        fn urls(&self) -> Vec<String> {
            self.seen
                .urls
                .lock()
                .unwrap()
                .lines()
                .map(str::to_owned)
                .collect()
        }

        fn posts(&self) -> Vec<Post> {
            self.seen.posts.lock().unwrap().clone()
        }

        /// Every request the loopback server saw, when the bridge runs on
        /// the real client: the head and body of each, as it arrived.
        fn wire_requests(&self) -> Vec<String> {
            self.wire
                .as_ref()
                .map(|server| server.requests.lock().unwrap().clone())
                .unwrap_or_default()
        }

        /// Every refresh call the token endpoint has had, from this
        /// bridge and from any other sharing its world.
        fn refreshes(&self) -> Vec<(Token, Option<String>)> {
            self.world.refreshes()
        }

        fn events(&self) -> Vec<String> {
            self.seen.events.lock().unwrap().clone()
        }

        fn stored(&self) -> Option<McpCredentials> {
            self.world.store.stored(self.world.host)
        }

        /// No byte the bridge wrote, and no `Debug` form of what it
        /// handled, carries a token or a device code.
        fn assert_no_secrets(&self) {
            let stdout = self.stdout_lines().join("\n");
            let stderr = self.stderr();
            let debug = self.seen.debug.lock().unwrap().clone();
            for secret in [ACCESS, REFRESH, NEXT_ACCESS, NEXT_REFRESH, DEVICE_CODE] {
                assert!(!stdout.contains(secret), "stdout leaked a secret: {stdout}");
                assert!(!stderr.contains(secret), "stderr leaked a secret: {stderr}");
                assert!(
                    !debug.contains(secret),
                    "Debug output leaked a secret: {debug}"
                );
            }
        }
    }

    impl MemoryStore {
        /// `fluxvale mcp logout`, from another terminal.
        fn remove(&self, host: &str) {
            self.pairs.lock().unwrap().remove(host);
        }

        /// The next load fails with `why`, and the pair is left alone.
        fn fail_load(&self, why: &str) {
            self.faults.lock().unwrap().load.push(why.to_owned());
        }

        /// The next save fails with `why`.
        fn fail_save(&self, why: &str) {
            self.faults.lock().unwrap().save.push(why.to_owned());
        }

        fn stored(&self, host: &str) -> Option<McpCredentials> {
            self.pairs.lock().unwrap().get(host).cloned()
        }
    }

    /// A temp directory of this test run's own, as the `mcp` tests make theirs.
    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "fluxvale-cli-mcp-serve-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// Holds the lock file the way another process would, until the file
    /// returned is dropped. Nothing holds it when this is called.
    fn hold_elsewhere(path: &Path) -> File {
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(path)
            .unwrap();
        file.lock().unwrap();
        file
    }

    #[test]
    fn initialize_then_initialized_then_tools_list() {
        let mut h = start(Script {
            answer: Box::new(|_, post| {
                Ok(match method(post).as_str() {
                    "initialize" => answered(vec![initialize_result()]),
                    "notifications/initialized" => McpReply {
                        status: 202,
                        messages: Vec::new(),
                    },
                    _ => echo(post),
                })
            }),
            ..script()
        });

        // A client waits for the initialize result before it goes on.
        let initialize = initialize();
        h.send(&initialize);
        assert_eq!(h.stdout_after(1), vec![initialize_result().to_string()]);
        let initialized = notification("notifications/initialized");
        h.send(&initialized);
        // ...and for the notification to be off its hands before the next request.
        assert!(
            wait_up_to(WAIT, || h.posts().len() == 2),
            "the notification was never forwarded"
        );
        let tools = request("tools", "tools/list");
        h.send(&tools);

        assert_eq!(
            h.stdout_after(2),
            vec![
                initialize_result().to_string(),
                answer("tools", "tools/list")
            ]
        );
        assert_eq!(h.finish(), 0);

        let posts = h.posts();
        assert_eq!(
            posts
                .iter()
                .map(|post| post.body.as_str())
                .collect::<Vec<_>>(),
            vec![initialize.as_str(), initialized.as_str(), tools.as_str()],
            "three messages in, three POSTs out, in order and byte for byte"
        );
        for post in &posts {
            assert_eq!(
                post.access_token,
                Token::new(ACCESS),
                "every POST carries the access token"
            );
        }
        assert_eq!(
            posts[0].protocol_version, None,
            "initialize carries no version header"
        );
        assert_eq!(posts[1].protocol_version.as_deref(), Some(PROTOCOL));
        assert_eq!(posts[2].protocol_version.as_deref(), Some(PROTOCOL));
        assert_eq!(h.urls(), vec![MCP_URL]);
        assert!(h.refreshes().is_empty(), "a healthy pair is not renewed");
        assert_eq!(h.stderr(), "", "the happy path writes nothing to stderr");
        h.assert_no_secrets();
    }

    #[test]
    fn a_401_renews_once_and_the_retry_carries_the_new_token() {
        let refused_token = Token::new(ACCESS);
        let mut h = start(Script {
            answer: Box::new(move |_, post| {
                if post.access_token == refused_token {
                    Ok(refused())
                } else {
                    Ok(echo(post))
                }
            }),
            ..script()
        });

        let tools = request("tools", "tools/list");
        h.send(&tools);
        assert_eq!(h.stdout_after(1), vec![answer("tools", "tools/list")]);

        // A request that comes after the renewal starts from the renewed pair: no second refusal.
        let later = request(9, "resources/list");
        h.send(&later);
        assert_eq!(
            h.stdout_after(2),
            vec![answer("tools", "tools/list"), answer(9, "resources/list")]
        );
        assert_eq!(h.finish(), 0);

        let posts = h.posts();
        let tokens: Vec<Token> = posts.iter().map(|post| post.access_token.clone()).collect();
        assert_eq!(
            tokens,
            vec![
                Token::new(ACCESS),
                Token::new(NEXT_ACCESS),
                Token::new(NEXT_ACCESS)
            ],
            "refused with the stored token, retried and continued with the renewed one"
        );
        assert_eq!(posts[1].body, tools, "the retry is the same message");
        assert_eq!(
            h.refreshes(),
            vec![(Token::new(REFRESH), Some(MCP_URL.to_string()))],
            "exactly one refresh, with the stored refresh token and the pair's resource"
        );
        assert_eq!(h.events(), ["post", "refresh", "post", "post"]);
        let stored = h.stored().expect("the pair is still stored");
        assert_eq!(stored.access_token, Token::new(NEXT_ACCESS));
        assert_eq!(stored.refresh_token, Token::new(NEXT_REFRESH));
        assert_eq!(stored.expires_at_unix, NOW + 3600, "the new expiry");
        assert_eq!(
            stored.scope, "instances:read wallet:read",
            "the scope the server answered"
        );
        assert_eq!(
            stored.resource.as_deref(),
            Some(MCP_URL),
            "the resource is unchanged"
        );
        assert_eq!(h.stderr(), "");
        h.assert_no_secrets();
    }

    #[test]
    fn two_requests_refused_together_renew_once() {
        let a = request("a", "tools/list");
        let b = request("b", "resources/list");
        let mut h = start(Script {
            input: Some(format!("{a}\n{b}\n")),
            answer: Box::new(|_, post| {
                if post.access_token == Token::new(ACCESS) {
                    Ok(refused())
                } else {
                    Ok(echo(post))
                }
            }),
            renew: Box::new(|seen, index| {
                // The first renewal waits until the second request has drawn its refusal too. Only the single-flight keeps a second refresh from following.
                if index == 0 && !wait_up_to(WAIT, || seen.posts.lock().unwrap().len() >= 2) {
                    return Err(permanent("the second request never drew its refusal"));
                }
                Ok(renewed())
            }),
            ..script()
        });

        assert_eq!(h.exit_code(), 0);
        let mut lines = h.stdout_lines();
        lines.sort();
        assert_eq!(
            lines,
            vec![answer("a", "tools/list"), answer("b", "resources/list")]
        );

        let posts = h.posts();
        assert_eq!(posts.len(), 4, "each request: one refusal, one retry");
        let refused = posts
            .iter()
            .filter(|post| post.access_token == Token::new(ACCESS))
            .count();
        let retried = posts
            .iter()
            .filter(|post| post.access_token == Token::new(NEXT_ACCESS))
            .count();
        assert_eq!(
            (refused, retried),
            (2, 2),
            "both retries carry the new access token"
        );
        assert_eq!(h.refreshes().len(), 1, "exactly one refresh call");
        assert_eq!(
            h.refreshes()[0],
            (Token::new(REFRESH), Some(MCP_URL.to_string()))
        );
        assert_eq!(h.stored().unwrap().access_token, Token::new(NEXT_ACCESS));
        assert_eq!(h.stderr(), "");
        h.assert_no_secrets();
    }

    #[test]
    fn a_pair_near_its_expiry_is_renewed_before_the_first_forward() {
        let tools = request("tools", "tools/list");
        let mut h = start(Script {
            input: Some(format!("{tools}\n")),
            // Thirty seconds left: inside the minute of leeway.
            stored: Some(pair(ACCESS, REFRESH, 30, Some(MCP_URL))),
            answer: Box::new(|_, post| {
                if post.access_token != Token::new(NEXT_ACCESS) {
                    return Err("a nearly expired token reached the server".to_string());
                }
                Ok(echo(post))
            }),
            ..script()
        });

        assert_eq!(h.exit_code(), 0);
        assert_eq!(h.refreshes().len(), 1);
        assert_eq!(
            h.events(),
            vec!["refresh", "post"],
            "renewed first, forwarded second"
        );
        assert_eq!(h.posts()[0].access_token, Token::new(NEXT_ACCESS));
        assert_eq!(h.stdout_lines(), vec![answer("tools", "tools/list")]);
        let stored = h.stored().unwrap();
        assert_eq!(
            stored.expires_at_unix,
            NOW + 3600,
            "the renewed expiry is stored"
        );
        assert_eq!(stored.access_token, Token::new(NEXT_ACCESS));
        h.assert_no_secrets();
    }

    #[test]
    fn a_failed_renewal_ends_the_bridge_and_forwards_nothing_more() {
        let mut h = start(Script {
            answer: Box::new(|_, _| Ok(refused())),
            renew: Box::new(|_, _| Err(permanent("invalid_grant: refresh token revoked"))),
            ..script()
        });

        h.send(&request(7, "tools/list"));

        assert_eq!(h.exit_code(), 1);
        assert_eq!(h.stdout_lines(), vec![lost_line(&json!(7))]);
        assert_eq!(h.stderr(), lost("invalid_grant: refresh token revoked"));
        assert_eq!(h.refreshes().len(), 1);

        // A client that keeps talking after the error: nothing more leaves the bridge.
        h.send(&request(8, "tools/list"));
        assert!(
            !wait_up_to(Duration::from_millis(300), || h.posts().len() > 1),
            "a message was forwarded after the sign-in was lost"
        );
        assert_eq!(h.stdout_lines().len(), 1);
        assert_eq!(h.refreshes().len(), 1);
        h.assert_no_secrets();
    }

    #[test]
    fn a_failed_startup_renewal_ends_the_bridge_before_any_forward() {
        // The client's line is already waiting. The bridge must end before it reads a byte of it.
        let mut h = start(Script {
            stored: Some(pair(ACCESS, REFRESH, 30, Some(MCP_URL))),
            input: Some(format!("{}\n", request(5, "tools/list"))),
            renew: Box::new(|_, _| Err(permanent("invalid_grant: refresh token revoked"))),
            ..script()
        });

        assert_eq!(h.exit_code(), 1);
        assert!(h.stdout_lines().is_empty(), "no request was ever forwarded");
        assert_eq!(h.stderr(), lost("invalid_grant: refresh token revoked"));
        assert!(h.posts().is_empty());
        assert_eq!(h.refreshes().len(), 1);
        h.assert_no_secrets();
    }

    #[test]
    fn a_transient_renewal_failure_answers_the_request_and_the_bridge_stays_alive() {
        let refused_token = Token::new(ACCESS);
        let mut h = start(Script {
            answer: Box::new(move |_, post| {
                if post.access_token == refused_token {
                    Ok(refused())
                } else {
                    Ok(echo(post))
                }
            }),
            renew: Box::new(blip_then_renewed),
            ..script()
        });

        // The first request's renewal hits the blip. The request carries it, the bridge does not.
        h.send(&request("a", "tools/list"));
        assert_eq!(h.stdout_after(1), vec![not_renewed("a", DIAL)]);

        // The second request draws its 401 too, and this time the renewal goes through.
        let second = request("b", "resources/list");
        h.send(&second);
        assert_eq!(
            h.stdout_after(2),
            vec![not_renewed("a", DIAL), answer("b", "resources/list")]
        );
        assert_eq!(h.finish(), 0);

        assert_eq!(
            h.stderr(),
            "",
            "a passing failure is the request's to carry"
        );
        assert_eq!(
            tokens(&h),
            vec![
                Token::new(ACCESS),
                Token::new(ACCESS),
                Token::new(NEXT_ACCESS)
            ],
            "the first request was not retried, the second was, with the renewed token"
        );
        assert_eq!(h.posts()[2].body, second, "the retry is the second request");
        assert_eq!(h.refreshes().len(), 2);
        assert_eq!(h.stored().unwrap().access_token, Token::new(NEXT_ACCESS));
        h.assert_no_secrets();
    }

    #[test]
    fn a_transient_renewal_failure_for_a_notification_is_dropped_and_the_bridge_stays_alive() {
        let refused_token = Token::new(ACCESS);
        let mut h = start(Script {
            answer: Box::new(move |_, post| {
                if post.access_token == refused_token {
                    Ok(refused())
                } else {
                    Ok(McpReply {
                        status: 202,
                        messages: Vec::new(),
                    })
                }
            }),
            renew: Box::new(blip_then_renewed),
            ..script()
        });

        // The first notification's renewal hits the blip, and the notification is dropped.
        h.send(&notification("notifications/progress"));
        assert!(
            wait_up_to(WAIT, || h.stderr().lines().count() == 1),
            "stderr: {:?}",
            h.stderr()
        );

        // The bridge is still up: the next one is renewed and acknowledged.
        h.send(&notification("notifications/cancelled"));
        assert!(
            wait_up_to(WAIT, || h.posts().len() == 3),
            "posts: {}",
            h.posts().len()
        );
        assert_eq!(h.finish(), 0);

        assert!(
            h.stdout_lines().is_empty(),
            "a notification gets no answer, renewed or not"
        );
        assert_eq!(
            h.stderr(),
            format!("fluxvale: dropped a message: {RENEWAL_FAILED}: {DIAL}\n")
        );
        assert_eq!(
            tokens(&h),
            vec![
                Token::new(ACCESS),
                Token::new(ACCESS),
                Token::new(NEXT_ACCESS)
            ]
        );
        assert_eq!(h.refreshes().len(), 2);
        h.assert_no_secrets();
    }

    #[test]
    fn a_transient_renewal_failure_at_startup_is_reported_and_the_bridge_serves_on() {
        let refused_token = Token::new(ACCESS);
        let mut h = start(Script {
            // Thirty seconds left: inside the minute of leeway, so the
            // renewal runs before the first forward.
            stored: Some(pair(ACCESS, REFRESH, 30, Some(MCP_URL))),
            answer: Box::new(move |_, post| {
                if post.access_token == refused_token {
                    Ok(refused())
                } else {
                    Ok(echo(post))
                }
            }),
            renew: Box::new(blip_then_renewed),
            ..script()
        });

        // The renewal runs before anything is read, fails, and is reported.
        assert!(
            wait_up_to(WAIT, || h.refreshes().len() == 1
                && h.stderr().lines().count() == 1),
            "stderr: {:?}",
            h.stderr()
        );
        assert_eq!(
            h.stderr(),
            format!("fluxvale: {RENEWAL_FAILED} yet: {DIAL}\n")
        );
        assert!(h.posts().is_empty(), "nothing was forwarded yet");

        // The first request draws its 401, and the second renewal goes through.
        h.send(&request("tools", "tools/list"));
        assert_eq!(h.stdout_after(1), vec![answer("tools", "tools/list")]);
        assert_eq!(h.finish(), 0);

        assert_eq!(
            h.stderr(),
            format!("fluxvale: {RENEWAL_FAILED} yet: {DIAL}\n"),
            "exactly that one line, before and after"
        );
        assert_eq!(
            tokens(&h),
            vec![Token::new(ACCESS), Token::new(NEXT_ACCESS)]
        );
        assert_eq!(h.events(), ["refresh", "post", "refresh", "post"]);
        assert_eq!(h.stored().unwrap().access_token, Token::new(NEXT_ACCESS));
        h.assert_no_secrets();
    }

    #[test]
    fn a_pair_removed_by_a_logout_is_a_lost_sign_in() {
        let world = world();
        let sabotage = world.store.clone();
        let mut h = start(Script {
            world: Some(world),
            input: Some(format!("{}\n", request("gone", "tools/list"))),
            // The logout lands while the request is in flight.
            answer: Box::new(move |_, _| {
                sabotage.remove(HOST);
                Ok(refused())
            }),
            ..script()
        });

        assert_eq!(h.exit_code(), 1);
        assert_eq!(h.stdout_lines(), vec![lost_line(&json!("gone"))]);
        assert_eq!(h.stderr(), lost("the stored sign-in was removed"));
        assert!(
            h.refreshes().is_empty(),
            "a removed pair is not refreshed from memory"
        );
        assert_eq!(h.stored(), None, "and nothing is stored in its place");
        h.assert_no_secrets();
    }

    #[test]
    fn a_pair_store_that_cannot_be_read_is_a_lost_sign_in() {
        let world = world();
        let sabotage = world.store.clone();
        let mut h = start(Script {
            world: Some(world),
            input: Some(format!("{}\n", request("locked", "tools/list"))),
            answer: Box::new(move |_, _| {
                sabotage.fail_load("the OS keychain is locked");
                Ok(refused())
            }),
            ..script()
        });

        assert_eq!(h.exit_code(), 1);
        assert_eq!(h.stdout_lines(), vec![lost_line(&json!("locked"))]);
        assert_eq!(h.stderr(), lost("the OS keychain is locked"));
        assert!(h.refreshes().is_empty(), "nothing is refreshed on a guess");
        assert_eq!(
            h.stored().unwrap().access_token,
            Token::new(ACCESS),
            "the pair is left alone"
        );
        h.assert_no_secrets();
    }

    #[test]
    fn a_renewed_pair_that_cannot_be_stored_is_a_lost_sign_in() {
        let world = world();
        let sabotage = world.store.clone();
        let mut h = start(Script {
            world: Some(world),
            input: Some(format!("{}\n", request("unsaved", "tools/list"))),
            answer: Box::new(move |_, _| {
                sabotage.fail_save("no space left on device");
                Ok(refused())
            }),
            ..script()
        });

        assert_eq!(h.exit_code(), 1);
        assert_eq!(h.stdout_lines(), vec![lost_line(&json!("unsaved"))]);
        assert_eq!(h.stderr(), lost("no space left on device"));
        // The endpoint rotated the pair, so the one still stored is stale
        // now. That is why this is final.
        assert_eq!(h.refreshes().len(), 1);
        assert_eq!(
            h.posts().len(),
            1,
            "nothing is retried on a pair that is not stored"
        );
        assert_eq!(h.stored().unwrap().access_token, Token::new(ACCESS));
        h.assert_no_secrets();
    }

    #[test]
    fn a_retry_refused_again_ends_the_bridge() {
        // The renewal here succeeds, so the bridge is marked lost by the
        // answer itself, not by the renewal.
        let mut h = start(Script {
            answer: Box::new(|_, _| Ok(refused())),
            ..script()
        });

        h.send(&request("r", "tools/list"));
        assert_eq!(h.exit_code(), 1);
        assert_eq!(h.stdout_lines(), vec![lost_line(&json!("r"))]);
        assert_eq!(h.stderr(), lost("the server refused the renewed token"));
        assert_eq!(h.posts().len(), 2, "refused, renewed, refused once more");
        assert_eq!(h.posts()[1].access_token, Token::new(NEXT_ACCESS));
        assert_eq!(h.refreshes().len(), 1);
        assert_eq!(
            h.stored().unwrap().access_token,
            Token::new(NEXT_ACCESS),
            "the renewal that did succeed was kept"
        );

        // And nothing more is forwarded, not even once.
        h.send(&request("later", "tools/list"));
        assert!(
            !wait_up_to(Duration::from_millis(300), || h.posts().len() > 2),
            "a message was forwarded after the sign-in was lost"
        );
        assert_eq!(h.refreshes().len(), 1);
        h.assert_no_secrets();
    }

    #[test]
    fn without_a_stored_pair_the_bridge_exits_before_touching_stdio() {
        let mut h = start(Script {
            stored: None,
            ..script()
        });

        assert_eq!(h.exit_code(), 1);
        assert_eq!(h.stdout_lines(), Vec::<String>::new());
        assert_eq!(
            h.stderr(),
            "not signed in for MCP on fluxvale.com, run `fluxvale mcp login` first\n"
        );
        assert!(h.posts().is_empty());
        assert!(h.urls().is_empty(), "no transport is even built");
        h.assert_no_secrets();
    }

    #[test]
    fn an_unreachable_server_is_answered_and_the_bridge_stays_alive() {
        let first = request(1, "tools/list");
        let second = request(2, "resources/list");
        let mut h = start(Script {
            input: Some(format!("{first}\n{second}\n")),
            answer: Box::new(|_, post| {
                if method(post) == "tools/list" {
                    Err(r#"could not reach the MCP server: io: "connection reset" "#.to_string())
                } else {
                    Ok(echo(post))
                }
            }),
            ..script()
        });

        assert_eq!(h.exit_code(), 0);
        let mut lines = h.stdout_lines();
        lines.sort();
        assert_eq!(
            lines,
            vec![
                answer(2, "resources/list"),
                r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"could not reach the MCP server: io: \"connection reset\" "}}"#.to_string(),
            ],
        );
        assert_eq!(
            h.stderr(),
            "",
            "a request gets its answer on stdout, not a note on stderr"
        );
        h.assert_no_secrets();
    }

    #[test]
    fn other_statuses_pass_the_servers_answer_through_or_name_the_status() {
        let own_error = json!({
            "jsonrpc": "2.0", "id": "e",
            "error": {"code": -32602, "message": "Unknown tool: nope", "data": {"tool": "nope"}}
        });
        let echoed = own_error.clone();
        let mut h = start(Script {
            input: Some(format!(
                "{}\n{}\n",
                request("e", "tools/call"),
                request("f", "tools/list")
            )),
            answer: Box::new(move |_, post| {
                Ok(match method(post).as_str() {
                    "tools/call" => McpReply {
                        status: 400,
                        messages: vec![echoed.clone()],
                    },
                    _ => McpReply {
                        status: 503,
                        messages: Vec::new(),
                    },
                })
            }),
            ..script()
        });

        assert_eq!(h.exit_code(), 0);
        let mut lines = h.stdout_lines();
        lines.sort();
        let mut expected = vec![
            r#"{"jsonrpc":"2.0","id":"f","error":{"code":-32603,"message":"the MCP server answered HTTP 503"}}"#.to_string(),
            // Re-serialized on the way through, so in the bridge's key order.
            json!({"error": own_error["error"], "id": "e", "jsonrpc": "2.0"}).to_string(),
        ];
        expected.sort();
        assert_eq!(lines, expected);
        assert_eq!(h.stderr(), "");
        h.assert_no_secrets();
    }

    #[test]
    fn a_line_that_is_not_json_gets_a_parse_error_and_the_next_request_is_answered() {
        let mut h = start(Script {
            input: Some(format!(
                "not json\n\n   \n{}\n{}\n",
                request(3, "tools/list"),
                notification("notifications/cancelled")
            )),
            answer: Box::new(|_, post| {
                Ok(match method(post).as_str() {
                    "notifications/cancelled" => McpReply {
                        status: 202,
                        messages: Vec::new(),
                    },
                    _ => echo(post),
                })
            }),
            ..script()
        });

        assert_eq!(h.exit_code(), 0);
        assert_eq!(
            h.stdout_lines(),
            vec![
                r#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error"}}"#
                    .to_string(),
                answer(3, "tools/list"),
            ]
        );
        assert_eq!(
            h.posts().len(),
            2,
            "only the two real messages were forwarded"
        );
        assert_eq!(
            h.stderr(),
            "",
            "a notification answered with 202 needs no note"
        );
        h.assert_no_secrets();
    }

    #[test]
    fn the_protocol_version_header_follows_the_negotiation() {
        let mut h = start(Script {
            answer: Box::new(|_, post| {
                Ok(match method(post).as_str() {
                    "initialize" => answered(vec![initialize_result()]),
                    _ => echo(post),
                })
            }),
            ..script()
        });

        // Nothing is negotiated yet: only a message's own `_meta` version rides.
        let own = with_meta_version(1, "2025-06-18");
        let bare = request(2, "tools/list");
        let init = initialize();
        let after = request(3, "tools/list");
        let different = with_meta_version(4, "2025-06-18");
        let again = initialize();
        for (count, line) in [&own, &bare, &init, &after, &different, &again]
            .into_iter()
            .enumerate()
        {
            h.send(line);
            h.stdout_after(count + 1);
        }
        assert_eq!(h.finish(), 0);

        let headers: BTreeMap<String, Option<String>> = h
            .posts()
            .iter()
            .map(|post| {
                let message = message(post);
                let key = match message["method"].as_str() {
                    Some("initialize") => "initialize".to_string(),
                    _ => message["id"].to_string(),
                };
                (key, post.protocol_version.clone())
            })
            .collect();
        assert_eq!(
            headers,
            BTreeMap::from([
                ("1".to_string(), Some("2025-06-18".to_string())),
                ("2".to_string(), None),
                ("initialize".to_string(), None),
                ("3".to_string(), Some(PROTOCOL.to_string())),
                // A message's own `_meta` version wins over the negotiated one:
                // the server refuses a header that differs from it.
                ("4".to_string(), Some("2025-06-18".to_string())),
            ])
        );
        h.assert_no_secrets();
    }

    #[test]
    fn a_negotiated_2026_07_28_is_not_sent_on_a_bare_message() {
        let mut h = start(Script {
            answer: Box::new(|_, post| {
                Ok(match method(post).as_str() {
                    "initialize" => answered(vec![initialize_result_negotiating("2026-07-28")]),
                    _ => echo(post),
                })
            }),
            ..script()
        });

        let init = initialize_as("2026-07-28");
        let bare = request(1, "tools/list");
        let own = with_meta_version(2, "2026-07-28");
        for (count, line) in [&init, &bare, &own].into_iter().enumerate() {
            h.send(line);
            h.stdout_after(count + 1);
        }
        assert_eq!(h.finish(), 0);

        let headers: BTreeMap<String, Option<String>> = h
            .posts()
            .iter()
            .map(|post| {
                let message = message(post);
                let key = match message["method"].as_str() {
                    Some("initialize") => "initialize".to_string(),
                    _ => message["id"].to_string(),
                };
                (key, post.protocol_version.clone())
            })
            .collect();
        assert_eq!(
            headers,
            BTreeMap::from([
                ("initialize".to_string(), None),
                // From this version on the server requires `_meta` on any
                // request whose header says it, and a bare message has none.
                ("1".to_string(), None),
                ("2".to_string(), Some("2026-07-28".to_string())),
            ])
        );
        h.assert_no_secrets();
    }

    #[test]
    fn only_an_initialize_answer_negotiates() {
        let mut h = start(Script {
            answer: Box::new(|_, post| {
                Ok(match method(post).as_str() {
                    "initialize" => answered(vec![initialize_result()]),
                    // A tool's result happens to carry something called protocolVersion.
                    "tools/call" => answered(vec![json!({
                        "jsonrpc": "2.0", "id": message(post)["id"],
                        "result": {"protocolVersion": "1999-01-01", "content": []}
                    })]),
                    _ => echo(post),
                })
            }),
            ..script()
        });

        let init = initialize();
        let call = request(1, "tools/call");
        let next = request(2, "tools/list");
        for (count, line) in [&init, &call, &next].into_iter().enumerate() {
            h.send(line);
            h.stdout_after(count + 1);
        }
        assert_eq!(h.finish(), 0);

        let headers: BTreeMap<String, Option<String>> = h
            .posts()
            .iter()
            .map(|post| {
                let message = message(post);
                let key = match message["method"].as_str() {
                    Some("initialize") => "initialize".to_string(),
                    _ => message["id"].to_string(),
                };
                (key, post.protocol_version.clone())
            })
            .collect();
        assert_eq!(
            headers,
            BTreeMap::from([
                ("initialize".to_string(), None),
                ("1".to_string(), Some(PROTOCOL.to_string())),
                // Still what `initialize` negotiated, not the tool result's.
                ("2".to_string(), Some(PROTOCOL.to_string())),
            ])
        );
        h.assert_no_secrets();
    }

    /// One row of the URL table: the flag, the stored resource, the API's base URL, and the endpoint or the error.
    type UrlCase<'a> = (
        Option<&'a str>,
        Option<&'a str>,
        &'a str,
        Result<&'a str, &'a str>,
    );

    #[test]
    fn the_url_comes_from_the_flag_then_the_stored_resource_then_the_environment() {
        const STAGING: &str = "https://mcp-staging.fluxvale.com/mcp";
        const ELSEWHERE: &str = "https://mcp.example.test/mcp";
        const LOCAL: &str = "http://127.0.0.1:4000";
        // The guard's message: the pair is bound to `bound`, the flag named `flag`.
        let bound = |bound: &str, flag: &str| {
            format!(
                "the stored MCP pair is bound to {bound}. Run `fluxvale mcp login --resource {flag}` to pair it with that server, or pass --url {bound}."
            )
        };
        let elsewhere_over_prod = bound(MCP_URL, ELSEWHERE);
        let prod_over_staging = bound(STAGING, MCP_URL);
        let flag_unchecked = format!(
            "cannot derive the MCP server URL from base URL {LOCAL}, so --url cannot be checked against the stored sign-in. Run `fluxvale mcp login --resource <URL>` for the MCP server you want, then run `fluxvale mcp serve` without --url."
        );
        let no_flag = format!(
            "cannot derive the MCP server URL from base URL {LOCAL}. Run `fluxvale mcp login --resource <URL>`."
        );
        let slashed = format!("{MCP_URL}/");
        let cases: Vec<UrlCase> = vec![
            // A login without --resource is bound to the environment's own
            // server, so that is what the flag is checked against.
            (
                Some(ELSEWHERE),
                None,
                BASE_URL,
                Err(elsewhere_over_prod.as_str()),
            ),
            (Some(MCP_URL), None, BASE_URL, Ok(MCP_URL)),
            (
                Some(slashed.as_str()),
                None,
                "https://fluxvale.com",
                Ok(MCP_URL),
            ),
            // A login with --resource is bound to that one.
            (Some(ELSEWHERE), Some(ELSEWHERE), BASE_URL, Ok(ELSEWHERE)),
            (
                Some(ELSEWHERE),
                Some(MCP_URL),
                BASE_URL,
                Err(elsewhere_over_prod.as_str()),
            ),
            (Some(slashed.as_str()), Some(MCP_URL), BASE_URL, Ok(MCP_URL)),
            // Without a flag the bound server is the URL.
            (None, Some(STAGING), BASE_URL, Ok(STAGING)),
            (
                None,
                Some(MCP_URL),
                "https://staging.fluxvale.com",
                Ok(MCP_URL),
            ),
            (None, None, "https://staging.fluxvale.com", Ok(STAGING)),
            (None, None, "https://fluxvale.com/", Ok(MCP_URL)),
            // An environment with no MCP server of its own: the flag cannot
            // be checked against anything, and without one there is no URL.
            (Some(ELSEWHERE), None, LOCAL, Err(flag_unchecked.as_str())),
            (None, None, LOCAL, Err(no_flag.as_str())),
        ];
        for (flag_url, stored_resource, base_url, expected) in cases {
            let got =
                resolve_url(flag_url, stored_resource, base_url).map_err(|err| err.to_string());
            assert_eq!(
                got,
                expected.map(str::to_owned).map_err(str::to_owned),
                "flag {flag_url:?}, stored {stored_resource:?}, base {base_url}"
            );
        }

        // The guard runs in the bridge too, before anything is forwarded.
        let mut h = start(Script {
            stored: Some(pair(ACCESS, REFRESH, 3600, Some(STAGING))),
            flag_url: Some(MCP_URL),
            ..script()
        });
        let err = h.exit().unwrap_err();
        assert_eq!(err.to_string(), prod_over_staging);
        assert!(h.posts().is_empty());
        assert!(h.stdout_lines().is_empty());
        h.assert_no_secrets();
    }

    #[test]
    fn a_flag_is_checked_against_the_environment_for_a_login_without_a_resource() {
        // The pair stores no resource, so its token is the environment's own
        // server's. A flag that names another server must not get it.
        let mut h = start(Script {
            stored: Some(pair(ACCESS, REFRESH, 3600, None)),
            flag_url: Some("https://mcp.example.test/mcp"),
            ..script()
        });

        let err = h.exit().unwrap_err();

        assert_eq!(
            err.to_string(),
            "the stored MCP pair is bound to https://mcp.fluxvale.com/mcp. Run `fluxvale mcp login --resource https://mcp.example.test/mcp` to pair it with that server, or pass --url https://mcp.fluxvale.com/mcp."
        );
        assert!(h.posts().is_empty(), "no POST was made");
        assert!(h.urls().is_empty(), "no transport was even built");
        assert!(h.stdout_lines().is_empty());
        assert!(h.refreshes().is_empty());
        h.assert_no_secrets();
    }

    #[test]
    fn a_slow_request_does_not_hold_up_a_later_one() {
        let slow = request("slow", "tools/call");
        let fast = request("fast", "tools/list");
        let mut h = start(Script {
            input: Some(format!("{slow}\n{fast}\n")),
            answer: Box::new(|seen, post| {
                // The slow call's answer waits until the later request has been forwarded too.
                if method(post) == "tools/call"
                    && !wait_up_to(WAIT, || seen.posts.lock().unwrap().len() >= 2)
                {
                    return Err(
                        "the later request was not forwarded while this one waited".to_string()
                    );
                }
                Ok(echo(post))
            }),
            ..script()
        });

        assert_eq!(h.exit_code(), 0);
        let mut lines = h.stdout_lines();
        lines.sort();
        assert_eq!(
            lines,
            vec![answer("fast", "tools/list"), answer("slow", "tools/call")]
        );
        h.assert_no_secrets();
    }

    #[test]
    fn a_message_nobody_waits_for_is_dropped_with_one_stderr_line() {
        let mut h = start(Script {
            input: Some(format!(
                "{}\n{}\n",
                notification("notifications/progress"),
                notification("notifications/cancelled")
            )),
            answer: Box::new(|_, post| {
                if method(post) == "notifications/progress" {
                    Ok(McpReply {
                        status: 503,
                        messages: Vec::new(),
                    })
                } else {
                    Err("could not reach the MCP server: connection failed".to_string())
                }
            }),
            ..script()
        });

        assert_eq!(h.exit_code(), 0, "a dropped notification is not fatal");
        assert!(h.stdout_lines().is_empty(), "a notification gets no answer");
        let mut lines = h.stderr().lines().map(str::to_owned).collect::<Vec<_>>();
        lines.sort();
        assert_eq!(
            lines,
            vec![
                "fluxvale: dropped a message: could not reach the MCP server: connection failed"
                    .to_string(),
                "fluxvale: dropped a message: the MCP server answered HTTP 503".to_string(),
            ]
        );
        h.assert_no_secrets();
    }

    /// A bridge on the real client, where the first request gets `first`
    /// and the second is answered. Runs both, one after the other as a
    /// client does, and returns what each got on stdout, then the exit code.
    fn on_the_wire(first: String) -> (Vec<String>, String, i32) {
        let mut h = start(Script {
            wire: Some(vec![
                first,
                http("200 OK", "application/json", &answer(2, "tools/list")),
            ]),
            ..script()
        });
        h.send(&request(1, "tools/call"));
        h.stdout_after(1);
        h.send(&request(2, "tools/list"));
        let both = h.stdout_after(2);
        let code = h.finish();
        let stderr = h.stderr();
        assert_eq!(h.wire_requests().len(), 2, "one request each");
        h.assert_no_secrets();
        (both, stderr, code)
    }

    #[test]
    fn a_403_with_a_gateway_error_body_is_answered_with_the_status_alone() {
        let (stdout, stderr, code) = on_the_wire(http(
            "403 Forbidden",
            "application/json",
            INSUFFICIENT_SCOPE,
        ));

        let told = not_answered(1, "the MCP server answered HTTP 403");
        assert_eq!(stdout, vec![told, answer(2, "tools/list")]);
        assert_eq!(stderr, "");
        assert_eq!(code, 0);
    }

    #[test]
    fn a_200_that_is_not_a_json_rpc_message_is_answered_as_such() {
        let (stdout, stderr, code) =
            on_the_wire(http("200 OK", "text/html", "<html>sign in</html>"));

        let told = not_answered(
            1,
            "the MCP server answered HTTP 200 with no JSON-RPC message",
        );
        assert_eq!(stdout, vec![told, answer(2, "tools/list")]);
        assert_eq!(stderr, "");
        assert_eq!(code, 0);
    }

    #[test]
    fn an_empty_200_to_a_request_is_answered_as_such() {
        let (stdout, stderr, code) = on_the_wire(http("200 OK", "application/json", ""));

        let told = not_answered(
            1,
            "the MCP server answered HTTP 200 with no JSON-RPC message",
        );
        assert_eq!(stdout, vec![told, answer(2, "tools/list")]);
        assert_eq!(stderr, "");
        assert_eq!(code, 0);
    }

    #[test]
    fn a_503_with_a_jsonapi_error_body_is_answered_with_the_status_alone() {
        let (stdout, stderr, code) = on_the_wire(http(
            "503 Service Unavailable",
            "application/json",
            UPSTREAM_DOWN,
        ));

        let told = not_answered(1, "the MCP server answered HTTP 503");
        assert_eq!(stdout, vec![told, answer(2, "tools/list")]);
        assert_eq!(stderr, "");
        assert_eq!(code, 0);
    }

    #[test]
    fn no_word_of_a_body_that_is_no_message_reaches_the_client() {
        // Every run above, through the real client: the bodies' own words
        // are the server's business, and the status is all the client gets.
        for (status, content_type, body) in [
            ("403 Forbidden", "application/json", INSUFFICIENT_SCOPE),
            ("200 OK", "text/html", "<html>sign in</html>"),
            ("503 Service Unavailable", "application/json", UPSTREAM_DOWN),
        ] {
            let mut h = start(Script {
                wire: Some(vec![
                    http(status, content_type, body),
                    http("200 OK", "application/json", &answer(2, "tools/list")),
                ]),
                ..script()
            });
            h.send(&request(1, "tools/call"));
            h.stdout_after(1);
            h.send(&request(2, "tools/list"));
            h.stdout_after(2);
            assert_eq!(h.finish(), 0);
            let shown = format!("{}{}", h.stdout_lines().join("\n"), h.stderr());
            for word in [
                "insufficient_scope",
                "sign in",
                "upstream down",
                "instances:read",
            ] {
                assert!(
                    !shown.contains(word),
                    "{status}: the client was shown {word:?}: {shown}"
                );
            }
            h.assert_no_secrets();
        }
    }

    #[test]
    fn a_pair_minted_for_another_server_is_never_adopted() {
        const OTHER_ACCESS: &str = "fvoat_other_server_access_token_never_sent";
        const OTHER_REFRESH: &str = "fvort_other_server_refresh_token_never_sent";
        let first = "https://mcp-a.example/mcp";
        let second = "https://mcp-b.example/mcp";
        let elsewhere = pair(OTHER_ACCESS, OTHER_REFRESH, 7200, Some(second));
        let world = Arc::new(World::new(
            HOST,
            Some(pair(ACCESS, REFRESH, 7200, Some(first))),
            Box::new(|_, _| Ok(renewed())),
        ));
        let store = world.store.clone();
        let landed = elsewhere.clone();
        let mut h = start(Script {
            world: Some(world),
            input: Some(format!("{}\n", request("moved", "tools/list"))),
            // A login for another server lands while the request is in flight.
            answer: Box::new(move |_, _| {
                store.save(HOST, &landed).unwrap();
                Ok(refused())
            }),
            ..script()
        });

        assert_eq!(h.exit_code(), 1);
        assert_eq!(h.stdout_lines(), vec![lost_line(&json!("moved"))]);
        assert_eq!(
            h.stderr(),
            lost("the stored sign-in is now for https://mcp-b.example/mcp")
        );
        assert!(h.refreshes().is_empty(), "no refresh call");
        assert!(
            h.posts()
                .iter()
                .all(|post| post.access_token == Token::new(ACCESS)),
            "no POST carried the other pair's token"
        );
        assert_eq!(
            h.stored(),
            Some(elsewhere),
            "the store is left as the login put it"
        );
        h.assert_no_secrets();
        let shown = format!("{}{}", h.stdout_lines().join("\n"), h.stderr());
        assert!(!shown.contains(OTHER_ACCESS));
        assert!(!shown.contains(OTHER_REFRESH));
    }

    /// A stdin that cannot be read at all.
    struct FailingReader(io::ErrorKind);

    impl io::Read for FailingReader {
        fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
            Err(io::Error::from(self.0))
        }
    }

    impl BufRead for FailingReader {
        fn fill_buf(&mut self) -> io::Result<&[u8]> {
            Err(io::Error::from(self.0))
        }

        fn consume(&mut self, _: usize) {}
    }

    #[test]
    fn a_stdin_that_cannot_be_read_is_an_error() {
        let store = MemoryStore::default();
        store
            .save(HOST, &pair(ACCESS, REFRESH, 3600, Some(MCP_URL)))
            .unwrap();
        let seen = Arc::new(Seen::default());
        let transport: Connected = Arc::new(MockTransport {
            seen: seen.clone(),
            answer: Box::new(|_, post| Ok(echo(post))),
        });
        let dir = temp_dir();

        let err = serve(
            None,
            BASE_URL,
            HOST,
            FailingReader(io::ErrorKind::PermissionDenied),
            ClientStdout(seen.clone()),
            {
                let stderr = seen.clone();
                move |line| push(&stderr.stderr, line)
            },
            move |_| Ok(transport.clone()),
            store.clone(),
            FileRenewalLock::new(dir.join("mcp-renewal.lock")),
            |_, _| unreachable!("nothing is forwarded"),
            || NOW,
        )
        .unwrap_err();

        assert!(
            err.to_string().starts_with("could not read stdin: "),
            "err: {err}"
        );
        assert!(seen.stdout.lock().unwrap().is_empty());
        assert!(seen.stderr.lock().unwrap().is_empty());
        assert!(
            seen.posts.lock().unwrap().is_empty(),
            "nothing was forwarded"
        );
        // A bridge that never renews never opens the lock file.
        assert!(!dir.join("mcp-renewal.lock").exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_line_that_is_not_utf8_gets_a_parse_error() {
        let mut h = start(Script { ..script() });

        h.send_bytes(b"\xff\xfe{\"jsonrpc\": \"2.0\"\n");
        assert_eq!(
            h.stdout_after(1),
            vec![
                r#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error"}}"#
                    .to_string()
            ]
        );
        h.send(&request(1, "tools/list"));
        assert_eq!(
            h.stdout_after(2),
            vec![
                r#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error"}}"#
                    .to_string(),
                answer(1, "tools/list"),
            ]
        );
        assert_eq!(h.finish(), 0);
        assert_eq!(h.stderr(), "");
        h.assert_no_secrets();
    }

    #[test]
    fn a_line_ended_by_crlf_and_a_last_line_without_a_newline_are_forwarded_as_they_are() {
        let first = request(1, "tools/list");
        let last = request(2, "resources/list");
        let mut h = start(Script { ..script() });

        // A Windows client's line ending.
        h.send_bytes(format!("{first}\r\n").as_bytes());
        assert_eq!(h.stdout_after(1), vec![answer(1, "tools/list")]);

        // The last line has no terminator at all. The end of input ends it.
        h.send_bytes(last.as_bytes());
        assert_eq!(h.finish(), 0);

        assert_eq!(
            h.posts()
                .iter()
                .map(|post| post.body.as_str())
                .collect::<Vec<_>>(),
            vec![first.as_str(), last.as_str()],
            "neither the line ending nor its absence reaches the wire"
        );
        assert_eq!(
            h.stdout_lines(),
            vec![answer(1, "tools/list"), answer(2, "resources/list")],
            "and the last line is answered all the same"
        );
        assert_eq!(h.stderr(), "");
        h.assert_no_secrets();
    }

    #[test]
    fn a_store_that_cannot_be_read_at_startup_is_an_error() {
        let world = world();
        world.store.fail_load("the OS keychain is locked");
        let mut h = start(Script {
            world: Some(world),
            input: Some(format!("{}\n", request(1, "tools/list"))),
            ..script()
        });

        let err = h.exit().unwrap_err();

        assert_eq!(err.to_string(), "the OS keychain is locked");
        assert!(h.stdout_lines().is_empty());
        assert!(h.stderr().is_empty());
        assert!(h.posts().is_empty(), "no POST was made");
        h.assert_no_secrets();
    }

    #[test]
    fn a_notification_whose_renewal_fails_for_good_ends_the_bridge() {
        let mut h = start(Script {
            answer: Box::new(|_, _| Ok(refused())),
            renew: Box::new(|_, _| Err(permanent("invalid_grant: refresh token revoked"))),
            input: Some(format!("{}\n", notification("notifications/progress"))),
            ..script()
        });

        assert_eq!(h.exit_code(), 1);
        assert!(h.stdout_lines().is_empty(), "a notification gets no answer");
        assert_eq!(h.stderr(), lost("invalid_grant: refresh token revoked"));
        h.assert_no_secrets();
    }

    #[test]
    fn two_bridges_renew_once() {
        // Two bridges, as two MCP clients under one sign-in run: one store,
        // one token endpoint, one lock file.
        let world = Arc::new(World::new(
            HOST,
            Some(pair(ACCESS, REFRESH, 7200, Some(MCP_URL))),
            // The token endpoint takes a moment, which opens the window in
            // which the other bridge is refused too.
            Box::new(|_, _| {
                std::thread::sleep(Duration::from_millis(150));
                Ok(renewed())
            }),
        ));
        let mut a = start(Script {
            world: Some(world.clone()),
            input: Some(format!("{}\n", request("a", "tools/list"))),
            answer: refuse_old(),
            ..script()
        });
        let mut b = start(Script {
            world: Some(world),
            input: Some(format!("{}\n", request("b", "tools/list"))),
            answer: refuse_old(),
            ..script()
        });

        assert_eq!(a.finish(), 0);
        assert_eq!(b.finish(), 0);
        assert_eq!(a.stdout_lines(), vec![answer("a", "tools/list")]);
        assert_eq!(b.stdout_lines(), vec![answer("b", "tools/list")]);
        assert_eq!(
            a.refreshes(),
            vec![(Token::new(REFRESH), Some(MCP_URL.to_string()))],
            "exactly one refresh call, shown the old refresh token once"
        );
        assert_eq!(b.refreshes(), a.refreshes(), "the endpoint is one");
        assert_eq!(a.stored().unwrap().access_token, Token::new(NEXT_ACCESS));
        assert_eq!(a.stderr(), "");
        assert_eq!(b.stderr(), "");
        a.assert_no_secrets();
        b.assert_no_secrets();
    }

    #[test]
    fn a_lock_another_process_holds_costs_one_renewal_attempt() {
        let world = Arc::new(plain_world().with_lock_wait(HELD_FOR));
        // Another process is mid-renewal.
        let held = hold_elsewhere(&world.lock);
        let mut h = start(Script {
            world: Some(world),
            answer: refuse_old(),
            ..script()
        });

        h.send(&request("busy", "tools/list"));
        let gave_up = not_answered(
            "busy",
            &format!(
                "{RENEWAL_FAILED}: another fluxvale process has held the renewal lock for {HELD_FOR:?}"
            ),
        );
        assert_eq!(h.stdout_after(1), vec![gave_up.clone()]);
        assert_eq!(h.stderr(), "");
        assert!(h.refreshes().is_empty(), "no refresh call");

        // The other process is done. The next refusal renews.
        drop(held);
        h.send(&request("next", "tools/list"));
        assert_eq!(
            h.stdout_after(2),
            vec![gave_up, answer("next", "tools/list")]
        );
        assert_eq!(h.finish(), 0);
        assert_eq!(
            tokens(&h),
            vec![
                Token::new(ACCESS),
                Token::new(ACCESS),
                Token::new(NEXT_ACCESS)
            ]
        );
        assert_eq!(h.refreshes().len(), 1);
        h.assert_no_secrets();
    }

    #[test]
    fn a_lock_another_process_holds_at_startup_is_reported_and_the_bridge_serves() {
        let world = Arc::new(
            World::new(
                HOST,
                Some(pair(ACCESS, REFRESH, 30, Some(MCP_URL))),
                Box::new(|_, _| Ok(renewed())),
            )
            .with_lock_wait(HELD_FOR),
        );
        let held = hold_elsewhere(&world.lock);
        let mut h = start(Script {
            world: Some(world),
            answer: refuse_old(),
            ..script()
        });
        let reported = format!(
            "fluxvale: could not renew the MCP access token yet: another fluxvale process has held the renewal lock for {HELD_FOR:?}\n"
        );

        // The startup renewal waits, gives up, and says so.
        assert_eq!(h.stderr_after(1), reported);
        assert!(h.refreshes().is_empty(), "no refresh call");

        // And the bridge serves. Once the lock is free the next refusal renews.
        drop(held);
        h.send(&request(1, "tools/list"));
        assert_eq!(h.stdout_after(1), vec![answer(1, "tools/list")]);
        assert_eq!(h.finish(), 0);
        assert_eq!(h.stderr(), reported, "exactly that one line");
        assert_eq!(h.refreshes().len(), 1);
        h.assert_no_secrets();
    }

    #[test]
    fn a_lock_that_cannot_exist_is_reported_and_the_renewal_goes_ahead() {
        let dir = temp_dir();
        std::fs::write(dir.join("not-a-directory"), b"a regular file").unwrap();
        let world = Arc::new(
            plain_world().with_lock_path(dir.join("not-a-directory").join("mcp-renewal.lock")),
        );
        let mut h = start(Script {
            world: Some(world),
            input: Some(format!("{}\n", request(1, "tools/list"))),
            answer: refuse_old(),
            ..script()
        });

        assert_eq!(h.exit_code(), 0);
        assert_eq!(h.stdout_lines(), vec![answer(1, "tools/list")]);
        assert_eq!(
            tokens(&h),
            vec![Token::new(ACCESS), Token::new(NEXT_ACCESS)],
            "renewed, and answered with the new token"
        );
        assert_eq!(h.refreshes().len(), 1);
        let stderr = h.stderr();
        assert_eq!(stderr.lines().count(), 1, "exactly one line: {stderr:?}");
        assert!(
            stderr.starts_with("fluxvale: could not take the renewal lock ("),
            "stderr: {stderr:?}"
        );
        assert!(
            stderr.ends_with("), renewing without it\n"),
            "stderr: {stderr:?}"
        );
        h.assert_no_secrets();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn without_a_usable_lock_file_renewals_in_this_process_are_still_one_at_a_time() {
        // Where the cross-process lock cannot exist, the bridge renews
        // without it. The lock this process takes on its own is then all
        // that keeps two refusals from presenting one refresh token twice.
        let dir = temp_dir();
        std::fs::write(dir.join("not-a-directory"), b"a regular file").unwrap();
        let world = Arc::new(
            World::new(
                HOST,
                script().stored,
                Box::new(|_, _| {
                    // The token endpoint takes a moment, as it does.
                    std::thread::sleep(Duration::from_millis(150));
                    Ok(renewed())
                }),
            )
            .with_lock_path(dir.join("not-a-directory").join("mcp-renewal.lock")),
        );
        let mut h = start(Script {
            world: Some(world),
            input: Some(format!(
                "{}\n{}\n",
                request("a", "tools/list"),
                request("b", "tools/list")
            )),
            answer: refuse_old(),
            ..script()
        });

        assert_eq!(h.exit_code(), 0);
        assert_eq!(
            h.refreshes(),
            vec![(Token::new(REFRESH), Some(MCP_URL.to_string()))],
            "exactly one refresh call, shown the old refresh token once"
        );
        let mut stdout = h.stdout_lines();
        stdout.sort();
        assert_eq!(
            stdout,
            vec![answer("a", "tools/list"), answer("b", "tools/list")]
        );
        // Each of the two renewals said it went ahead without the lock.
        let stderr = h.stderr();
        assert_eq!(stderr.lines().count(), 2, "stderr: {stderr:?}");
        assert!(stderr.lines().all(|line| {
            line.starts_with("fluxvale: could not take the renewal lock (")
                && line.ends_with("), renewing without it")
        }));
        h.assert_no_secrets();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_renewal_lock_is_held_by_one_and_waited_for_by_the_other() {
        let path = temp_dir().join("mcp-renewal.lock");
        let shortly = Duration::from_millis(60);
        let first = FileRenewalLock::new(path.clone()).with_wait(shortly);
        let second = FileRenewalLock::new(path.clone()).with_wait(shortly);

        let Ok(Held::Locked(guard)) = first.hold() else {
            panic!("a free lock is taken at once");
        };
        let second = Arc::new(second);
        let waited = {
            let second = second.clone();
            std::thread::spawn(move || second.hold())
        };
        assert!(
            wait_up_to(WAIT, || waited.is_finished()),
            "the second lock's hold never came back: the wait does not end"
        );
        assert!(
            waited.join().unwrap().is_err(),
            "the second waits out its wait and gives up"
        );

        drop(guard);

        assert!(
            matches!(second.hold(), Ok(Held::Locked(_))),
            "dropping the first guard released the lock"
        );
        drop((first, second.as_ref().clone()));
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[cfg(unix)]
    #[test]
    fn a_lock_file_is_readable_by_its_owner_only() {
        use std::os::unix::fs::PermissionsExt as _;

        let path = temp_dir().join("mcp-renewal.lock");
        let Ok(Held::Locked(_guard)) = FileRenewalLock::new(path.clone()).hold() else {
            panic!("a free lock is taken at once");
        };

        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "the lock file is the owner's alone");
        drop(_guard);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn two_refusals_and_a_failing_save_refresh_once() {
        let world = world();
        let store = world.store.clone();
        let mut h = start(Script {
            world: Some(world),
            input: Some(format!(
                "{}\n{}\n",
                request("a", "tools/list"),
                request("b", "tools/list")
            )),
            answer: Box::new(move |_, _| {
                store.fail_save("no space left on device");
                Ok(refused())
            }),
            ..script()
        });

        assert_eq!(h.exit_code(), 1);
        assert_eq!(h.refreshes().len(), 1, "exactly one refresh call");
        let stdout = h.stdout_lines();
        assert!(
            !stdout.is_empty()
                && stdout.iter().all(|line| {
                    line == &lost_line(&json!("a")) || line == &lost_line(&json!("b"))
                }),
            "every line that reached stdout is a lost sign-in answer: {stdout:?}"
        );
        assert_eq!(
            h.stderr(),
            lost("no space left on device"),
            "the first request's reason is the one told"
        );
        h.assert_no_secrets();
    }

    #[test]
    fn two_refusals_and_a_refusing_endpoint_refresh_once() {
        let world = Arc::new(World::new(
            HOST,
            script().stored,
            Box::new(|_, _| Err(permanent("invalid_grant: refresh token revoked"))),
        ));
        let mut h = start(Script {
            world: Some(world),
            input: Some(format!(
                "{}\n{}\n",
                request("a", "tools/list"),
                request("b", "tools/list")
            )),
            answer: Box::new(|_, _| Ok(refused())),
            ..script()
        });

        assert_eq!(h.exit_code(), 1);
        assert_eq!(h.refreshes().len(), 1, "exactly one refresh call");
        let stdout = h.stdout_lines();
        assert!(
            !stdout.is_empty()
                && stdout.iter().all(|line| {
                    line == &lost_line(&json!("a")) || line == &lost_line(&json!("b"))
                }),
            "every line that reached stdout carries the lost sign-in message: {stdout:?}"
        );
        assert_eq!(h.stderr(), lost("invalid_grant: refresh token revoked"));
        h.assert_no_secrets();
    }

    #[test]
    fn only_an_object_with_an_id_and_no_answer_is_a_request() {
        assert_eq!(
            request_id(&json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})),
            Some(&json!(1))
        );
        assert_eq!(
            request_id(&json!({"jsonrpc": "2.0", "id": "a", "method": "tools/list"})),
            Some(&json!("a"))
        );
        for not_a_request in [
            json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
            json!({"jsonrpc": "2.0", "id": 1, "result": {}}),
            json!({"jsonrpc": "2.0", "id": 1, "error": {"code": -1}}),
            json!([{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}]),
            json!("a string"),
            json!(null),
        ] {
            assert_eq!(request_id(&not_a_request), None, "{not_a_request}");
        }
    }

    #[test]
    fn a_cleartext_endpoint_is_refused_before_the_bridge_starts() {
        // The pair was minted for a cleartext endpoint: the URL rules let it through, the transport does not.
        let store = MemoryStore::default();
        store
            .save(
                HOST,
                &pair(ACCESS, REFRESH, 3600, Some("http://mcp.example.test/mcp")),
            )
            .unwrap();
        let seen = Arc::new(Seen::default());
        let dir = temp_dir();

        let err = serve(
            None,
            BASE_URL,
            HOST,
            io::Cursor::new(String::new()),
            ClientStdout(seen.clone()),
            {
                let stderr = seen.clone();
                move |line| push(&stderr.stderr, line)
            },
            McpHttpClient::new,
            store.clone(),
            FileRenewalLock::new(dir.join("mcp-renewal.lock")),
            |_, _| unreachable!("no refresh without a transport"),
            || NOW,
        )
        .unwrap_err();

        assert!(err.to_string().contains("https://"), "err: {err}");
        assert!(seen.stdout.lock().unwrap().is_empty());
        assert!(seen.stderr.lock().unwrap().is_empty());
        // A bridge that never renews never opens the lock file.
        assert!(!dir.join("mcp-renewal.lock").exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_broken_stdio_is_an_error_unless_the_client_went_away() {
        // A stdout that cannot be written is an error, except for the closed pipe of a client that left.
        for (kind, expected) in [
            (io::ErrorKind::PermissionDenied, false),
            (io::ErrorKind::BrokenPipe, true),
        ] {
            let store = MemoryStore::default();
            store
                .save(HOST, &pair(ACCESS, REFRESH, 3600, Some(MCP_URL)))
                .unwrap();
            let seen = Arc::new(Seen::default());
            let dir = temp_dir();
            let transport = MockTransport {
                seen: seen.clone(),
                answer: Box::new(|_, post| Ok(echo(post))),
            };

            let exit = serve(
                None,
                BASE_URL,
                HOST,
                io::Cursor::new(format!("{}\n", request(1, "tools/list"))),
                FailingWriter(kind),
                {
                    let stderr = seen.clone();
                    move |line| push(&stderr.stderr, line)
                },
                move |_| Ok(transport),
                store.clone(),
                FileRenewalLock::new(dir.join("mcp-renewal.lock")),
                |_, _| unreachable!("a healthy pair is not renewed"),
                || NOW,
            );

            assert_eq!(exit.is_ok(), expected, "{kind:?}: {exit:?}");
            assert_eq!(
                seen.posts.lock().unwrap().len(),
                1,
                "the request was forwarded either way"
            );
            assert!(seen.stderr.lock().unwrap().is_empty());
            let _ = std::fs::remove_dir_all(dir);
        }
    }

    /// A stdout that refuses every write.
    struct FailingWriter(io::ErrorKind);

    impl Write for FailingWriter {
        fn write(&mut self, _: &[u8]) -> io::Result<usize> {
            Err(io::Error::from(self.0))
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
}
