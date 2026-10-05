use std::time::{Duration, Instant};

#[derive(Default)]
pub struct Backoff(u32);

impl Backoff {
    pub fn next(&mut self) -> Duration {
        let seconds = (1u64 << self.0.min(6)).min(60);
        self.0 = self.0.saturating_add(1);
        Duration::from_secs(seconds)
    }

    pub fn reset(&mut self) {
        self.0 = 0;
    }
}

#[derive(Clone)]
pub struct Playback {
    pub track: String,
    pub position_ms: u32,
    pub playing: bool,
    pub updated: Instant,
}

impl Playback {
    pub fn freeze(&self) -> Self {
        let elapsed = if self.playing { self.updated.elapsed().as_millis() } else { 0 };
        Self {
            position_ms: (u128::from(self.position_ms) + elapsed).min(u128::from(u32::MAX)) as u32,
            updated: Instant::now(),
            ..self.clone()
        }
    }
}

pub fn resume_snapshot(active: bool, playback: Option<&Playback>) -> Option<Playback> {
    playback.filter(|p| active && p.playing).map(Playback::freeze)
}

pub fn is_web_player(name: &str, model: &str) -> bool {
    let model = model.to_ascii_lowercase();
    model == "web_player" || model == "web player" || model.starts_with("web_player/")
        || name.to_ascii_lowercase().starts_with("web player (")
}

pub fn authentication_failed(kind: librespot::core::error::ErrorKind, credentials: &std::path::Path) -> bool {
    if kind == librespot::core::error::ErrorKind::Unauthenticated { let _ = std::fs::remove_file(credentials); true } else { false }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unauthenticated_deletes_cached_credentials_but_transport_errors_keep_them() {
        use librespot::core::error::ErrorKind;
        let nonce = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let root = std::env::temp_dir().join(format!("w210-auth-{}-{nonce}", std::process::id()));
        std::fs::create_dir(&root).unwrap();
        let credentials = root.join("credentials.json");
        std::fs::write(&credentials, b"synthetic test credentials").unwrap();
        assert!(!authentication_failed(ErrorKind::Unavailable, &credentials));
        assert_eq!(std::fs::read(&credentials).unwrap(), b"synthetic test credentials");
        assert!(authentication_failed(ErrorKind::Unauthenticated, &credentials));
        assert!(!credentials.exists(), "authentication failure must not leave a reusable disk cache");
        assert!(authentication_failed(ErrorKind::Unauthenticated, &credentials));
        std::fs::remove_dir(&root).unwrap();
    }

    #[test]
    fn reconnect_never_gives_up_and_caps_at_sixty_seconds() {
        let mut backoff = Backoff::default();
        let sequence: Vec<_> = (0..10).map(|_| backoff.next().as_secs()).collect();
        assert_eq!(sequence, [1, 2, 4, 8, 16, 32, 60, 60, 60, 60]);
        for _ in 0..1000 { assert_eq!(backoff.next().as_secs(), 60); }
        backoff.reset();
        assert_eq!(backoff.next().as_secs(), 1);
    }

    #[test]
    fn resume_only_if_we_owned_playing_track() {
        let mut playback = Playback {
            track: "spotify:track:fixture".into(), position_ms: 42000, playing: true,
            updated: Instant::now() - Duration::from_secs(3),
        };
        let saved = resume_snapshot(true, Some(&playback)).unwrap();
        assert_eq!(saved.track, playback.track);
        assert!((45000..45100).contains(&saved.position_ms));
        assert_eq!(playback.position_ms, 42000);
        assert!(resume_snapshot(false, Some(&playback)).is_none());
        playback.playing = false;
        assert!(resume_snapshot(true, Some(&playback)).is_none());
        assert!(resume_snapshot(true, None).is_none());
    }

    #[test]
    fn retake_only_identifies_web_players_not_webos_or_native_devices() {
        assert!(is_web_player("Dia", "web_player"));
        assert!(is_web_player("Web Player (Chrome)", ""));
        assert!(!is_web_player("Living room", "webOS"));
        assert!(!is_web_player("iPhone", "iPhone17,1"));
        assert!(!is_web_player("TATWO OS", "librespot"));
    }
}
