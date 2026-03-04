# PCInfo Classic

USB から起動する PC 情報収集ツール。[Tiny Core Linux](http://tinycorelinux.net/) をベースに、起動直後にフレームバッファ画面へ PC のハードウェア情報を自動表示します。日本語（漢字・全角カタカナ）表示対応。

## 表示する情報

| カテゴリ | 取得内容 |
|----------|----------|
| CPU | モデル名・コア数・スレッド数・最大クロック・リビジョン・ステッピング |
| メモリ | スロット別：モデル番号・DDR種別・クロック速度・容量 |
| マザーボード | メーカー・型番・BIOSバージョン・BIOS更新日 |
| GPU | モデル名（PCI IDルックアップ）・VRAM容量 |
| ストレージ | ディスク別：モデル名・容量 |

## ファイル構成

```
pcinfo_classic/
├── src/
│   ├── pcinfo.sh           # PC情報収集スクリプト（BusyBox sh互換）
│   ├── fbprint.c           # フレームバッファ直接描画ツール（C）
│   ├── meminfo.c           # SMBIOS Type17メモリパーサー（C）
│   └── unifont_ja.psf.gz   # PSF2 16×16 日本語フォント（CJK正方形表示）
├── build/
│   └── build.sh            # ISOビルドスクリプト（全自動）
└── .devcontainer/
    ├── Dockerfile
    └── devcontainer.json
```

## アーキテクチャ

- **ベースOS**: Tiny Core Linux CorePure64 15.0（x86_64）
- **カーネル**: Debian bookworm 6.1系（vesafb・fbcon ビルトイン）
- **フレームバッファ**: `vga=794`（1024×768 16bpp）で `/dev/fb0` を直接使用
- **フォント描画**: `fbprint`（静的Cバイナリ）で PSF2 16×16 フォントを直接描画  
  → `setfont`/KD_FONT_OP_SET の 16px 幅制限を回避し、CJK文字を正方形表示
- **メモリ情報**: `meminfo`（静的Cバイナリ）が `/sys/firmware/dmi/tables/DMI` を直接パース  
  → dmidecode 不要・root 不要・SMBIOS警告なし
- **GPU名称**: AMD / NVIDIA / Intel Arc の PCI ID ルックアップテーブル（1000+エントリー）
- **BIOS/UEFI**: 両対応（Legacy isolinux + GRUB EFI デュアルブート ISO）

## ビルド方法

### 前提ツール

Dev Container を使うと自動で揃います（`Dockerfile` 参照）。

手動の場合：
```
wget, xorriso, cpio, gzip, gcc, grub-mkstandalone, mtools, isohybrid
```

### ビルド

```bash
# Dev Container を起動後
cd /workspaces/pcinfo_classic
bash build/build.sh
```

ビルド成功後、`build/pcinfo-classic.iso`（約 41MB）が生成されます。

## USB への書き込み

### dd（Linux / macOS）

```bash
sudo dd if=build/pcinfo-classic.iso of=/dev/sdX bs=4M status=progress && sync
```

> ⚠️ `/dev/sdX` は `lsblk` で確認してから実行してください。

### Windows

[Rufus](https://rufus.ie/) を使用し、**DD モード**で書き込んでください。

### Ventoy

ISO ファイルをそのまま Ventoy の USB ドライブにコピーするだけで起動できます。

## 起動手順

1. USB を PC に挿して電源 ON
2. BIOS/UEFI で USB ブートを選択（`F12` / `F2` / `Del` 等）
3. 自動的に `pcinfo.sh` が実行され、ハードウェア情報が画面に表示される
4. Enter キーを押すとシェルに移行
