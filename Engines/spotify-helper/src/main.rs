//! W176：TATWO OS 內建的 Spotify Connect 裝置。
//!
//! OS 瀏覽器的 Spotify 網頁播放器只能播約 10 秒（Spotify 只把授權給有 Google 正式 VMP 簽章的瀏覽器）。
//! 這支程式用 librespot 在本機當一台叫「TATWO OS」的 Spotify 裝置，聲音由它自己播，不經瀏覽器的加密播放元件。
//!
//! 和 App 的約定（一行一筆）：
//! - stdin 指令：`login`、`logout`、`transfer`（把正在播的轉到這台）、`quit`。
//! - stdout 事件：JSON，例如 `{"event":"connected"}`、`active`／`inactive`（是不是正在播放的那台）；另外 librespot 會印一行 `Browse to: <登入網址>`，App 照原樣接。
//! - stderr：一般記錄（不含權杖）。
//! 登入只走 Spotify 官方 OAuth 頁；可重複使用的憑證由 librespot 存在 `--cache` 資料夾的 credentials.json。

use std::{
    path::PathBuf,
    time::{Duration, Instant},
};

use librespot::{
    connect::{ConnectConfig, Spirc},
    core::{
        authentication::Credentials, cache::Cache, config::DeviceType, config::SessionConfig,
        session::Session,
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

enum Command {
    Login,
    Logout,
    Transfer,
    Quit,
}

fn spawn_stdin_reader() -> mpsc::UnboundedReceiver<Command> {
    let (tx, rx) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        let mut lines = BufReader::new(tokio::io::stdin()).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let command = match line.trim() {
                "login" => Command::Login,
                "logout" => Command::Logout,
                "transfer" => Command::Transfer,
                "quit" => Command::Quit,
                "" => continue,
                other => {
                    emit("error", serde_json::json!({ "message": format!("不認得的指令 {other}") }));
                    continue;
                }
            };
            if tx.send(command).is_err() {
                break;
            }
        }
        // App 關掉 stdin（或 App 結束）＝結束。
        let _ = tx.send(Command::Quit);
    });
    rx
}

/// 目前正在播放的裝置。Spotify 每次狀態變動都會推一份 cluster；這支程式自己也訂一份，隨時知道是誰在播。
static ACTIVE_DEVICE: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

