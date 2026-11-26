# RV100 Brightness

[![MIT License](https://img.shields.io/github/license/yi-ge/rv100-brightness?style=flat-square)](LICENSE)

[简体中文](README_CHS.md) · [Releases](https://github.com/yi-ge/rv100-brightness/releases)

Control external monitor brightness from the keyboard on an Apple Silicon Mac. RV100 Brightness uses DDC/CI to adjust the monitor's backlight and automatically detects compatible displays when you plug them in.

![Brightness overlay showing a progress bar at 48 percent](Preview.png)

## Requirements

- Apple Silicon Mac. The build targets macOS 13 and later.
- An external monitor and connection that support DDC/CI brightness reads and writes. Some adapters and docks can affect DDC/CI availability.
- [m1ddc](https://github.com/waydabber/m1ddc), installed with `brew install m1ddc`.

The app was tested on macOS 27.0.1 with an RV100 Max. The multi-display selection and hot-plug paths were also tested with simulated displays.

## Install

Install the Apple Command Line Tools and [Homebrew](https://brew.sh/), then build from source.

```sh
xcode-select --install
brew install m1ddc
git clone https://github.com/yi-ge/rv100-brightness.git
cd rv100-brightness
./build.sh
mkdir -p "$HOME/Applications"
ditto "build/RV100 Brightness.app" "$HOME/Applications/RV100 Brightness.app"
open "$HOME/Applications/RV100 Brightness.app"
```

When a [release](https://github.com/yi-ge/rv100-brightness/releases) includes a notarized DMG, you can open the image, drag RV100 Brightness into Applications, and launch it. Install m1ddc in either case. Quit an existing copy before replacing it.

## Use

- **Brightness keys**. F1 lowers the brightness and F2 raises it. To enable these keys, open the sun icon in the menu bar, select **启用原生亮度键**, then allow RV100 Brightness in **System Settings → Privacy & Security → Device Control and Data Access** on macOS 27. On earlier macOS versions, use **Accessibility**.
- **Alternative shortcuts**. Use **Control + Option + ↓** and **Control + Option + ↑** without granting keyboard access.
- **Display selection**. Choose **控制的显示器** under the sun icon to select a display. Automatic mode prefers the main display when compatible. A saved choice resumes when you reconnect that display.
- **Brightness feedback**. The progress bar shows the brightness reported by the selected monitor, normalized to its hardware range.
- **Black at 0%**. A zero reading blacks out the selected screen while keeping it connected. Raise the brightness to bring the picture back.

## Troubleshooting

- If a monitor is missing, enable DDC/CI in its OSD if that option is available. Use **重新检测显示器** in the menu or run `m1ddc display list` to check which displays are available.
- If another display utility handles the same native keys, turn off its brightness-key handling before using F1/F2 with RV100 Brightness.
- If macOS shows the permission as enabled after replacing a local build and native keys stop working, quit RV100 Brightness, run `tccutil reset Accessibility local.rv100-brightness`, reopen the app, and enable its permission again.

## Development

[Contributing](CONTRIBUTING.md) · [Signing and releasing](RELEASING.md) · [Changelog](CHANGELOG.md)

RV100 Brightness is available under the [MIT License](LICENSE). The separately installed m1ddc project has its own [MIT License](https://github.com/waydabber/m1ddc/blob/main/LICENSE).
