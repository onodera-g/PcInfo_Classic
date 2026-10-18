# PCInfo Classic

USBからAlpine Linuxを起動し、PC情報・メモリ・GPU・ストレージを確認する診断ツールです。

**Windows 11で開発・IMG生成・内容検証を行い、別PCをUSB起動して実機確認します。Docker・WSLは使用しません。** 自作診断処理はLinux上で動くシェルスクリプト、ビルド処理はWindows上で動くPythonです。

## セットアップ

Windows版Python 3.12を用意し、プロジェクト直下で実行します。依存は専用`.venv/`に保存します。

```powershell
.\セットアップ.cmd
```

PythonがPATHにない場合は実行ファイルを指定します。このPCの既存環境では次の指定が使えます。

```powershell
.\セットアップ.cmd -Python "D:\作業フォルダ\40_Development\10_Python\Runtimes\3.12.14\python.exe"
```

## ビルドと検証

```powershell
.\ビルド.cmd
.\検証.cmd
```

完成品は`build/output/pcinfo-classic.img`、SHA-256・取得元・同梱ファイル一覧は`build/output/pcinfo-classic.manifest.json`です。

公開予定版は**1.0.0**です。2026-10-18に現在の診断処理を含むWindowsビルドと、単体テスト・完成IMGの整合性検査が成功しました。別PCでの実機起動・診断の確認は未実施です。

IMGを生成・検証せず、Windowsで単体テストだけを実行する場合：

```powershell
.\検証.cmd --tests-only
```

通常の`検証.cmd`はIMGと現在の入力一覧・SHA-256も照合します。診断ソース・データ・起動設定テンプレート・ビルド処理・依存定義・ライセンスの追加・削除・変更を検出します。入力記録のない旧IMGや、入力を変更した後のIMGは再ビルドを要求して停止します。

初回はネット接続が必要です。公式配布のAlpine起動ファイル・APK・GRUBのWindows版・Memtest86+・PCI情報等を取得し、空のIMGへ組み込みます。既存IMGやLinux PCで作成したブートローダーへの依存はありません。OS・ブートローダーをソースからコンパイルする処理ではなく、公式配布物から起動IMGを組み立てるビルドです。

jqとその依存も同梱し、今回のビルドで取得・照合済みです。初回は通常の`ビルド.cmd`を使用し、必要な取得物が揃った後はオフラインで再ビルドできます。

取得済みの同じ入力だけで作り直す場合：

```powershell
.\ビルド.cmd --offline
```

APKリポジトリ一覧とPCI情報を更新する場合：

```powershell
.\ビルド.cmd --refresh
```

OS・GRUB・Memtestの版、同梱パッケージ、起動引数は`tools/packaging/build_config.json`で管理します。GRUBはGNU公式Windows版の生成ツールと、同じ版のAlpine公式ターゲット部品を組み合わせます。現在は生成ツール2.14と、Alpine 3.24リポジトリのGRUB 2.14-r0を使用します。起動するOS本体はAlpine 3.21.8です。

GRUBの変更時は公式配布物のSHA-256と部品取得先も更新し、起動確認をやり直します。Memtestの表示版は`src/menu_memtest.sh`と揃えます。バージョンを自動で最新版に切り替えません。

## ドライバ読み込み設定の変更

Alpine公式ISOのカーネル・initramfs・ドライバ集合（modloop-lts）を同じ組合せのまま使用します。現在は追加ドライバをソースからコンパイルせず、同梱済みのドライバを読み込む設定と動作オプションを調整しています。

`tools/packaging/build_config.json`の主な設定：

- `boot_modules`：起動時に読み込むモジュール。現在はradeon・amdgpu・nouveau・i915等を指定。
- `kernel_parameters`：ドライバの動作オプション等。
- `packages`・`overlay_packages`：診断ツールと必要ライブラリ。

`src/`・`data/gpu/`・上記設定を編集した後、`ビルド.cmd`でIMGを生成し、`検証.cmd`で内容を確認します。Windows側の開発・IMG生成にDocker・WSL・Cygwin・MSYS2・LLVMは不要です。GRUB生成にはビルドが取得・照合するWindows版ツールを使用します。

`boot_modules`への追記だけで、IMGに存在しないドライバを追加できるわけではありません。将来、未同梱ドライバやファームウェアが必要になった場合は、Alpineの対応状況とカーネルの互換性を確認したうえで、OSの更新又は同梱処理の改修を行います。

## 別PCでの確認

1. IMG全体をRufusのDDモード等で検証用USBへ書き込みます。USBへの書込みはこのビルドツールでは行いません。
2. 対象PCをUSBから起動し、PC Info・GPU Driver Check・Storage Healthを確認します。
3. Memory TestでMemtest86+へ移り、再起動後にPCInfoへ戻ることを確認します。
4. 必要な対象ではBIOS起動とx86_64 UEFI起動をそれぞれ確認します。生成するGRUBはSecure Boot用の署名を行っていません。

`検証.cmd`はIMGの内部構造・同梱内容と回帰テストを確認します。実機での起動・機器対応の合格を意味しません。

利用時に接続するUSBはPCInfo起動用の1本だけとします。複数USBを接続しない運用条件に基づき、媒体の探索方式は維持しています。

## 診断画面の変更

