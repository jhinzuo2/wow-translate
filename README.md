# WoWTranslate / 魔兽翻译

### 1. Download / 下载

**[⬇️ Download Latest Release](../../releases/latest)**

**[▶️Installation Instructions VIDEO](https://www.youtube.com/watch?v=tcxiaU0CSfA)**

<p align="center">
  <strong>Real-time chat translation for World of Warcraft 1.12</strong><br>
  Break the language barrier on multilingual WoW 1.12 servers
</p>

<p align="center">
  <img src="https://img.shields.io/badge/WoW-1.12-blue" alt="WoW 1.12">
  <img src="https://img.shields.io/badge/version-1.2-green" alt="Version 1.2">
  <img src="https://img.shields.io/github/license/sanjaygbhat/wow-translate" alt="License">
</p>

---

## Announcement:

Since an unexpected amount of people were asking me for a way to donate, if you want to support the development of this passion project, either Paypal me at `@paokkerkir` or Revolut me at `@belthazor`.

## ✨ Features

| Feature | Description |
|---------|-------------|
| 🌍 **Multi-Language** | Chinese, Japanese, Korean, Russian → English (and vice-versa) |
| 📚 **WoW Glossary** | 850+ gaming terms translated correctly ("老克" → "Kel'Thuzad", not "Old gram") |
| ⚡ **Instant Cache** | Previously seen translations are instant |
| 💬 **Outgoing Translation** | Type in English, send in Chinese (or other languages) |
| 🔗 **Hyperlink Safe** | Player names, items, and quests stay clickable and are translated|
| 🔗 **Hyperlink Caching** | Quests are auto translated internally from WoW, for Items a cache is populated|
| 🗺️ **Minimap Button** | One-click access to settings, draggable around the minimap |
| 📺 **Channel Filtering** | Choose exactly which channels get translated |
| 💤 **AFK Auto-Pause function** | Pausing translation while you're AFK |

Fully compatible with [WoW-CNLocale](https://github.com/paokkerkir/WoW-CNLocale).

---

## 🚀 Quick Start

### 1. Download

**[⬇️ Download Latest Release](../../releases/latest)**

The download includes everything: DLL + Addon in one package.

### 2. Install

Extract and copy to your WoW folder:

```
YourWoWFolder/
├── WoW.exe
├── WoWTranslate.dll        ← From the download
├── cacert.pem              ← From the download (required, see note below)
├── dlls.txt                ← Add "WoWTranslate.dll" to this file
└── Interface/
    └── AddOns/
        └── WoWTranslate/   ← From the download
```

> **Note:** If `dlls.txt` doesn't exist, create it and add `WoWTranslate.dll` on the first line.

> **Note:** `cacert.pem` must sit in the same folder as `WoWTranslate.dll` (next to `WoW.exe`). It's a CA certificate bundle the translation client needs to verify Google's HTTPS certificate. Without it, translations will fail with a certificate error in the debug log. If it's missing, download it from https://curl.se/ca/cacert.pem.

> You have to run via `VanillaFixes.exe` or any other WoW dll launcher.

>There is a possibility that your AV flags the dll, if this happens you have to add the dll to exclusions. 

**Done!** A minimap button (scroll icon) appears — click it to open settings. Chat messages will now appear translated.

---

## 📖 Commands

| Command | Description |
|---------|-------------|
| `/wt show` | Open configuration panel |
| `/wt on` / `/wt off` | Enable/disable translation |
| `/wt status` | Show status and credits |
| `/wt test` | Test translation |
| `/wt outgoing on` | Enable outgoing translation |
| `/wt clearcache` | Clear translation cache |


You can use the following Macro in-game to create an Outgoing Translation toggle:

`/run if not WT_Toggle then WT_Toggle = true ChatFrameEditBox:SetText("/wt outgoing on") else WT_Toggle = nil ChatFrameEditBox:SetText("/wt outgoing off") end ChatEdit_SendText(ChatFrameEditBox)
`

---

## 🔧 How It Works

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  Glossary   │ →  │    Cache    │ →  │  Translate  │
│  (instant)  │    │   (free)    │    │ (also free) |
└─────────────┘    └─────────────┘    └─────────────┘
```

1. **Glossary** — WoW terms translated instantly (raids, bosses, slang)
2. **Cache** — Seen before? Instant and free
3. **Google Translate**

---

## 🎮 Language Settings

Open settings with `/wt show`:

- **Incoming**: What language to translate FROM (Chinese, Japanese, Korean, Russian, English)
- **Outgoing**: Enable translation for Say, Party, Guild, Whisper, etc.
- **Channel Filtering**: Toggle individual channels (Say, Yell, Whisper, Party, Guild, Raid, Battleground, World/Local, Hardcore) for both incoming and outgoing
- **AFK Pause**: Translation pauses while AFK (off by default, configurable)

---

## ❓ Troubleshooting

| Problem | Solution |
|---------|----------|
| DLL not loading | Ensure `WoWTranslate.dll` is next to `WoW.exe` and listed in `dlls.txt` |
| No translations | Run `/wt status` to check DLL loaded, then `/wt test` |
| Launcher issues | Run `WoW.exe` directly instead of through a launcher |

---

## 🛠️ Building from Source

<details>
<summary>For contributors</summary>

**Requirements:** Windows, Visual Studio 2022, CMake 3.20+

```bash
cd dll && mkdir build && cd build
cmake .. -G "Visual Studio 17 2022" -A Win32
cmake --build . --config Release
```

Output: `dll/build/bin/Release/WoWTranslate.dll`

</details>

---

## 📄 License

MIT License

---

<p align="center">
  <sub>Made for the WoW 1.12 community</sub>
</p>
