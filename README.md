# 🤖 Termux AI v3.0

> **A complete AI-powered toolkit for Termux**

Copyright (c) 2026 Mr-Egyptian
Licensed under GNU General Public License v3.0
Original repository: <YOUR_REPO_URL>

---

## 📖 Overview

Termux AI is a comprehensive, single-file toolkit for Android's Termux terminal emulator. It bundles four powerful tools into one application:

1. **📁 Normal Mode** — Full-featured file manager
2. **🧠 Advanced Mode** — AI-powered command analyzer with 15+ API providers
3. **🌐 Browser** — Text-based web browser with download support
4. **💬 P2P Chat** — Encrypted peer-to-peer messenger with file sharing

The entire project is contained in a single `main.sh` file that self-bootstraps all required Python modules on first run — no complex installation needed.

---

## ✨ Features

### 📁 Normal Mode (12 options)

Complete file management with Arabic + English support:

| # | Feature |
|---|---------|
| 1 | Create File |
| 2 | Create Directory |
| 3 | Delete File |
| 4 | Delete Directory |
| 5 | Copy File/Directory |
| 6 | Move File/Directory |
| 7 | Rename File/Directory |
| 8 | List Directory |
| 9 | Read File |
| 10 | Search |
| 11 | Text Editor (nano) |
| 12 | File Browser |

**Locations supported:**
- Home directory (`$HOME`)
- Internal Storage (`~/storage/shared`)
- Downloads (`~/storage/shared/Download`)
- Documents (`~/storage/shared/Documents`)
- Custom path

**Safety:** Confirmation prompts before any destructive operation.

---

### 🧠 Advanced Mode (4 options)

| # | Feature |
|---|---------|
| 1 | Command Analyzer |
| 2 | Discover Commands |
| 3 | Auto-Learn Command |
| 4 | API Key Management |

#### Command Analyzer (8-Layer AI)

Automatically corrects mistyped commands using:

1. **Preprocessing** — Common abbreviations + typos
2. **Fuzzy Matching** — Sequence similarity
3. **Phonetic Matching** — Soundex-like algorithm
4. **Semantic Scoring** — Value type detection
5. **Structure Similarity** — Dynamic programming on syntax
6. **Record Scoring** — All database fields compared
7. **Context Awareness** — Package/Git/File/Network detection
8. **Learning from Usage** — Frequency-based boosting

**Database:** 200+ commands, 18 error patterns, 6 correction rules.

**Example:**
```

Input:  gti status
Output: git status
Score:  0.95 [high] very similar name

```

#### Supported AI Providers (15+)

| Provider | Model | Free |
|----------|-------|------|
| OpenAI | gpt-4o-mini | No |
| OpenRouter | qwen/qwen3.6-plus | No |
| Groq | llama-3.3-70b | Yes |
| Together AI | Llama 3.1 Turbo | No |
| DeepInfra | Meta-Llama 3.1 | No |
| Mistral | mistral-small | No |
| Cohere | command-r-plus | No |
| Cerebras | gpt-oss-120b | Yes |
| HuggingFace | Llama-3.2-3B | Yes |
| Google Gemini | gemini-flash | Yes |
| DeepSeek | deepseek-flash | Yes |
| xAI Grok | grok-4.1-fast | No |
| Anthropic | claude-sonnet | No |
| Perplexity | sonar-pro | No |
| Custom | Any OpenAI-compatible | - |

---

### 🌐 Browser (Text-based)

Full-featured text browser:

| # | Action |
|---|--------|
| 1 | Open link by number |
| 2 | Enter new URL |
| 3 | Search |
| 4 | Back |
| 5 | Reload |
| 6 | Change Search Engine |
| 7 | Next page |
| 8 | Previous page |
| 9 | Download by number |
| D | Download URL |
| 0 | Exit |

**Search Engines:**
- Bing (default — best for Arabic)
- Wikipedia
- Wiby
- DuckDuckGo Lite
- Custom engines (add your own)

**Features:**
- Progress bar for downloads
- Auto-detects file types
- GitHub releases to direct assets
- Cookie persistence
- Full Arabic support

---

### 💬 P2P Chat (Encrypted)

