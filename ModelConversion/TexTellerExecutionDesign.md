# TexTeller Transformer 実行管理設計

## 目的

TexTellerを、印刷された論文PDF等から得た数式画像クロップを数式トークン列へ変換する処理として運用する。通常チャット編集欄で取得するApple Pencil／指／ポインターのオンライン筆跡とは別経路であり、筆跡認識器やフォールバックとして扱わない。Transformer本体をアプリ側で再学習・改造するのではなく、学習済みEncoderとDecoderをCore MLで実行し、Swift側が1トークンごとの推論、KVキャッシュ、終了、継続、検証、保存を管理する。

## 入出力契約

```text
印刷数式クロップ
  → 定義済み画像前処理
  → TexTeller Encoder
  → encoder_hidden_states [1, 785, 768] Float16
  → DecoderInit（初回のみ）
  → DecoderKV（2回目以降）
  → logits [1, 1, 15000]
  → 語彙表によるargmaxトークン
  → トークン列
  → 数式構文木
  → MathML
  → MathML検証
  → 正式組版・導出成果物
```

入力画像を直接MathMLと扱わない。Encoder出力、語彙表、トークン列、構文木、MathMLは別の成果物であり、各段階の検証に合格しなければ次段階へ進めない。

## モデル構成

### Encoder

- 原モデル：ローカルに保持するOleehyO/TexTellerのVisionEncoderDecoderチェックポイント
- Core ML入力：`[1, 1, 448, 448]`、Float16
- Core ML出力：`[1, 785, 768]`、Float16
- 成果物：`Models/TexTellerEncoder.mlpackage`

### DecoderInit

初回推論専用。自己注意KVは1024スロットのゼロ配列を受け取るが、Cross-Attentionの過去KVは入力しない。Encoder特徴からCross-AttentionのK/Vを計算し、以後のキャッシュとして出力する。

- `input_ids`: `[1, 1]` Int32
- `encoder_hidden_states`: `[1, 785, 768]` Float16
- `attention_mask`: `[1, 1025]` Int32
- `position_ids`: `[1, 1]` Int32
- 自己注意の過去K/V：各層 `[1, 16, 1024, 64]` Float16
- 出力`logits`: `[1, 1, 15000]` Float16
- 自己注意のpresent K/V：各層 `[1, 16, 1025, 64]` Float16
- Cross-Attentionのpresent K/V：各層 `[1, 16, 785, 64]` Float16
- 成果物：`Models/TexTellerDecoderInit.mlpackage`

### DecoderKV

2回目以降の推論専用。Encoder K/Vを再計算せず、初回出力を入力として使用する。

- 入力はDecoderInitに加えて、各層のEncoder K/V `[1, 16, 785, 64]`を持つ
- 出力の自己注意K/Vは常に1025スロット
- Swift側は有効な過去スロットと末尾の新トークンを管理し、次回入力を1024スロットへ整形する
- 成果物：`Models/TexTellerDecoderKV.mlpackage`

## 1トークン実行

1. Swift側が現在の入力トークンを`input_ids`へ入れる。
2. `activeLength`個の過去スロットをマスク1にする。
3. 新しい入力位置である1025番目のスロットをマスク1にする。
4. `position_ids`には現在の窓内位置を入れる。
5. `activeLength == 0`ならDecoderInit、それ以外ならDecoderKVを呼ぶ。
6. `logits`の最大値の語彙IDを次トークンとする。
7. EOSなら生成を終了する。
8. present K/Vを検査し、次の状態へ保存する。

argmaxを確率分布と偽装しない。温度、top-k、top-pなどの未実装サンプリングは行わない。

## 1024枠を超える継続

1024枠は1回の物理キャッシュ窓の上限であり、数式全体の長さの上限ではない。`activeLength == 1024`になった時点で、UIへ途中成果物を返せる状態にする。

次の窓では、生成済みトークン列の末尾1023トークンを新しい窓の入力として順次primeする。prime中に得られる中間logitsは捨てずに隠すだけで、最後のlogitsから次トークンを決定する。これにより、表示上は途中結果を保存しながら、物理キャッシュをリセットして生成を続けられる。

EOSが得られないまま呼び出し側の上限に達した場合は失敗として返し、部分トークン列と最後の検証済み成果物を保持する。固定長へ切り詰めて成功扱いにしない。

## Transformer処理の対応

- Self-Attention：各Decoder層の`self_attn`。入力トークンと過去のDecoder K/Vを処理する。
- Cross-Attention：各Decoder層の`encoder_attn`。Decoder状態からQを作り、Encoder特徴からK/Vを作る。初回にK/Vを生成し、以後はKVキャッシュを再利用する。
- Q/K/V：Qは現在のDecoder状態、K/VはSelfでは過去を含むDecoder状態、CrossではEncoder出力に対応する。
- LayerNorm：各Decoder層の学習済みLayerNormをCore ML変換後も保持する。実行管理はLayerNormの値を再計算・変更しない。
- 出力Linear：Decoder最終状態を15000語彙のlogitsへ変換する。

