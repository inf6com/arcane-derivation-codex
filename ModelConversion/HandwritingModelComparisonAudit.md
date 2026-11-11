# 手書き数式認識モデル比較（調査途中）

調査日: 2026-11-01。以下は公開元資料とローカル成果物の比較であり、同一データ・iPad実測ではない。非公開モデルを含む全世界の網羅は保証できない。

| 対象 | 入力・出力 | 公開情報 | iPad・採用上の未確認 |
|---|---|---|---|
| Hinotori | ストローク群→229記号候補順位 | 内部直接教師valid 1,281記号、222種。1,361,408ペア時の記号候補TOP1 52.15%、TOP5 83.37% | 記号群の自動分割条件、位置判定を含めた候補順位、端末速度・メモリ、学習データ利用条件 |
| TexTeller | 画像→式LaTeX | ローカル保存済みモデルはViT encoder 12層、TrOCR decoder 12層、語彙15,000トークン。Core ML保存容量はencoder 164MB、decoder init 404MB、decoder KV 368MB | このアプリの手書き経路では機能しなかったとユーザーが報告。当該実行の再現原因、同一データでの精度・端末資源、版ごとのライセンス |
| MathNote OCR | ストローク→LaTeX、編集可能な部分木 | 公開元は計約1.2Mパラメータ・CPU実行、重み同梱、リポジトリApache-2.0表示。https://github.com/YonatanNemtsov/mathnote-ocr | 重み・学習データの条件、229記号網羅、Core ML移植、iPad精度・速度、出力適合。リポジトリ表示のみで全資産の権利適合を断定しない |
| ink-on / CoMER | ストローク描画画像→LaTeX | 公開元は量子化ONNX合計7.2MB、CROHME 2014数式完全一致36.41%、ブラウザ内実行、Apache-2.0表示。v0.1.0リリースの重み説明は113シンボル。https://github.com/kimseungdae/ink-on/releases | 重み・派生元の条件、READMEの245記載との不一致、実ファイルと229記号の照合、iPad速度、製品契約が禁止する自動LaTeX修復の除去と再評価 |
| CoMER | 画像→LaTeX | 公式論文はCROHME 2014/2016/2019の数式完全一致を報告。https://arxiv.org/abs/2207.04410 | iPad・Core ML・重みとコードの使用条件・本件データ実測 |
| CAN | 画像→LaTeX | 弱教師付き記号数推定と式認識。https://github.com/LBH1024/CAN | 重みとコードの使用条件、iPad・Core ML、モデル容量・本件データ実測 |
| PosFormer | 画像→LaTeX | 位置・構造を扱う。公式READMEはコードが学術研究目的に限り無料と記載。https://github.com/SJTU-DeepVisionLab/PosFormer | 商用利用・重み条件の確認が必要。iPad・Core MLと本件データ実測なし |
| TAMER | 画像→LaTeX | 公式実装はCROHME数式完全一致等の研究結果を掲載。https://github.com/qingzhenduyu/TAMER | 版・重み・利用条件、iPad・Core ML、本件データ実測 |
| SCAN | ストロークまたは画像→数式 | 画単位の特徴と注意機構。https://arxiv.org/abs/2002.08670 | 重み、権利、229記号、Core ML、iPad実測 |
| Online gesture transformer | ストローク→数式木 | 小型・エッジ推論を論文が報告。https://arxiv.org/abs/2211.02643 | 重み、権利、対象記号、Core ML、iPad実測 |
| TAP | ストローク→数式LaTeX | 公式実装はv1 GRU、v2 Track Attend Parseを掲載。https://github.com/JianshuZhang/TAP | READMEの実行環境はTheano・CUDA 8。公開重み・ライセンス・229記号・Core ML移植・iPad実測は未確認 |

アプリの入力はストローク座標である。画像型モデルも比較対象に含め、入力画像化が追加で必要な設計上の違いを明示する。MathNote OCRは公開APIがストロークを受け取る一方、公開元は分類器内部で32×32画像を使うと明記している。画像内部表現の可否はストローク直接入力とは別の設計上の判断であり、同一と混同しない。https://github.com/YonatanNemtsov/mathnote-ocr

## 重要な利用条件

現在のHinotori学習コマンドは `/Volumes/ORICO/Developer/inf6-training/dataset/mathwriting-2024` を参照する。ローカル同梱 `readme.md` は、別途指定がない限りデータをCC BY-NC-SA 4.0と記載し、Wikipedia由来LaTeXに別条件を記載している。Google公式もMathWritingデータをCC BY-NC-SA 4.0、コードをApache 2.0と区別している: https://github.com/google-research/google-research/blob/master/mathwriting/README.md 。公開・商用利用や学習済み重みへの影響は権利者の条件と専門家による確認が必要で、違反とも利用可能とも断定しない。ライセンス確認前に配布可能と表現しない。

## 未完了

上記は全候補の網羅ではなく、実端末での同一入力・同一指標・同一条件の実測もない。記号TOP1と数式完全一致は比較不能。モデルと重みの許諾を別々に確認し、入力仕様・対象語彙を固定し、未使用テストで式構造正解率、時間、メモリ、電力を測る。TexTellerの過去失敗を未確認の成功に置き換えない。ビルド停止指示を尊重する。