- USB起動時に必要なAPK・ツールを準備できなければ、理由を表示して診断メニューへの移行を止めます。`r`で準備を再試行、`q`でシャットダウンします。起動中の状態はLinux側の`/opt/pcinfo/.cache/runtime/boot-status`へ保存し、再起動後は再判定します。
- GPU Driver Checkは初回表示で状態だけを確認します。情報・復旧結果はページ送りで表示し、途中ページでも`q`で戻れます。`r`で未接続GPUのモジュール読み込みを実行します。画面用ドライバの強制解除やPCI再プローブは行いません。負荷・VRAM故障検査の機能はありません。
- GPU名の既存判定ルールは維持しています。AMDのCU数はKFD情報、PCIアドレス又は実際のDRM番号に対応するログから取得します。単一AMD GPUでは従来のアドレスなしログも使い、対応を特定できない場合は元の候補名を残します。
- Storage HealthはSMARTのJSONと終了コードを使い、`Good`・`Caution`・`Bad`・`Unknown`と理由を表示します。SSDの残寿命は意味を限定できる属性だけを表示し、取得失敗を正常と扱いません。USBストレージは従来どおり健康確認から除外します。
- Memory Testは繰り返し実行します。Escで再起動し、次回起動でPCInfoへ戻ります。開始前の入力失敗は開始操作として扱いません。再起動要求が失敗した場合、又は15秒以内に再起動しなかった場合は、起動フラグの取消しを試みてエラー表示へ戻ります。

## フォルダ

| 場所 | 内容 |
|---|---|
| `src/` | 自作のLinux用診断スクリプトとjq解析処理 |
| `src/boot/` | Linux起動時の初期設定・自動ログイン処理 |
| `src/lib/` | 端末表示、媒体操作、GPU・ストレージ情報、PC Infoの情報取得 |
| `data/gpu/` | GPU判定ルールの原本 |
| `tools/` | Windows用セットアップ・ビルド・検証入口 |
| `tools/pcinfo_build/` | APK依存解決、アーカイブ、IMG生成等の処理 |
| `tools/packaging/` | ビルド設定とLinux設定ファイルのテンプレート |
| `tests/` | ビルド・診断解析・シェル構文とGPU操作境界の回帰テスト |
| `tests/fixtures/` | SMART JSON・GPUログの固定サンプル |
| `docs/` | 設計書、履歴、GPU調査一覧 |
| `licenses/` | 第三者ソフトウェアの注意書き・ライセンス |
| `.venv/` | Windows用Python開発環境と環境準備用キャッシュ |
| `build/work/` | 取得キャッシュ・ツール・中間物。再利用可能 |
| `build/output/` | 完成IMGと検証用manifest |
| `.cache/verification/` | 検証時だけ使う一時ファイル |

診断の変更は`src/`、起動処理の変更は`src/boot/`、GPU判定データは`data/gpu/`を編集します。OS・パッケージ・ドライバ読み込み指定等のビルド設定は`tools/packaging/build_config.json`、Linuxのinittab・APK world・ログイン設定は`tools/packaging/overlay/`です。`build/`と`.venv/`の中を直接編集して改修しません。

GPUログのPCI/DRM関連付けとCU・VRAM解析は`src/gpu_logs.jq`に集約しています。自作ファイルの同梱先・権限と原本照合は`tools/pcinfo_build/payload.py`、ビルド設定の読込み・検査は`tools/pcinfo_build/config.py`で管理し、ビルドと検証の両方から共用します。

共通初期化は`src/common.sh`から`src/lib/`の処理を読み込みます。端末表示・ページ送りは`display.sh`、USBの媒体操作は`media.sh`、GPU判定は`gpu.sh`、ドライブ列挙・接続方式は`storage.sh`です。容量の丸め方や健康確認時のUSB除外は各画面の現行仕様を維持しています。

PC Infoの`lscpu`とBIOS・ベースボード・CPUのDMI情報は`src/lib/hardware.sh`で1回の表示内だけ再利用し、画面を開き直すと取得し直します。`lsblk`のJSONは`src/storage_devices.jq`で解析し、JSONを使えない場合のpairs形式と、`lsblk`がない場合のsysfsによる取得も維持しています。

起動処理の原本は`src/boot/setup.sh`と`src/boot/autologin.sh`です。ビルド時に従来と同じ`/etc/local.d/00-pcinfo-setup.start`と`/usr/sbin/autologin`へ実行権限付きで同梱します。

今回の移行前IMGは`build/work/previous/pcinfo-classic.img`、旧中間物は`build/work/legacy_alpine/`に保護しています。新しいIMGの実機確認が済むまでは削除しません。

## GitHubへのソース更新

GitHubは[onodera-g/PcInfo_Classic](https://github.com/onodera-g/PcInfo_Classic)の`main`で管理します。既存の共通ツール`D:\作業フォルダ\40_Development\40_Git\upload.bat`を開き、**8番（pcinfo-classic）**を選びます。コミットの版・日付・説明は`docs/release-notes.md`から読み込みます。共通ツールはビルドを実行しないため、送信前に本プロジェクトの`ビルド.cmd`と`検証.cmd`を完了させてください。

ソース・判定ルール・設定・テスト・文書を送信し、`.venv/`・`.cache/`・`build/`・`export/`はGit除外します。完成IMGとmanifestは別の場所で配布し、GitHub Releasesへのアップロードは行いません。

## 資料とライセンス

- [設計書](docs/設計書.md)
- [変更履歴](docs/release-notes.md)
- [第三者ソフトウェア](licenses/THIRD_PARTY_NOTICES)

従来の自作診断コードはMITです。Windowsビルドに使うAlpine版比較モジュール`tools/pcinfo_build/versions.py`はapk-tools由来でGPL-2.0-onlyです。詳しくはファイルの表示と`licenses/COPYING.GPL-2.0`を参照してください。
