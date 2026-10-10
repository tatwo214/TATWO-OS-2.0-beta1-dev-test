//! W176：TATWO OS 內建的 Spotify Connect 裝置。
//!
//! OS 瀏覽器的 Spotify 網頁播放器只能播約 10 秒（Spotify 只把授權給有 Google 正式 VMP 簽章的瀏覽器）。
//! 這支程式用 librespot 在本機當一台叫「TATWO OS」的 Spotify 裝置，聲音由它自己播，不經瀏覽器的加密播放元件。
//!
//! 和 App 的約定（一行一筆）：
//! - stdin：login／logout／quit／cancel_resume；JSON transfer（id、device_id、resume）與 reconnect。
//! - stdout 事件：JSON，例如 `{"event":"connected"}`、`active`／`inactive`（是不是正在播放的那台）；另外 librespot 會印一行 `Browse to: <登入網址>`，App 照原樣接。
//! - stderr：一般記錄（不含權杖）。
//! 登入只走 Spotify 官方 OAuth 頁；可重複使用的憑證由 librespot 存在 `--cache` 資料夾的 credentials.json。

use std::{
    path::PathBuf,
    time::{Duration, Instant},
};

use librespot::{
    connect::{ConnectConfig, Spirc, LoadRequest, LoadRequestOptions},
    core::{
        authentication::Credentials, cache::Cache, config::DeviceType, config::SessionConfig,
        session::Session,
        Error, error::ErrorKind,
    },
    oauth::OAuthClientBuilder,
    playback::{
        audio_backend,
        config::{AudioFormat, Bitrate, PlayerConfig},
        mixer::{self, MixerConfig},
        player::{Player, PlayerEvent},
    },
};
use futures_util::StreamExt;
use librespot::core::dealer::protocol::Message;
use librespot::protocol::connect::ClusterUpdate;
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    sync::mpsc,
};

mod recovery;
use recovery::{Backoff, Playback, resume_snapshot, is_web_player};

// 和 librespot 主程式相同的範圍；少了部分範圍時 Connect 的狀態同步會失敗。
const SCOPES: &[&str] = &[
    "app-remote-control",
    "playlist-modify",
    "playlist-modify-private",
    "playlist-modify-public",
    "playlist-read",
    "playlist-read-collaborative",
    "playlist-read-private",
    "streaming",
    "ugc-image-upload",
    "user-follow-modify",
    "user-follow-read",
    "user-library-modify",
    "user-library-read",
    "user-modify",
    "user-modify-playback-state",
    "user-modify-private",
    "user-personalized",
    "user-read-birthdate",
    "user-read-currently-playing",
    "user-read-email",
    "user-read-play-history",
    "user-read-playback-position",
    "user-read-playback-state",
    "user-read-private",
    "user-read-recently-played",
    "user-top-read",
];

const LOGIN_DONE_PAGE: &str = "<!doctype html><meta charset=\"utf-8\"><title>TATWO OS</title>\
<body style=\"font:16px -apple-system,sans-serif;padding:48px\"><h2>已登入 Spotify</h2>\
<p>TATWO OS 會在 Spotify 的裝置清單裡出現。這一頁可以關掉了。</p></body>";

fn emit(event: &str, extra: serde_json::Value) {
    let mut object = serde_json::json!({ "event": event });
    if let (Some(target), Some(source)) = (object.as_object_mut(), extra.as_object()) {
        for (key, value) in source {
            target.insert(key.clone(), value.clone());
        }
    }
    println!("{object}");
}

fn registration_timeout(session: &Session, registered: &mut bool, resume: bool, name: &str) -> Option<serde_json::Value> {
    if *registered || session.is_invalid() { return None; }
    *registered = true;
    Some(serde_json::json!({ "device": name, "device_id": session.device_id(), "resume": resume, "unconfirmed": true }))
}

type SpircFuture = std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>;
type ClusterStream = std::pin::Pin<Box<dyn futures_util::Stream<Item = Result<ClusterUpdate, Error>> + Send>>;