/// 把播放轉到這台。2026-09-23 實測：librespot 自己的 transfer（從自己轉給自己）會被 OS 裡的 Spotify 網頁播放器立刻搶回；
/// 從「正在播放的那台」轉給這台，才等於使用者在「裝置」清單手動選這台（網頁播放器不會再搶）。
async fn transfer_here(session: &Session, spirc: &Spirc) -> Result<(), String> {
    let own = session.device_id().to_string();
    let active = ACTIVE_DEVICE.lock().unwrap().clone();
    match active {
        Some(from) if from != own => session
            .spclient()
            .transfer(&from, &own, None)
            .await
            .map(|_| ())
            .map_err(|e| e.to_string()),
        Some(_) => Ok(()),
        None => spirc.transfer(None).map_err(|e| e.to_string()),
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
    let player_config = PlayerConfig { bitrate: Bitrate::Bitrate320, ..PlayerConfig::default() };
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
    let mut spirc_task: Option<std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>> = None;
    type ClusterStream = std::pin::Pin<Box<dyn futures_util::Stream<Item = Result<ClusterUpdate, librespot::core::Error>> + Send>>;
    let mut cluster_updates: Option<ClusterStream> = None;
    let mut reconnects: Vec<Instant> = Vec::new();
    let mut login_task: Option<tokio::task::JoinHandle<Result<Credentials, String>>> = None;
    let mut transfer_pending = false;
    // 轉播放要在主迴圈裡做（要用到目前的 session 與 spirc）。
    let (transfer_tx, mut transfer_rx) = mpsc::unbounded_channel::<()>();

    emit(if credentials.is_some() { "starting" } else { "needs_login" }, serde_json::json!({}));

    loop {
        // 有憑證但還沒連上：建立連線。
        if spirc.is_none() && credentials.is_some() && login_task.is_none() {
            if session.is_invalid() {
                session = Session::new(session_config.clone(), Some(cache.clone()));
                player.set_session(session.clone());
            }
            match Spirc::new(connect_config.clone(), session.clone(), credentials.clone().unwrap(), player.clone(), mixer.clone()).await {
                Ok((new_spirc, task)) => {
                    emit("connected", serde_json::json!({ "device": options.name }));
                    cluster_updates = session.dealer().listen_for("hm://connect-state/v1/cluster", Message::from_raw::<ClusterUpdate>).ok();
                    if transfer_pending {
                        transfer_pending = false;
                        transfer_tx.send(()).ok();
                    }
                    spirc = Some(new_spirc);
                    spirc_task = Some(Box::pin(task));
                }
                Err(e) => {
                    // 多半是憑證過期或被撤銷：丟掉舊憑證，請使用者重新登入。
                    log::warn!("connect failed: {e}");
                    let _ = std::fs::remove_file(&credentials_file);
                    credentials = None;
                    if !session.is_invalid() {
                        session.shutdown();
                    }
                    emit("needs_login", serde_json::json!({ "reason": e.to_string() }));
                }
            }
        }

        tokio::select! {
            command = commands.recv() => match command.unwrap_or(Command::Quit) {
                Command::Login => {
                    if login_task.is_none() {
                        let client_id = session_config.client_id.clone();
                        let port = options.port;
                        login_task = Some(tokio::task::spawn_blocking(move || login_blocking(client_id, port)));
                    }
                }
                Command::Logout => {
                    if let Some(s) = spirc.take() { let _ = s.shutdown(); }
                    if let Some(task) = spirc_task.take() { tokio::spawn(task); }
                    if !session.is_invalid() { session.shutdown(); }
                    let _ = std::fs::remove_file(&credentials_file);
                    credentials = None;
                    emit("logged_out", serde_json::json!({}));
                }
                Command::Transfer => match spirc.as_ref() {
                    Some(_) => { transfer_tx.send(()).ok(); }
                    None => transfer_pending = true,
                },
                Command::Quit => break,
            },
            result = async { login_task.as_mut().unwrap().await }, if login_task.is_some() => {
                login_task = None;
                match result {
                    Ok(Ok(new_credentials)) => {
                        credentials = Some(new_credentials);
                        emit("logged_in", serde_json::json!({}));
                    }
                    Ok(Err(message)) => emit("login_failed", serde_json::json!({ "message": message })),
                    Err(e) => emit("login_failed", serde_json::json!({ "message": e.to_string() })),
                }
            },
            _ = async { spirc_task.as_mut().unwrap().await }, if spirc_task.is_some() => {
                spirc_task = None;
                spirc = None;
                reconnects.retain(|t| t.elapsed() < Duration::from_secs(600));
                if reconnects.len() >= 5 {
                    emit("error", serde_json::json!({ "message": "和 Spotify 的連線一直斷，先停下來" }));
                    credentials = None;
                } else {
                    reconnects.push(Instant::now());
                    emit("reconnecting", serde_json::json!({}));
                    if !session.is_invalid() { session.shutdown(); }
                    tokio::time::sleep(Duration::from_secs(2)).await;
                }
            },
            Some(update) = async { cluster_updates.as_mut().unwrap().next().await }, if cluster_updates.is_some() => {
                if let Ok(update) = update {
                    let id = update.cluster.active_device_id.clone();
                    *ACTIVE_DEVICE.lock().unwrap() = if id.is_empty() { None } else { Some(id) };
                }
            },
            Some(()) = transfer_rx.recv() => {
                if let Some(s) = spirc.as_ref() {
                    match transfer_here(&session, s).await {
                        Ok(()) => emit("transferred", serde_json::json!({})),
                        Err(message) => emit("error", serde_json::json!({ "message": format!("轉到這台失敗：{message}") })),
                    }
                }
            },
            Some(event) = player_events.recv() => match event {
                PlayerEvent::Playing { .. } => emit("playing", serde_json::json!({})),
                PlayerEvent::Paused { .. } => emit("paused", serde_json::json!({})),
                PlayerEvent::Stopped { .. } => emit("stopped", serde_json::json!({})),
                PlayerEvent::Unavailable { .. } => emit("unavailable", serde_json::json!({})),
                // 變成／不再是正在播放的那台（別的裝置或網頁播放器把播放搶走時會收到 inactive）。
                PlayerEvent::SessionConnected { .. } => emit("active", serde_json::json!({})),
                PlayerEvent::SessionDisconnected { .. } => emit("inactive", serde_json::json!({})),
                _ => {}
            },
        }
    }

    if let Some(s) = spirc.take() { let _ = s.shutdown(); }
    if let Some(task) = spirc_task.take() {
        let _ = tokio::time::timeout(Duration::from_secs(3), task).await;
    }
    emit("stopped_helper", serde_json::json!({}));
    // 讀 stdin 的背景執行緒會卡住 runtime 的收尾；說好要走就直接走。
    std::process::exit(0);
}
