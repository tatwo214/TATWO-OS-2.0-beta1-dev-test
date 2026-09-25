#!/usr/bin/env python3
"""W176：把 TATWO OS 內建的 Spotify 裝置（Engines/spotify-helper，librespot）編好放進 App。

prepare <app>：依原始碼雜湊快取編譯結果；沒有快取才用 cargo 編（--locked，版本照 Cargo.lock）。
finalize <app> <identity>：用 App 同一張憑證簽章並驗證。

Rust 工具：TATWO2_RUST_HOME（內含 rustup/ 與 cargo/）→ PATH 上的 cargo → ~/.cargo/bin/cargo。
找不到時失敗；只有明確設 TATWO2_SKIP_SPOTIFY_HELPER=1 才略過（開發用，正式打包不可略過）。
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Engines/spotify-helper"
HELPER = "Contents/Helpers/tatwo-spotify"
RESOURCES = "Contents/Resources/spotify-helper"


def sha256(file):
    digest = hashlib.sha256()
    with Path(file).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_digest():
    digest = hashlib.sha256()
    files = [SOURCE / "Cargo.toml", SOURCE / "Cargo.lock"] + sorted((SOURCE / "src").rglob("*.rs"))
    for file in files:
        digest.update(str(file.relative_to(SOURCE)).encode() + b"\0" + file.read_bytes() + b"\0")
    return digest.hexdigest()


def cargo_command():
    env = dict(os.environ)
    home = env.get("TATWO2_RUST_HOME")
    if home:
        env["RUSTUP_HOME"] = str(Path(home) / "rustup")
        env["CARGO_HOME"] = str(Path(home) / "cargo")
        cargo = Path(home) / "cargo/bin/cargo"
        if cargo.exists():
            return str(cargo), env
    found = shutil.which("cargo")
    if found:
        return found, env
    fallback = Path.home() / ".cargo/bin/cargo"
    if fallback.exists():
        return str(fallback), env
    return None, env


def prepare(app, cache_base):
    digest = source_digest()
    cache = cache_base / digest[:16]
    binary = cache / "tatwo-spotify"
    if not binary.exists():
        cargo, env = cargo_command()
        if cargo is None:
            if os.environ.get("TATWO2_SKIP_SPOTIFY_HELPER") == "1":
                print("spotify helper: 略過（TATWO2_SKIP_SPOTIFY_HELPER=1，找不到 cargo）", file=sys.stderr)
                return
            raise RuntimeError("找不到 cargo：設 TATWO2_RUST_HOME，或開發時設 TATWO2_SKIP_SPOTIFY_HELPER=1")
        target = cache_base / "target"
        subprocess.run([cargo, "build", "--release", "--locked", "--target-dir", str(target)],
                       cwd=SOURCE, env=env, check=True)
        cache.mkdir(parents=True, exist_ok=True)
        temp = binary.with_suffix(".partial")
        shutil.copyfile(target / "release/tatwo-spotify", temp)
        temp.replace(binary)
    helper = app / HELPER
    resources = app / RESOURCES
    helper.parent.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(binary, helper)
    helper.chmod(0o755)
    shutil.copyfile(SOURCE / "LICENSE-librespot", resources / "LICENSE-librespot")
    manifest = {"source": "Engines/spotify-helper", "sourceSHA256": digest, "librespot": "0.8.0",
                "unsignedSHA256": sha256(binary), "helper": HELPER, "signedSHA256": None}
    (resources / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def finalize(app, identity):
    helper = app / HELPER
    manifest_file = app / RESOURCES / "manifest.json"
    if not helper.exists():
        if os.environ.get("TATWO2_SKIP_SPOTIFY_HELPER") == "1":
            return
        raise RuntimeError("App 裡沒有 Spotify 裝置程式（prepare 沒跑？）")
    manifest = json.loads(manifest_file.read_text())
    if sha256(helper) != manifest["unsignedSHA256"]:
        raise RuntimeError("helper changed before signing")
    subprocess.run(["codesign", "--force", "--sign", identity, "--timestamp=none", str(helper)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(helper)], check=True)
    manifest["signedSHA256"] = sha256(helper)
    manifest_file.write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    mode, bundle = sys.argv[1:3]
    if mode == "prepare":
        base = os.environ.get("TATWO2_DOWNLOAD_CACHE") or os.environ.get("TMPDIR")
        if not base:
            raise RuntimeError("set TMPDIR or TATWO2_DOWNLOAD_CACHE on external staging volume")
        prepare(Path(bundle), Path(base) / "tatwo-spotify-builds")
    elif mode == "finalize":
        finalize(Path(bundle), sys.argv[3])
    else:
        raise SystemExit("expected prepare or finalize")