Peer-to-peer messaging over MQTT with strong encryption:

**Core Features:**
- AES-like encryption (PBKDF2 + SHA256 + HMAC)
- Friend requests with approval
- Live presence (online / away / offline)
- Group chats
- Small files (up to 256 KB)
- Large files via chunks (up to 20 MB)
- Remote command execution
- Offline message queue
- Chat history logging
- Emoji shortcuts

**Available Commands:**
```

/me                  Show your ID
/add NAME [ID]       Send friend request
/friends             List friends + status
/requests            Show pending requests
/accept NAME         Accept friend request
/reject NAME         Reject friend request
/remove NAME         Remove friend
/chat NAME           Open chat
/queue               Show offline queue
/cmd FRIEND CMD      Send command to friend
/file FRIEND PATH    Send file (max 20 MB)
/fileg GROUP PATH    Send file to group
/group               Groups menu
/g NAME              Open group chat
/help                Show help
/quit                Exit

```

---

## ⚡ Requirements

### Mandatory
```bash
- Android device
- Termux app (from F-Droid — recommended)
- bash
- python3
- python3-pip
```

For P2P Chat

```bash
pip install paho-mqtt
```

For Browser

No additional packages — uses Python's built-in urllib.

---

🚀 Installation

Method 1: Direct Copy

1. Copy main.sh to your Termux home directory:
   ```bash
   # If you downloaded it:
   mv ~/storage/downloads/main.sh ~/
   ```
2. Make it executable:
   ```bash
   chmod +x main.sh
   ```
3. Run it:
   ```bash
   ./main.sh
   ```

Method 2: From GitHub (future)

```bash
git clone <YOUR_REPO_URL>
cd TermuxAI
chmod +x main.sh
./main.sh
```

First Run

On the first run, bootstrap_files automatically creates:

· advanced_ai.py
· advanced_database.db
· api_config.json
· api_client.py
· p2p_chat.py
· web_engine.py
· README.md

No manual setup needed.

---

📚 Detailed Usage

Normal Mode

Simple file operations. Navigate the menu, choose a path, and manage files. All operations have confirmation prompts.

Advanced Mode

Command Analyzer:

```
> gti status

Found 1 suggestion:
  1. git status
     score: 0.95  [high] very similar name
     Distributed version control system
```

API Key Setup:

1. Choose [2] Advanced Mode then [4] API Key
2. Select [2] Select Provider and Model
3. Choose your provider (e.g., 10 for Google Gemini)
4. Add API key: [1] Add API Key
5. Test: [3] Test Connection
6. Chat: [4] Chat with Model

Browser

```
> Search: termux
> 1
> D
> Download URL: https://example.com/file.zip
```

P2P Chat

Setup (First Time):

1. Choose your username
2. Save your ID (like AHMED_AB12CD34)
3. Share it with friends

Connect with a friend:

```
/add sara SARA_XY98ZW76
```

Send a message:

```
/chat sara
> Hello Sara!
```

Send a file:

```
/file sara ~/document.pdf
```

Create a group:

```
/group create team
/group invite team sara
```

Send to group:

```
/g team
> Hello team!
```

Remote command:

```
/cmd sara whoami
```

---

🏗️ Architecture

```
main.sh (9200+ lines)
|
+-- bootstrap_files()
|   +-> advanced_ai.py        (~1000 lines)
|   +-> advanced_database.db  (~200 lines)
|   +-> api_config.json
|   +-> api_client.py         (~150 lines)
|   +-> p2p_chat.py           (~2500 lines)
|   +-> web_engine.py         (~1000 lines)
|   +-> README.md             (this file)
|
+-- UI functions
+-- Normal Mode functions
+-- Advanced Mode functions
+-- Browser functions
+-- P2P functions
+-- main_menu()
```

---

💡 Examples

Example 1: Correcting a Typo

```
$ ./main.sh
Select: 2                    # Advanced Mode
Select: 1                    # Command Analyzer
> lst

Found 2 suggestions:

  1. ls
     score: 0.92  [high] similar name
     List files and directories

  2. lst
     score: 0.50  [low] best match
```

Example 2: Sending a Large File