## 失敗条件

- モデルの入力名、出力名、shape、dtypeが設計と一致しない
- Encoder出力が`[1,785,768]`でない
- KVの層数、head数、head次元が一致しない
- 語彙IDが範囲外
- EOSなしで生成上限に到達
- MathML構文木またはMathML検証に失敗

これらは別のモデル、汎用OCR、固定テキスト、トピック全体のAI解説へ迂回しない。失敗段階、根本原因、再開可能な検証操作を保存する。

## 保存成果物

User Setting Rootへ、少なくとも次を保存する。

- Encoder出力の検証結果
- 生成トークン列と語彙版
- 各チャンク境界と継続履歴
- 構文木
- MathMLと検証結果
- 使用した論文クロップの出典ID
- モデル名、原モデルハッシュ、Core ML変換設定、変換日時、検証結果

モデル本体と変換台帳はアプリBundleまたは開発成果物として保持し、ユーザーのUser Setting Rootへ勝手に複製しない。

## 実装単位

- `ModelConversion/convert_texteller_decoder_kv.py`：原モデルからDecoderInit/DecoderKVを生成
- `TexTellerExecutionManager.swift`：Core MLの実推論、KV状態、EOS、窓継続を管理し、検証済みトークン列を後段へ渡す
- `TexTellerVocabulary.swift`：同梱したTexTellerの`vocab.json`と追加トークン定義でID列をByteLevel-BPE復号する
- `TexTellerSyntaxTree.swift`：復号文字列を決定的に構文木へ変換し、構文木からMathMLを生成して検証する
- `MathMLValidator.swift`：MathMLの構文・許可要素を検証

このブロックを通過していない文字列を数式成果物として保存しない。

## 実行状態と再開

実行管理は次の状態を明示的に遷移させる。

```text
idle
  → encoding
  → decoding(initial)
  → decoding(recurrent)
  → chunk-ready
  → decoding(recurrent) または eos
  → parsed
  → mathml-validated
  → saved
```

各状態は、入力の出典ID、現在のトークン列、物理キャッシュの有効長、
最後に検証済みの成果物IDを保持する。モデル推論、チャンク継続、構文解析、
MathML検証、保存はUIスレッドで実行しない。キャンセルまたは失敗時は、最後の
検証済み状態と未確定トークン列を保存し、同じ状態から再開する。

`TexTellerExecutionManager`はTransformerの数値実行と、検証済みトークン列を後段へ
渡す責任を持つ。語彙表の復号、構文木、MathMLは別ブロックで実行する。各段階の
成果物は次段階の入力契約を満たした場合だけ渡す。

## アプリからの呼び出し契約

`TexTellerExecutionManager(bundledIn:)`は、Bundle内のEncoder、初回Decoder、
継続Decoderを読み込み、各モデルの入出力shapeを検証してから返る。検証に失敗
した場合は認識を開始しない。

`generate(pixelValues:startTokenID:eosTokenID:maximumTokens:)`は、正規化済みの
画像配列`[1,1,448,448]`をEncoderへ渡し、得られた`last_hidden_state`
`[1,785,768]`をTransformer実行管理へ渡す。`generate(encoderHiddenStates:...)`
は、既に検証済みのEncoder出力を受け取る低レベル呼び出しである。どちらも
トークンID列を返し、語彙表にないIDやshape不一致を成功として返さない。
`generateMathML(pixelValues:..., vocabulary:)`は、同じ実推論結果を同梱語彙表で復号し、
構文木を生成し、検証済みMathMLまで接続する。各段階の失敗は成果物として保存しない。

推論は呼び出し側がUIスレッド外で実行する。実行管理側は共有状態を別の要求へ
流用せず、要求ごとに`resetCache()`から開始する。途中結果が必要な場合は
`generateChunk`を使い、`continuationRequired`がtrueのときだけ次チャンクを
明示的に要求する。

## 変換成果物の受入検証

変換スクリプトは次を実測してから各`.mlpackage`を保存する。

1. Encoder出力が`[1,785,768]`であること。
2. 初回Decoderが自己KV入力のみを持ち、Cross KV出力が`[1,16,785,64]`であること。
3. 継続Decoderが自己KVとCross KVを入力に持つこと。
4. 両Decoderのlogitsが`[1,1,15000]`であること。
5. 自己KV入力が`[1,16,1024,64]`、出力が`[1,16,1025,64]`であること。
6. 原モデルと変換モデルへ同一入力を与え、logits shape、dtype、出力トークン、
   キャッシュshapeを比較すること。

いずれかが不一致なら保存済み変換物を採用せず、変換エラーとして停止する。
