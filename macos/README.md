# TvtPlay for macOS

TVTest 本体の中で使う場合は、[macOS 用プラグイン](plugin/README.md)を参照してください。

ローカルの M2TS ファイルを再生する macOS 用のスタンドアロン版です。
映像・音声のデコードと再生には FFmpeg の `ffplay` を使います。
TVTest 本体や BonDriver のインストールは不要です。

## ビルドと起動

Xcode または Xcode Command Line Tools と、`ffplay` を含む FFmpeg が必要です。
リポジトリのルートで以下を実行します。

```sh
brew install ffmpeg
make -C macos
./macos/build/tvtplay "/path/to/録画.m2ts"
```

引数なしで起動すると、macOS のファイル選択ダイアログが開きます。

## 再生操作

| キー | 操作 |
| --- | --- |
| Space | 一時停止・再開 |
| ← / → | 約10秒戻る・進む |
| ↓ / ↑ | 約1分戻る・進む |
| F | 全画面表示の切り替え |
| Q または Esc | 終了 |

M2TS のシーク位置はファイルのタイムスタンプやストリーム構成に依存します。
インターレースとして記録された映像にはデインターレースを適用します。

現時点の対象は復号済みのローカル録画の再生です。放送の受信、B-CAS による復号、
ARIB 字幕、TVTest プラグイン連携は対象外です。