fn reconnect(session: &Session, stop: impl FnOnce(), backoff: &mut Backoff, connected_at: Instant, reason: &str,
    saved: &mut Option<Playback>, playback: Option<&Playback>, restoring: &mut Option<Playback>,
    spirc: &mut Option<Spirc>, task: &mut Option<SpircFuture>, cluster: &mut Option<ClusterStream>,
    active: &mut bool, owned: &mut bool, player_active: &mut bool, device: &mut Option<String>,
    transfer_task: &mut Option<tokio::task::JoinHandle<Result<(), Error>>>, transferring: &mut Option<Transfer>,
) -> tokio::time::Instant {
    if saved.is_none() { *saved = resume_snapshot(*owned, playback); }
    *restoring = None;
    *task = None; *spirc = None; *cluster = None;
    *active = false; *owned = false; *player_active = false; *device = None;
    if let Some(task) = transfer_task.take() { task.abort(); }
    if let Some(request) = transferring.take() { transfer_result(&request, Err(Error::not_found("session disconnected"))); }
    if !session.is_invalid() { session.shutdown(); }
    stop();
    // Reset only after a stable connection, not each brief successful handshake.
    if connected_at.elapsed() >= Duration::from_secs(60) { backoff.reset(); }
    let delay = backoff.next();
    emit("reconnecting", serde_json::json!({ "delay": delay.as_secs(), "reason": reason }));
    tokio::time::Instant::now() + delay
}

struct Options {
    cache: PathBuf,
    name: String,
    port: u16,
}

fn parse_options() -> Result<Options, String> {
    let mut cache = None;
    let mut name = "TATWO OS".to_string();
    let mut port = 5589u16;
    let mut args = std::env::args().skip(1);
    while let Some(flag) = args.next() {
        let value = args.next().ok_or_else(|| format!("{flag} 缺值"))?;
        match flag.as_str() {
            "--cache" => cache = Some(PathBuf::from(value)),
            "--name" => name = value,
            "--port" => port = value.parse().map_err(|_| "--port 不是數字".to_string())?,
            _ => return Err(format!("不認得的參數 {flag}")),
        }
    }
    Ok(Options { cache: cache.ok_or("需要 --cache")?, name, port })
}

#[derive(Clone)]
struct Transfer {
    id: String,
    device_id: Option<String>,
    resume: bool,
    reason: String,
}

enum Command {
    Login,
    Logout,
    Transfer(Transfer),
    Reconnect,
    CancelResume,
    Quit,
}

fn parse_command(line: &str) -> Option<Command> {
    let object: serde_json::Value = serde_json::from_str(line).unwrap_or_default();
    let name = object["command"].as_str().unwrap_or(line.trim());
    match name {
        "login" => Some(Command::Login),
        "logout" => Some(Command::Logout),
        "transfer" => Some(Command::Transfer(Transfer {
            id: object["id"].as_str().unwrap_or("legacy").into(),
            device_id: object["device_id"].as_str().map(str::to_owned),
            resume: object["resume"].as_bool().unwrap_or(false),
            reason: object["reason"].as_str().unwrap_or("").into(),
        })),
        "reconnect" => Some(Command::Reconnect),
        "cancel_resume" => Some(Command::CancelResume),
        "quit" => Some(Command::Quit),
        _ => None,
    }
}

fn spawn_stdin_reader() -> mpsc::UnboundedReceiver<Command> {
    let (tx, rx) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        let mut lines = BufReader::new(tokio::io::stdin()).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if let Some(command) = parse_command(&line) {
                if tx.send(command).is_err() { break; }
            }
        }
        let _ = tx.send(Command::Quit);
    });
    rx
}

fn transfer_options(reason: &str, playing: bool) -> Option<librespot::core::spclient::TransferRequest> {
    let paused = match reason { "gesture" => "resume", "tab-open" | "retake" if !playing => "pause", _ => return None };
    Some(librespot::core::spclient::TransferRequest { transfer_options: librespot::core::dealer::protocol::TransferOptions {
        restore_paused: Some(paused.into()), ..Default::default()
    } })
}

// Always resolve the target from the live session, not a previously connected session.
async fn transfer_here(session: Session, from: Option<String>, reason: String, playing: bool) -> Result<(), Error> {
    let own = session.device_id();
    let from = from.as_deref().filter(|id| !id.is_empty()).unwrap_or(own);
    let options = transfer_options(&reason, playing);
    let paused = options.as_ref().and_then(|o| o.transfer_options.restore_paused.as_deref());
    emit("transfer_options", serde_json::json!({ "pause": paused == Some("pause"), "play": paused == Some("resume") }));
    session.spclient().transfer(from, own, options.as_ref()).await?;
    Ok(())
}