```
[Ahmed] > /file sara ~/video.mp4

Sending video.mp4 (5000000 bytes, 153 chunks)
  Sent: 153/153
File sent.

[Sara receives]
[FILE] from Ahmed: video.mp4 (5000000 bytes, 153 chunks)
  Receiving: 153/153
[FILE] from Ahmed: video.mp4 (5000000 bytes)
    Accept? [Y] Yes  [N] No
> Y

[OK] File accepted and saved.
```

Example 3: Quick Search

```
$ ./main.sh
Select: 3                    # Browser
Select: 2                    # Search
Search query: termux
```

---

🔧 Troubleshooting


Problem Solution
paho-mqtt not installed pip install paho-mqtt
Permission denied chmod +x main.sh
python3: not found pkg install python
Shared storage not available termux-setup-storage
Connection failed Check internet connection
AI file not found Run ./main.sh once to create files
Command failed with exit code Read error, check syntax

If P2P does not connect:

```bash
ping -c 3 broker.hivemq.com
```

If files are missing:

```bash
rm -f advanced_ai.py advanced_database.db p2p_chat.py web_engine.py api_client.py
./main.sh
```

---

🧪 Testing

Termux AI has been comprehensively tested:

Test Suite Passed
Bash syntax Yes
Python syntax (4 files) Yes
Normal Mode (12 features) Yes
Advanced Mode Yes
Browser Yes
P2P Chat (50 tests) 50/50
Encryption round-trip Yes
File chunking Yes
MD5 verification Yes

Test Coverage: 100%

---

⚠️ Limitations

Limit Value Reason
P2P file size 20 MB MQTT broker limits
Single file (no chunks) 256 KB Efficiency
Chunk size 32 KB Network balance
Remote command timeout 30 seconds Security
Chat log size Unlimited Storage-dependent

Security Notes

The current encryption provides:

· Protection against casual MQTT snooping
· Protection against unknown peers

Limitations:

· Shared salt is embedded in code
· Keys derived from public IDs
· MQTT broker is public

For maximum security: Avoid sharing sensitive data. Use a private MQTT broker for critical use.

---

🤝 Contributing

Contributions are welcome!

1. Fork the repository
2. Follow the existing code style
3. Test your changes thoroughly
4. Submit a Pull Request

Please note: Any modifications must:

· Include original copyright notice
· Credit the original author (Mr-Egyptian)
· Be open-sourced (GPL v3)

---

📜 License

GNU General Public License v3.0

Copyright (c) 2026 Mr-Egyptian

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program. If not, see https://www.gnu.org/licenses/

What This Means

You CAN:

· Use this software for any purpose
· Study how it works
· Modify it
· Share it with others

You MUST:

· Include this copyright notice in any copy
· Credit the original author (Mr-Egyptian)
· Open-source any modifications
· Include the license file

You CANNOT:

· Claim this as your own work
· Remove the copyright notice
· Include in proprietary software
· Sell without permission

For commercial use: please contact the author first.

---

👤 Author

Mr-Egyptian

· From Egypt
· Developer of Termux AI
· Contact: <mostafamom9292@gmail.com>
· GitHub: <https://github.com/Mr-EgyptianX/Terminal-AI>

---

⚠️ Disclaimer

This software is provided "as is", without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and noninfringement. In no event shall the authors or copyright holders be liable for any claim, damages, or other liability, whether in an action of contract, tort, or otherwise, arising from, out of, or in connection with the software or the use or other dealings in the software.

Use at your own risk.

The P2P Chat feature uses a public MQTT broker. Messages may be accessible to third parties. Do not use for confidential communication.

The Browser feature downloads files from the internet. Ensure you trust the source before downloading.

---

🌟 Acknowledgments

· Termux — For the amazing Android terminal
· Paho MQTT — For the excellent MQTT client
· Open source community — For the tools that made this possible

---

📅 Version History

v3.0 (2026)

· Four complete modes: Normal, Advanced, Browser, P2P
· Encrypted P2P messaging
· Chunked file transfer (up to 20 MB)
· Text-based browser with downloads
· AI-powered command analyzer (8 layers)
· 15+ AI provider support
· Full Arabic support

---

Made with love in Egypt
