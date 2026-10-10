1. Dots／Grok：Linux 或 macOS 一般使用者需有 Python 3.9+、git；執行 `sh Engines/sandbox-agent/install.sh`，不用 sudo。
2. 主設備「設定 › 設備 › 沙盒 › Linux／macOS › 自己的設備 › 加一台」填名稱與來源，再按建立沙盒專用配對。
3. 執行 `python3 ~/.tatwo-sandbox/sandbox-agent.py pair --gateway https://你的關口`；核對交易後輸入配對碼；W264 回呼僅為識別值，不連 ChatGPT、不改帳號設定。
4. 執行 `python3 ~/.tatwo-sandbox/sandbox-agent.py run --runner 'sh'`（使用者派 shell 工作）；AI 工作改填接受 stdin 指示的本機引擎指令，預設時限 600 秒。
5. 只領指定快照、交補丁與報告、心跳；存取權杖每小時自動換新，被撤銷或拒絕就停，成果保留本機並在主設備等套用；虛擬設備也用同一支，開關機留 W336。
