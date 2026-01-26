# openCluely

**The Context-Aware Stealth Copilot for macOS.**

openCluely is a native macOS application designed to provide discrete, high-context AI assistance during meetings, interviews, and complex workflows. Unlike standard AI assistants, openCluely "lives" in your environment—it listens to your system audio (Zoom calls, videos), hears your voice, and watches your screen to understand the full context before you even ask a question.

---

## ⚡️ Core Features

### 🎧 Dual-Channel Audio Intelligence
openCluely separates the audio world into two distinct channels:
* **Mic Stream (You):** Captures your voice for queries and commands.
* **System Stream (Them):** Captures internal system audio (e.g., Zoom meetings, YouTube tutorials, Spotify) *without* needing virtual audio cables or third-party drivers.

### 👁️ Active Visual Context
The system analyzes your screen in real-time to determine *where* the audio is coming from.
* *Example:* If you are watching a video, it tags the audio as "Video/Tutorial".
* *Example:* If you are in a Zoom window, it tags the audio as "Meeting/Speaker".

### 🧠 "Store & Forward" Architecture
The AI silently absorbs all context (audio + video) into a short-term memory buffer but **never interrupts**. It only responds when you explicitly type a trigger query. This ensures the AI has the full context of the last few minutes of conversation without being intrusive.

### 📝 The "Black Box" Logger
A unified, immutable log feed displays a timeline of all events:
* `[MIC]` Your speech activity.
* `[SYS]` System audio activity (tagged with visual context).
* `[SCR]` Visual context shifts (e.g., switching from VS Code to Chrome).
* `[AI]` The assistant's private responses to you.

---

## 🛠️ Architecture

openCluely is built entirely in **Swift** using native frameworks for maximum performance and security:

* **ScreenCaptureKit**: For high-performance, low-latency screen and system audio capture.
* **AVFoundation**: For microphone processing and PCM audio conversion.
* **OpenAI Realtime API (WebSockets)**: For low-latency streaming of audio and text events.
* **SwiftUI**: For the HUD-style overlay interface.

---

## 🚀 Installation & Usage

### Prerequisites
* **macOS 13.0 (Ventura)** or later.
* **Apple Silicon (M1/M2/M3)** recommended (Intel works but may have higher latency).
* **OpenAI API Key** with access to the `gpt-4o-realtime-preview` model.

1.  **Configure API Key**:
    Replace the placeholder API key with your own:
    ```swift
    private let apiKey = "sk-..."
    ```

2.  **Permissions**:
    On the first run, macOS will ask for:
    * **Microphone Access**: To hear you.
    * **Screen Recording Access**: To see your screen and capture system audio.

### Controls
* **Toggle Online/Offline**: Click the Power/Play icon in the header.
* **Ask a Question**: Type in the bottom text field and hit Enter. The AI will answer based on the audio/visual context it has just witnessed.
* **Visualizers**:
    * **Blue Bar**: Your microphone activity.
    * **Purple Bar**: System audio activity.

---

## 🔒 Privacy & Security

* **No Persistent Storage**: Audio and video data are processed in RAM and streamed to the API; nothing is saved to your local disk.
* **Ephemerality**: Once the session is closed, the context buffer is wiped.
* **Transparency**: The "Black Box" log shows you exactly what the system is detecting (Mic vs. System) in real-time, so you are never unsure if the AI is listening.

---

## ⚠️ Disclaimer

openCluely is a powerful tool for *personal* productivity and assistance.
* **Consent**: Always ensure you have the consent of other parties before recording or processing their audio, especially in confidential meetings.
* **Usage**: The user assumes all responsibility for compliance with local wiretapping and privacy laws (e.g., GDPR, CCPA).

---

*Built for the 10x Engineer.*
