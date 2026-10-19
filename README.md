# PCInfo Classic

[日本語](#日本語) | [English](#english)

## 日本語

USBからAlpine Linuxを起動し、PCのハードウェア情報と診断結果を確認するツールです。画面表示は英語です。

### 機能

- **PC Info**：CPU・メモリ・GPU・ストレージ等の情報表示
- **Memory Test**：Memtest86+によるメモリ検査
- **GPU Driver Check**：GPUの識別とドライバ状態の確認。負荷・VRAM故障検査は対象外
- **Storage Health**：SMARTによる健康状態の確認。USB接続ストレージは対象外

### 利用

x86_64のPCで、BIOS又はx86_64 UEFIから起動します。Secure Bootには対応していません。接続するUSBはPCInfo起動用の1本だけにしてください。

完成IMGは別途配布します。IMG全体をUSBへ書き込み、対象PCをUSBから起動してください。書込み先USBの内容は消去されます。

### ビルド・検証

Windows 11、Windows版Python 3.12、Git、初回のインターネット接続が必要です。Docker・WSLは不要です。

PowerShellで実行します。

```powershell
git clone https://github.com/onodera-g/PcInfo_Classic.git
Set-Location -LiteralPath '.\PcInfo_Classic'
.\tools\セットアップ.cmd
.\tools\ビルド.cmd
.\tools\検証.cmd
```

完成IMGとSHA-256等を記録したmanifestは`build/output/`に生成されます。

単体テストのみ実行する場合は`.\tools\検証.cmd --tests-only`を使用します。生成IMGの実機起動・診断は未確認のため、対象PCで別途確認してください。

### ソース構成

- `src/`：診断プログラム本体
- `data/gpu/`：GPU判定データ
- `tools/`：セットアップ・ビルド・検証
- `tests/`：テストと固定サンプル
- `licenses/`：第三者ライセンス・表記

### ライセンス・報告

自作診断コードは[MIT](LICENSE)、ビルド用の[版比較モジュール](tools/pcinfo_build/versions.py)はGPL-2.0-onlyです。同梱ソフトウェアには[個別のライセンス](licenses/THIRD_PARTY_NOTICES)が適用されます。

[変更履歴](CHANGELOG.md) ／ [不具合報告・改善案](https://github.com/onodera-g/PcInfo_Classic/issues)

## English

A bootable USB tool based on Alpine Linux for viewing PC hardware information and diagnostic results. The user interface is in English.

### Features

- **PC Info**: CPU, memory, GPU, storage, and other hardware information
- **Memory Test**: Memory testing with Memtest86+
- **GPU Driver Check**: GPU identification and driver status. GPU stress and VRAM fault tests are not included
- **Storage Health**: SMART health status. USB-connected storage is excluded

### Usage

Boot on an x86_64 PC using BIOS or x86_64 UEFI. Secure Boot is not supported. Connect only the PCInfo boot USB drive.

Prebuilt IMG files are distributed separately. Write the entire image to a USB drive, then boot the target PC from it. Writing the image erases the contents of the selected USB drive.

### Build and verification

Requires Windows 11, Python 3.12 for Windows, Git, and an internet connection for the initial setup and build. Docker and WSL are not required.

Run in PowerShell:

```powershell
git clone https://github.com/onodera-g/PcInfo_Classic.git
Set-Location -LiteralPath '.\PcInfo_Classic'
.\tools\セットアップ.cmd
.\tools\ビルド.cmd
.\tools\検証.cmd
```

The IMG and a manifest containing its SHA-256 and other build records are generated in `build/output/`.

To run unit tests only, use `.\tools\検証.cmd --tests-only`. Hardware boot and diagnostic testing of the generated IMG has not yet been performed; verify it on the target PC separately.

### Source layout

- `src/`: Diagnostic application
- `data/gpu/`: GPU identification data
- `tools/`: Setup, build, and verification tools
- `tests/`: Tests and fixtures
- `licenses/`: Third-party licenses and notices

### License and feedback

The original diagnostic code is licensed under [MIT](LICENSE). The build-time [version comparison module](tools/pcinfo_build/versions.py) is GPL-2.0-only. Bundled components are covered by their [individual licenses](licenses/THIRD_PARTY_NOTICES).

[Changelog](CHANGELOG.md) / [Bug reports and suggestions](https://github.com/onodera-g/PcInfo_Classic/issues)