fn transfer_result(request: &Transfer, result: Result<(), Error>) {
    match result {
        Ok(()) => emit("transferred", serde_json::json!({ "id": request.id })),
        Err(error) => emit("transfer_failed", serde_json::json!({
            "id": request.id, "not_found": error.kind == ErrorKind::NotFound,
            "message": error.to_string(),
        })),
    }
}

fn login_blocking(client_id: String, port: u16) -> Result<Credentials, String> {
    let client = OAuthClientBuilder::new(&client_id, &format!("http://127.0.0.1:{port}/login"), SCOPES.to_vec())
        .with_custom_message(LOGIN_DONE_PAGE)
        .build()
        .map_err(|e| e.to_string())?;
    // 會在 stdout 印一行 `Browse to: <網址>`，App 接到後自己開頁面。
    let token = client.get_access_token().map_err(|e| e.to_string())?;
    Ok(Credentials::with_access_token(token.access_token))
}

#[tokio::main]
async fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("librespot=info,tatwo_spotify=info"))
        .target(env_logger::Target::Stderr)
        .init();

    let options = match parse_options() {
        Ok(options) => options,
        Err(message) => {
            emit("error", serde_json::json!({ "message": message }));
            std::process::exit(2);
        }
    };

    // 只存憑證與音量；不存音樂檔，避免佔空間。
    let cache = match Cache::new(Some(&options.cache), Some(&options.cache), None, None) {
        Ok(cache) => cache,
        Err(e) => {
            emit("error", serde_json::json!({ "message": format!("快取資料夾不能用：{e}") }));
            std::process::exit(2);
        }
    };
    let credentials_file = options.cache.join("credentials.json");

    let session_config = SessionConfig::default();
    let player_config = PlayerConfig { bitrate: Bitrate::Bitrate320, position_update_interval: Some(Duration::from_secs(1)), ..PlayerConfig::default() };
    let connect_config = ConnectConfig {
        name: options.name.clone(),
        device_type: DeviceType::Computer,
        initial_volume: cache.volume().unwrap_or(u16::MAX),
        ..ConnectConfig::default()
    };
    let sink_builder = match audio_backend::find(Some("rodio".to_string())) {
        Some(builder) => builder,
        None => {
            emit("error", serde_json::json!({ "message": "找不到音訊輸出" }));
            std::process::exit(2);
        }
    };
    let mixer = match mixer::find(None).map(|build| build(MixerConfig::default())) {
        Some(Ok(mixer)) => mixer,
        _ => {
            emit("error", serde_json::json!({ "message": "音量控制初始化失敗" }));
            std::process::exit(2);
        }
    };

    let mut commands = spawn_stdin_reader();
    let mut credentials = cache.credentials();
    let mut session = Session::new(session_config.clone(), Some(cache.clone()));
    let player = Player::new(player_config, session.clone(), mixer.get_soft_volume(), move || {
        sink_builder(None, AudioFormat::default())
    });
    let mut player_events = player.get_player_event_channel();

    let mut spirc: Option<Spirc> = None;
    let mut spirc_task: Option<SpircFuture> = None;
    let mut connecting: Option<tokio::task::JoinHandle<Result<(Spirc, SpircFuture), Error>>> = None;
    let mut cluster_updates: Option<ClusterStream> = None;
    let mut backoff = Backoff::default();
    let mut retry_at = tokio::time::Instant::now();
    let mut connected_at = Instant::now();
    let mut registered = false;
    let mut registration_deadline = tokio::time::Instant::now();
    let mut login_task: Option<tokio::task::JoinHandle<Result<Credentials, String>>> = None;
    let mut transfer_pending: Option<Transfer> = None;
    let mut transfer_task: Option<tokio::task::JoinHandle<Result<(), Error>>> = None;
    let mut transferring: Option<Transfer> = None;
    let mut transfer_deadline = tokio::time::Instant::now();
    let mut transfer_accepted = false;
    let mut active_device: Option<String> = None;
    let mut active = false;
    let mut active_playing = false;
    // SessionDisconnected is also emitted during unexpected shutdown.
    // Only a cluster naming another device revokes pre-disconnect ownership.
    let mut owned = false;
    let mut player_active = false;
    let mut playback: Option<Playback> = None;
    let mut saved: Option<Playback> = None;
    let mut restoring: Option<Playback> = None;
    let mut connection_check = tokio::time::interval(Duration::from_secs(1));
    connection_check.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    emit(if credentials.is_some() { "starting" } else { "needs_login" }, serde_json::json!({}));

    loop {
        tokio::select! {
            _ = connection_check.tick(), if spirc.is_some() => {
                // Do not wait for librespot's asynchronous disconnect cleanup to finish.
                if session.is_invalid() {
                    retry_at = reconnect(&session, || player.stop(), &mut backoff, connected_at, "session-invalid",
                        &mut saved, playback.as_ref(), &mut restoring, &mut spirc, &mut spirc_task, &mut cluster_updates,
                        &mut active, &mut owned, &mut player_active, &mut active_device, &mut transfer_task, &mut transferring);
                }
            },
            _ = tokio::time::sleep_until(retry_at), if spirc.is_none() && connecting.is_none() && credentials.is_some() && login_task.is_none() => {
                if session.is_invalid() {
                    session = Session::new(session_config.clone(), Some(cache.clone()));
                    player.set_session(session.clone());
                }
                let (config, session, credentials, player, mixer) =
                    (connect_config.clone(), session.clone(), credentials.clone().unwrap(), player.clone(), mixer.clone());
                connecting = Some(tokio::spawn(async move {
                    let (spirc, task) = tokio::time::timeout(Duration::from_secs(30),
                        Spirc::new(config, session, credentials, player, mixer)).await
                        .map_err(|_| Error::deadline_exceeded("connect timeout"))??;
                    Ok((spirc, Box::pin(task) as SpircFuture))
                }));
            },
            result = async { connecting.as_mut().unwrap().await }, if connecting.is_some() => {
                connecting = None;
                match result.unwrap_or_else(|e| Err(Error::unavailable(e.to_string()))) {
                    Ok((new_spirc, task)) => {
                        connected_at = Instant::now();
                        registered = false;
                        registration_deadline = tokio::time::Instant::now() + Duration::from_secs(30);
                        cluster_updates = session.dealer().listen_for("hm://connect-state/v1/cluster", Message::from_raw::<ClusterUpdate>).ok();
                        spirc = Some(new_spirc);
                        spirc_task = Some(task);
                    }
                    Err(e) => {
                        log::warn!("connect failed: {e}");
                        session.shutdown();
                        if recovery::authentication_failed(e.kind, &credentials_file) {
                            // Only authentication failures require login. Never delete credentials for transport errors.
                            credentials = None;
                            saved = None;
                            emit("needs_login", serde_json::json!({}));
                        } else {
                            let delay = backoff.next();
                            retry_at = tokio::time::Instant::now() + delay;
                            emit("reconnecting", serde_json::json!({ "delay": delay.as_secs(), "reason": "connect-failed" }));
                        }
                    }
                }
            },
            command = commands.recv() => {
                let command = command.unwrap_or(Command::Quit);
                if matches!(&command, Command::CancelResume) ||
                    matches!(&command, Command::Transfer(request) if !request.resume) {
                    saved = None; restoring = None;
                    if session.is_invalid() { owned = false; }
                    if transfer_pending.as_ref().is_some_and(|pending| pending.resume) {
                        transfer_pending = None;
                    }
                    if transferring.as_ref().is_some_and(|current| current.resume) {
                        if let Some(task) = transfer_task.take() { task.abort(); }
                        if let Some(current) = transferring.take() {
                            transfer_result(&current, Err(Error::cancelled("resume cancelled")));
                        }
                    }
                }
                match command {
                Command::Login => {
                    if login_task.is_none() {
                        let client_id = session_config.client_id.clone();
                        let port = options.port;
                        login_task = Some(tokio::task::spawn_blocking(move || login_blocking(client_id, port)));
                    }
                }
                Command::Logout => {
                    saved = None; restoring = None; playback = None; active = false; owned = false; player_active = false; active_device = None;
                    transfer_pending = None;
                    if let Some(task) = connecting.take() { task.abort(); }
                    if let Some(task) = transfer_task.take() { task.abort(); }
                    if let Some(request) = transferring.take() { transfer_result(&request, Err(Error::cancelled("logged out"))); }
                    if let Some(s) = spirc.take() { let _ = s.shutdown(); }
                    if let Some(task) = spirc_task.take() { tokio::spawn(task); }
                    cluster_updates = None;
                    if !session.is_invalid() { session.shutdown(); }
                    player.stop();
                    let _ = std::fs::remove_file(&credentials_file);
                    credentials = None;
                    emit("logged_out", serde_json::json!({}));
                }
                Command::Transfer(request) => {
                    transfer_pending = Some(request);
                }
                Command::CancelResume => {}
                Command::Reconnect => {
                    if saved.is_none() { saved = resume_snapshot(owned, playback.as_ref()); }
                    restoring = None;
                    if let Some(task) = connecting.take() { task.abort(); }
                    if let Some(task) = transfer_task.take() { task.abort(); }
                    if let Some(request) = transferring.take() { transfer_result(&request, Err(Error::not_found("session replaced"))); }
                    if let Some(s) = spirc.take() { let _ = s.shutdown(); }
                    if let Some(task) = spirc_task.take() { tokio::spawn(task); }
                    cluster_updates = None;
                    session.shutdown();
                    player.stop();
                    active = false; owned = false; player_active = false; active_device = None;
                    backoff.reset();
                    retry_at = tokio::time::Instant::now();
                    emit("reconnecting", serde_json::json!({ "delay": 0, "reason": "requested" }));
                }
                Command::Quit => break,
                }
            },
            result = async { login_task.as_mut().unwrap().await }, if login_task.is_some() => {
                login_task = None;
                match result {
                    Ok(Ok(new_credentials)) => {
                        credentials = Some(new_credentials);
                        backoff.reset(); retry_at = tokio::time::Instant::now();
                        emit("logged_in", serde_json::json!({}));
                    }
                    Ok(Err(message)) => emit("login_failed", serde_json::json!({ "message": message })),
                    Err(e) => emit("login_failed", serde_json::json!({ "message": e.to_string() })),
                }
            },
            _ = async { spirc_task.as_mut().unwrap().await }, if spirc_task.is_some() => {
                retry_at = reconnect(&session, || player.stop(), &mut backoff, connected_at, "task-ended",
                    &mut saved, playback.as_ref(), &mut restoring, &mut spirc, &mut spirc_task, &mut cluster_updates,
                    &mut active, &mut owned, &mut player_active, &mut active_device, &mut transfer_task, &mut transferring);
            },
            update = async { cluster_updates.as_mut().unwrap().next().await }, if cluster_updates.is_some() => {
                match update {
                    Some(Ok(update)) if !session.is_invalid() => {
                        if !registered && update.cluster.device.contains_key(session.device_id()) {
                            registered = true;
                            emit("connected", serde_json::json!({ "device": options.name, "device_id": session.device_id(), "resume": saved.is_some() }));
                        }
                        let id = &update.cluster.active_device_id;
                        active_playing = !id.is_empty() && update.cluster.player_state.is_playing && !update.cluster.player_state.is_paused;
                        active_device = (!id.is_empty()).then(|| id.clone());
                        active = id == session.device_id();
                        owned = active;
                        let web = update.cluster.device.get(id).is_some_and(|info|
                            is_web_player(&info.name, &info.model));
                        emit("device", serde_json::json!({ "active": active, "web": web, "playing": active_playing }));
                    }
                    None => cluster_updates = None,
                    _ => {}
                }
            },
            _ = tokio::time::sleep_until(registration_deadline), if spirc.is_some() && !registered && !session.is_invalid() => {
                if let Some(connected) = registration_timeout(&session, &mut registered, saved.is_some(), &options.name) {
                    log::warn!("registration unconfirmed; continuing");
                    emit("connected", connected);
                }
            },
            result = async { transfer_task.as_mut().unwrap().await }, if transfer_task.is_some() => {
                transfer_task = None;
                let result = result.unwrap_or_else(|e| Err(Error::unavailable(e.to_string())));
                match result {
                    Ok(()) => transfer_accepted = true,
                    Err(e) => if let Some(request) = transferring.take() { transfer_result(&request, Err(e)); },
                }
            },
            _ = tokio::time::sleep_until(transfer_deadline), if transferring.is_some() => {
                if let Some(task) = transfer_task.take() { task.abort(); }
                restoring = None;
                if let Some(request) = transferring.take() { transfer_result(&request, Err(Error::deadline_exceeded("device did not take over"))); }
            },
            Some(event) = player_events.recv() => {
                let playing = matches!(&event, PlayerEvent::Playing { .. });
                match event {
                PlayerEvent::Playing { track_id, position_ms, .. } | PlayerEvent::Paused { track_id, position_ms, .. } if !session.is_invalid() && player_active => {
                    playback = Some(Playback { track: track_id.to_uri().unwrap_or_default(), position_ms, playing, updated: Instant::now() });
                    emit(if playing { "playing" } else { "paused" }, serde_json::json!({}));
                    if playing && restoring.as_ref().is_some_and(|p|
                        playback.as_ref().is_some_and(|current| current.track == p.track &&
                            current.position_ms.abs_diff(p.position_ms) < 2000)) {
                        restoring = None; saved = None;
                        if let Some(request) = transferring.take() { transfer_result(&request, Ok(())); }
                    }
                }
                PlayerEvent::PositionChanged { position_ms, .. } | PlayerEvent::PositionCorrection { position_ms, .. } | PlayerEvent::Seeked { position_ms, .. } if !session.is_invalid() => {
                    if let Some(p) = playback.as_mut() { p.position_ms = position_ms; p.updated = Instant::now(); }
                }
                PlayerEvent::Stopped { .. } | PlayerEvent::Unavailable { .. } if !session.is_invalid() => {
                    if let Some(p) = playback.as_mut() { p.playing = false; }
                    emit("stopped", serde_json::json!({}));
                }
                PlayerEvent::SessionConnected { connection_id, .. } if !session.is_invalid() && connection_id == session.connection_id() => {
                    active = true; owned = true; player_active = true;
                    emit("active", serde_json::json!({}));
                }
                PlayerEvent::SessionDisconnected { connection_id, .. } if !session.is_invalid() && connection_id == session.connection_id() => {
                    active = false; player_active = false;
                    emit("inactive", serde_json::json!({}));
                }
                _ => {}
                }
            },
        }

        if spirc.is_some() && registered && transferring.is_none() {
            if let Some(request) = transfer_pending.take() {
                if request.device_id.as_deref().is_some_and(|id| id != session.device_id()) {
                    transfer_result(&request, Err(Error::not_found("stale device id")));
                } else {
                    transfer_deadline = tokio::time::Instant::now() + Duration::from_secs(10);
                    transfer_accepted = active && player_active;
                    if !transfer_accepted {
                        let (session, from) = (session.clone(), active_device.clone());
                        transfer_task = Some(tokio::spawn(transfer_here(session, from, request.reason.clone(), active_playing)));
                    }
                    transferring = Some(request);
                }
            }
        }
        if active && player_active && transfer_accepted && restoring.is_none() {
            if let Some(request) = transferring.take() {
                if request.resume {
                    if let (Some(s), Some(p)) = (spirc.as_ref(), saved.as_ref()) {
                        match s.load(LoadRequest::from_tracks(vec![p.track.clone()], LoadRequestOptions {
                            start_playing: true, seek_to: p.position_ms, ..Default::default()
                        })) {
                            Ok(()) => { restoring = Some(p.clone()); transferring = Some(request); }
                            Err(e) => transfer_result(&request, Err(e)),
                        }
                    } else { transfer_result(&request, Ok(())); }
                } else { transfer_result(&request, Ok(())); }
            }
        }
    }
    if let Some(task) = connecting.take() { task.abort(); }
    if let Some(task) = transfer_task.take() { task.abort(); }

    if let Some(s) = spirc.take() { let _ = s.shutdown(); }
    if let Some(task) = spirc_task.take() {
        let _ = tokio::time::timeout(Duration::from_secs(3), task).await;
    }
    emit("stopped_helper", serde_json::json!({}));
    // 讀 stdin 的背景執行緒會卡住 runtime 的收尾；說好要走就直接走。
    std::process::exit(0);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn live_registration_timeouts_continue_once_and_invalid_sessions_schedule_retries() {
        let mut backoff = Backoff::default();
        let (mut saved, mut restoring, mut spirc, mut device, mut transferring) = (None, None, None, None, None);
        let playback = Playback { track: "fixture".into(), position_ms: 42, playing: true, updated: Instant::now() };
        for delay in [1, 2, 4] {
            let session = Session::new(SessionConfig::default(), None);
            let mut task: Option<SpircFuture> = Some(Box::pin(std::future::pending()));
            let mut cluster: Option<ClusterStream> = Some(Box::pin(futures_util::stream::empty()));
            let (mut active, mut owned, mut player_active, mut stopped) = (true, true, true, false);
            let mut transfer = Some(tokio::spawn(std::future::pending::<Result<(), Error>>()));
            let mut registered = false;
            let connected = registration_timeout(&session, &mut registered, false, "fixture-device").unwrap();
            assert!(registered && connected["unconfirmed"] == true && connected["resume"] == false && connected["device_id"] == session.device_id());
            for _ in 0..400 { assert!(registration_timeout(&session, &mut registered, false, "fixture-device").is_none() && !session.is_invalid() && task.is_some() && cluster.is_some() && !stopped); }
            session.shutdown(); registered = false; assert!(registration_timeout(&session, &mut registered, false, "fixture-device").is_none());
            let before = tokio::time::Instant::now();
            let retry = reconnect(&session, || stopped = true, &mut backoff, Instant::now(), "session-invalid",
                &mut saved, Some(&playback), &mut restoring, &mut spirc, &mut task, &mut cluster,
                &mut active, &mut owned, &mut player_active, &mut device, &mut transfer, &mut transferring);
            assert!(task.is_none() && cluster.is_none() && transfer.is_none() && spirc.is_none());
            assert!(session.is_invalid() && stopped && !active && !owned && !player_active);
            assert!(saved.is_some() && (retry - before).as_secs() == delay);
        }
    }

    #[test]
    fn automatic_idle_transfer_pauses_playing_transfer_preserves_and_gesture_plays() {
        for reason in ["tab-open", "retake"] {
            assert_eq!(serde_json::to_value(transfer_options(reason, false).unwrap()).unwrap()["transfer_options"]["restore_paused"], "pause");
            assert!(transfer_options(reason, true).is_none());
        }
        assert_eq!(transfer_options("gesture", false).unwrap().transfer_options.restore_paused.as_deref(), Some("resume"));
        assert_eq!(transfer_options("gesture", true).unwrap().transfer_options.restore_paused.as_deref(), Some("resume"));
    }

    #[test]
    fn real_http_404_and_410_become_the_not_found_wire_flag() {
        for status in [404u16, 410u16] {
            let error: Error = librespot::core::http_client::HttpClientError::StatusCode(
                status.try_into().unwrap()
            ).into();
            assert_eq!(error.kind, ErrorKind::NotFound);
        }
    }

    #[test]
    fn stdin_json_transfer_preserves_request_target_and_resume_semantics() {
        let Some(Command::Transfer(request)) = parse_command(
            r#"{"command":"transfer","id":"request-1","device_id":"live-device","resume":false,"reason":"tab-open"}"#
        ) else { panic!("expected transfer"); };
        assert_eq!(request.id, "request-1");
        assert_eq!(request.device_id.as_deref(), Some("live-device"));
        assert!(!request.resume);
        assert_eq!(request.reason, "tab-open");
        let Some(Command::Transfer(request)) = parse_command(
            r#"{"command":"transfer","id":"resume-1","resume":true}"#
        ) else { panic!("expected resume"); };
        assert!(request.resume);
        assert!(matches!(parse_command(r#"{"command":"reconnect"}"#), Some(Command::Reconnect)));
        assert!(matches!(parse_command(r#"{"command":"cancel_resume"}"#), Some(Command::CancelResume)));
        assert!(matches!(parse_command("quit"), Some(Command::Quit)));
    }
}
