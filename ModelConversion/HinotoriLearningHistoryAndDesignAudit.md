# 火の鳥・手書き記号認識の研究史と学習設計監査

調査日: 2026-11-03 JST

## 結論

「画像学習モデル全史」を全画像分野・全論文まで網羅したとは主張しません。この監査は、火の鳥の対象に直結する手書き文字・数学記号・数式認識の一次資料を年代順に追い、**229種類の個別記号を、手書き入力から分類するモデル**に絞っています。数式画像から式全体のLaTeXを出す研究は、関連技術史として区別して扱います。

現時点で、世界最適なモデルは確定していません。実測上の優先候補は、**残差ラスタCNNの特徴埋め込みを直接教師prototypeとの全229クラス類似順位に使う方式**です。入力順序不変Point/undirected-segment集合枝は同一foldで大幅に劣ったため不採用、HOG線形headは分類headを上回るもののCNN prototypeに届いていません。類似記号候補は学習特徴距離、位置判定は座標を保持した別段階として接続します。次は新規source-disjoint holdoutで融合方法を事前固定して評価します。これは研究上の暫定選択であり、世界首位の根拠ではありません。

## 研究史：火の鳥に関係する流れ

| 時期 | 研究上の転換 | 何を入力・出力したか | 火の鳥への含意 |
|---|---|---|---|
| 1960–80年代 | ルール、幾何特徴、構文解析。2次元数式を演算子や記号関係の木として解析 | ペン軌跡または紙面 → 記号・構造 | 位置と字形の責任を分ける考えは古くからある。字形分類器と式構造認識を同一指標に混ぜない。 |
| 1990年代 | 統計的分類器、特徴量設計、確率的系列モデルが発展。LeNet-5は局所結合・重み共有を使うCNNを文書・手書き数字へ実用化 | 画素画像 → 文字クラス | ラスタCNNは書き順を入力せず、形状の平行移動・局所パターンを畳み込みで学習する。 |
| 2000年代 | オンライン数式認識を記号分類＋構造解析として分ける方式、ストローク群と記号候補をグラフとして保持する方式 | 座標列 → 記号候補グラフ／数式構造 | 最初から単一の確定系列に潰さず、曖昧な候補と根拠を残す設計につながる。 |
| 2011–13 | HMM・局所軌跡特徴・最近傍法など、時間系列と手設計特徴を用いる孤立記号分類が比較され、CROHMEがオンライン数式の共通データ・評価を整備 | 単記号のペン軌跡 → クラス順位 | 2011 HMM研究は93クラス、20,281訓練/2,202評価でTop-1 82.9%、Top-5 97.8%。ただし連続左→右HMMであり、筆順に依存しないという火の鳥要件とは異なる。 |
| 2014–15 | CROHME 2014の孤立記号基準が101クラスへ拡大。軌跡特徴・前処理・データ拡張・MLPを大量記録で比較する研究も進む | InkML単記号 → Top-k候補 | 条件の違う報告を同一ランキングへ混ぜない。 |
| 2014–16 | 画素化した手書き記号へCNN、元軌跡へBLSTMを適用し、両者を融合する研究が登場。CROHME 2016で孤立記号Task 2a/2bを独立評価 | 同一オンライン記号のラスタ画像＋軌跡 → 101クラスの孤立数学記号 | 形と軌跡の融合は2014で改善を報告。CROHME 2016 Task 2aの公式最高Top-1は92.81%、提供データだけの最高は92.28%。火の鳥の現在値との直接比較ではない。 |
| 2017–19 | CNN画像エンコーダ＋Attentionデコーダ、オンライン軌跡のGRU/BLSTM＋Attentionが数式全体をLaTeXへ変換 | 式全体の画像または軌跡 → LaTeX列 | 記号・位置・構造を一括で学習するが、229クラス単記号分類とは目的が異なる。式完全一致の値を火の鳥のTop-1と比較しない。 |
| 2020–21 | 双方向文脈、文法、ストローク単位Attention・オンラインHMERが発展 | 式中のストローク群 → 記号と関係 | 文脈は曖昧な記号に有効だが、画面上の上下左右を使う位置規則とは別機能。単記号分類評価では文脈の有無を固定する。 |
| 2022–24 | Transformer、構文制約、Graph Neural Networkが式全体の認識で強化。MathWritingが大規模なオンライン式・合成式データとベンチマークを公開 | 式全体 → 数式トークン列／記号関係グラフ | データ量だけで解けるわけではない。原版MathWritingの式Inkには個々の記号の直接境界ラベルがなく、式LaTeXだけから記号群を正解として作ることはできない。 |
| 2025 | 構造認識への回帰。式ラベルと生ストロークを自動整列し、記号群・関係の疑似ラベルを公開。分類では軌跡系と描画画像系を融合 | 式Ink + LaTeX → 疑似TraceGroup／SLG、分類・関係予測 | 数式単位の境界教師が増える可能性がある。ただし自動ラベルは正解ではなく、教師モデルの系統誤りを引き継ぐ。人手監査済み部分と未監査疑似ラベルを分離する必要がある。 |
| 2026 | 離散マスク拡散による式全体の反復修正、実世界の手書き数式ベンチマークが登場 | ラスタ式画像 → 記号・構造の反復修正／式出力 | 新しい有力な式全体方式だが、単記号229クラス分類器の代替やTop-1比較対象ではない。入力単位・出力単位を混ぜず、後段の利用可能性だけを見る。 |

## 方式ごとの理論適合性レビュー（孤立記号229分類）

「過去知のモデルをすべて検討する」は、関連する方式の仮定と適用範囲を漏れなく洗い出す意味で実施します。世界中の全論文を網羅したという意味にはしません。以下は方式の理論上の性質と火の鳥への適合仮説であり、火の鳥上の性能順位は同一データ・分割で測るまで未確定です。

| モデル族 | 数学的な仮定・利点 | 失敗しやすい条件 | 火の鳥での扱い |
|---|---|---|---|
| 最近傍・テンプレート・弾性距離 | 形を特徴空間へ写し、代表例との距離で順位付けする。小標本でも使え、候補と距離の説明が直接得られる。 | 正規化・対応点・距離尺度に強く依存し、字形内の局所ずれや画数差が距離を壊す。全例保存では229クラス×多数例の検索費用が増す。 | 現行の学習特徴prototypeと直接比較する。ユークリッド、コサイン、DTW等を同一inner splitで選び、全例・複数prototypeのメモリと遅延も測る。単一テンプレートを当然の正解としない。 |
| HMM／状態系列モデル | 筆跡を時間方向の状態遷移と観測列として表す。軌跡順が安定し、状態数と遷移がクラス差を表す場合に有効。 | 利用者が画順・画方向を変えると系列分布が変わる。点列を単純な左→右に仮定すると、円・上下画・筆順差を損なう。 | 画順を教師の正解条件にしない契約と緊張する。方向・順序に頑健な特徴化を明示的に検証できる場合のみ候補。既報値を移植しない。 |
| MRF／MQDF／ガウス判別 | クラスごとの特徴分布を平均・共分散（または近似固有空間）で表す。推論は小さく、少量データでの統計的構造を利用できる。 | 特徴が多次元で標本が少ないと共分散推定が不安定。単峰・楕円分布の仮定は、同じ記号の複数の書き方を一つの分布で覆えないことがある。 | 低次元HOG/幾何特徴でMQDFを強い古典ベースラインとして実装・評価候補にする。229クラス・直接教師約6.4kではクラス別共分散の正則化、必要標本数、保存量が主要検討点。MRFは局所依存構造を定義できる特徴格子が必要で、現状は未実装。 |
| HOG＋線形分類器 | 勾配方向ヒストグラムが局所輪郭の小変位を集約し、線形境界で分類する。CNNより軽く、特徴寄与を比較しやすい。 | 強い形状変形・階層的部品構成・細い点や微小添字に対する解像度不足。固定ラスタ化条件に依存。 | fold-05 outerはTop-1 49.2%、Top-5 85.8%。fold-06同一分割でもTop-1 checkpointは51.2% / 84.2%、Top-5 checkpointは49.8% / 82.8%で、CNN prototypeを下回った。なおMQDF等との基準比較は未完了。 |
| CNN／残差CNN | 局所畳み込みと重み共有により輪郭・部品の階層特徴を学習する。手設計特徴より柔軟だが、ラスタ画像を入力するためストローク時系列は直接利用しない。 | 少数教師・不均衡・前処理のずれ・過剰な拡張で過学習または字形を壊す。画像化の線幅・縦横比が推論と学習でずれると分布が変わる。 | 現在の最有力実測候補。fold-05のCNN特徴prototypeはTop-1 66.8%、Top-5 92.2%（500例）。一foldのみで、229全クラスを含む大規模検証ではない。ラスタ条件固定とfold間再現が先。 |
| CNN＋BLSTM／双方向軌跡融合 | ラスタCNNが空間的な輪郭、BLSTMが筆跡の時間的前後文脈を捉える。モダリティごとの誤差が独立なら融合で補える。 | 順序の異なる書き方への感度、2枝の較正不一致、融合重み過適合、計算・メモリ増加。式全体文脈を含む論文結果は孤立記号単体にそのまま当てはまらない。 | 2016年の数学記号研究に、画像CNNと元軌跡BLSTMの融合、およびMRF/MQDF比較の直接先例がある。火の鳥では、同じ孤立記号splitで独立枝→融合の増分、反転・画順摂動耐性、ANE適合を実測する候補。未実施。 |
| Siamese／metric learning／supervised contrastive | 同一クラスを近づけ、異クラスを離す埋め込みを学ぶ。距離ランキング、類似候補、prototypeを一つの空間で扱える。 | ペア選択・温度・クラス不均衡に敏感。異なるが視覚的に近い記号を押し離しすぎると、利用者が求める距離付き類似候補を失う。 | 特徴距離で類似候補を作る考えは適合する。現foldで試した一設定のcontrastive枝はCE残差CNNを下回った。損失係数・samplingを事前固定した別検証なしに「metric learning全般が失敗」と一般化しない。 |
| Prototype／分類器融合 | 分類logitと教師埋め込みprototypeを組み合わせ、決定境界と例ベース距離の利点を併用する。 | prototypeがtrain埋め込みへ過適合、温度・重み選択に依存、同じvalidationへ何度も調整すると選択バイアス。 | fold-05ではprototype単独がTop-1最良。fold-06ではvalidation-only Top-5 fusionが66.0% / 93.6%、prototype単独が65.8% / 92.8%だったがcluster-bootstrap区間は重なる。優位の確証ではなく、より大きい未使用foldで再検証する。 |
| ViT／自己注意画像モデル | 広域のパッチ間関係を直接学び、CNNの局所帰納バイアスに依存しない。 | 大量データ・正則化・計算資源を要しやすく、直接教師約6.4kでは事前学習なしの優位性が不明。小さな単記号画像ではCNNより不利な可能性もある。 | 現状未実施。事前学習の出典・利用条件・端末資源を固定し、CNNと同一splitで初めて比較する。論文の式全体ViTを単記号スコアとして引用しない。 |
| ルール・幾何判定 | 正規化座標、縦横比、位置、線長などの明示特徴で限定的な曖昧候補を順次識別できる。深層モデルにない操作根拠を提示できる。 | 閾値が筆記サイズや傾きに依存し、対象外記号へ適用すると精度を落とす。候補順位を無視した強制上書きは誤りを増やす。 | 類似距離を先に計算し、位置は独立段階で適用する。原座標・候補・ルール根拠を保持し、適用対象外は変更しない。全体Top-kと対象ペア別誤りを接続前後で測る。 |

### 理論レビューから確定する比較順

1. **現行再現基準**: 同一source-disjoint split・前処理で、残差CNN classifier/prototype、HOG線形、HOG+MQDF、直接テンプレート距離を比べます。候補選択はinner validationだけ、outer testは凍結後に一度だけ開きます。
2. **表現の反証**: 画順・方向・線幅・縮尺の摂動を、意味が保たれる変換と壊れる変換に分け、同一標本の順位変動を測ります。画順不変性を達成したと仮定しません。
3. **軌跡情報の追加価値**: オンライン点列を使うBLSTM/HMM系は、ラスタCNNに対する孤立記号同一foldの増分が確認できた場合にだけANE候補へ進めます。
4. **類似候補と位置規則**: 類似距離ランキング→位置規則の順で、厳密Top-1/5、類似群別recall、誤認ペア、適用前後の差を別々に算出します。類似群一致を厳密正解へ加算しません。
5. **端末適合**: Core ML変換後に同じ入力で出力差、ANE/CPU/GPU実行先、遅延、ピークメモリ、モデル容量を実機iPadで測ります。変換可否だけをANE実行の証拠にしません。

この順序は理論から決まる測定計画です。最終的な優劣・採用モデルはまだ決定していません。

主要一次資料: [Nguyen, Le & Nakagawa (2016), CNN/BLSTMとMRF/MQDF比較](https://doi.org/10.1587/transinf.2016EDP7102)、[Hu & Zanibbi (2011), 孤立記号HMM](https://www.cs.rit.edu/~rlaz/files/HuZanibbiICDAR2011.pdf)、[CROHME 2016競技報告とTask 2孤立記号定義](https://digitalcommons.isical.ac.in/conf-articles/726/)、[CROHME 2016 Task 2公式定義](https://tc11.cvc.uab.es/datasets/ICFHR-CROHME-2016_1/task_2_1)、[LeCun et al. (1998), Gradient-Based Learning Applied to Document Recognition](https://doi.org/10.1109/5.726791)、[Dalal & Triggs (2005), HOG](https://doi.org/10.1109/CVPR.2005.177)、[Bellet, Habrard & Sebban (2013), Metric Learning for Similarity-Based Pattern Recognition](https://doi.org/10.1016/j.patcog.2012.09.035)。

## 今回の一次資料から、単記号課題へ移せる範囲

- CROHME 2016は式全体認識と別に、孤立した有効記号の分類 (Task 2a) と有効/無効記号分類 (Task 2b) を設けています。したがって「229クラスの既知記号群から一記号を分類する」評価単位自体には先例があります。ただしCROHMEの101クラス・分割・データ量は、本件MathWriting直接教師と異なるため、公開Top-1を現在の順位表へ混ぜません。
- オンライン記号の双方向文脈研究は、前後のストローク文脈を用いて曖昧記号の分類と分割を同時に改善しました。これは式全体認識に文脈が有効である証拠ですが、孤立記号モデルへ前後文脈を入れたTop-1とは別タスクです。本件では文脈情報を位置判定・候補再順位付けに入れるなら、その段階の入力と増分を分けて報告します。
- SCANは式全体HMERでオンライン点列とオフライン画素をストローク単位に整列し、単独モダリティと融合を比較しました。これを根拠に、次の同一fold実験はラスターCNN対、座標点/無向線分を対称集約する順序不変幾何枝とします。SCANの式完全一致率をこの単記号分類へ転用したり、同じ方式と称したりはしません。
- MathWritingの公式資料は入力をInkMLのオンライン筆跡として公開し、個別記号の孤立例を `symbols/` に別収録します。式全体のInk/LaTeX標本を、そのまま正しい各記号境界を持つ教師例として数えない方針を維持します。公式READMEに記されたデータCC BY-NC-SA 4.0と、コードApache 2.0の条件も別々に扱います。

一次出典: [CROHME 2016 competition report](https://digitalcommons.isical.ac.in/conf-articles/726/)、[Online Handwritten Mathematical Symbol Segmentation and Recognition with Bidirectional Context](https://doi.org/10.1109/ICFHR2020.2020.00071)、[Stroke Constrained Attention Network](https://doi.org/10.1016/j.patcog.2021.108047)、[MathWriting official dataset README and license](https://github.com/google-research/google-research/blob/master/mathwriting/README.md)。

### 歴史的な数値をどう読むか

2016年のオンライン数学記号論文は、CROHME 2014の孤立記号・101クラスでCNN(DMCN) 89.39%、BLSTM 87.29%、両者の加重融合91.28%を報告しています。これは直接的な先行事例ですが、現在のMathWriting由来229クラス、データ分割、教師数、評価手順、前処理は異なります。したがって「火の鳥がこの論文に勝った／負けた」とは結論できません。特にCROHMEの競技結果は、式全体タスクと記号タスクが分かれており、式全体のExpRateを記号Top-1として転用できません。

CROHME 2014の孤立記号競技報告では、101クラス・invalid hypothesisを含めない設定で、参加方式のTop-1は77.25〜91.24%でした。最上位91.24%はRNN系、別参加者のMLP系も91.04%で、単一のネットワーク系統だけが優位とはいえない結果です。invalid/junkを加えた設定ではrejectの扱いも指標に影響しています。これもオンライン筆跡、101クラスの競技値であり、229クラスの画像ラスタ分類の直接基準にはしません。

別の一次資料であるCROHME 2016競技報告は、孤立記号Task 2a（有効記号のみ、101クラス）でMyScript 92.81%、提供データだけの最高値としてTUAT 92.28%を報告します。Task 2bは誤分割記号/junkを含み、Top-1はMyScript 86.77%、Tokyo 83.34%、RIT 89.82%です。Task 2aと2bは入力分布・クラス定義が違い、MathWriting 229クラスとも異なるので、歴史上の基準点としてのみ記録し、火の鳥の直接順位とはしません。

### 2025–26の更新と、火の鳥に取り込む範囲

2025年の構造認識研究は、CROHMEで学習した整列器を使ってCROHME/MathWritingの式Inkに記号群・関係を自動付与し、公開拡張データを作っています。論文はCROHME validationで記号分類96.73%などを報告しますが、これは101クラスの式中記号を境界付きで分類する工程であり、孤立記号の229クラスTop-1ではありません。論文本文の段階別数値と表の数値にも不一致があるため、数値を単純に最上位実績として扱えません。拡張データは人手正解ではなく、ラベル生成器による選別済み疑似教師です。利用するなら元の直接教師・独立人手確認済み検証集合と分離し、疑似教師の精度を別途監査する必要があります。

2026年のGryphOneはMathWritingの筆跡をラスタ画像化し、ViTと離散マスク拡散で式全体のトークンと構造を反復修正します。公開要約のCER/式完全一致率は、局所的な記号Top-1とは別の指標です。また2026年の実世界ベンチマーク研究は、大規模視覚言語モデルでも記号検出と2D構造の間に課題が残ることを検討します。これらから導けるのは「反復修正や構造情報が式全体で有効な研究方向」ということまでで、火の鳥の単記号分類へ拡散デコーダを載せる根拠にはなりません。

この更新で、データ不足への候補を修正します。原版MathWritingに直接ラベルのある孤立記号は約6千件だけですが、2025年の拡張には式Inkの自動TraceGroup注釈があります。これは捨てるべきゴミとも、そのまま正解扱いできる教師とも決め付けず、来歴・ラベル生成法・対象シンボル範囲・利用条件を確認し、直接教師と分離した疑似教師実験としてだけ検討します。拡張データのライセンスもCC BY-NC-SA 4.0と記録されているため、将来の配布モデル・アプリへの重み同梱可否は別途法務判断が必要です。

## 公式の直接記号教師の再照合

MathWriting 2024の公式 `symbols.jsonl` には6,423件の孤立記号注釈がありました。教師生成器v1は、source formula `51486ff88b789d6d` 内でstroke 19が `\prime` と `i`、stroke 22が `(` と `i` に重複割当てされたことを検出し、その数式に属する18注釈をすべて落としていました。これは未知語彙の除外ではありません。

生成器を改め、矛盾するstrokeに触れる3注釈だけを除外し、同じ数式内の矛盾しない15注釈を保持します。新しい `runs/symbol229-teachers-v2-conflict-local/` は6,420直接教師・3,426 source formulaになりました。v1の教師と、既に作成したfold-01〜05の分割・checkpoint・評価結果は書き換えていません。fold-05の比較が終わった後、v2教師を使う新しいsource-disjoint foldで、この15件を含めた影響を測ります。曖昧な3注釈をどちらかの正解に決め打ちすることはしません。

## 現行の学習系列で判明している設計上の問題

1. **タスク混同**: 全式画像→LaTeXの実験群と、記号ストローク群→229記号の実験群の数値が過去報告で同じ「認識」名に混在しました。
2. **直近モデルの入力表現**: 直接教師分類器は点ごとのMLP後に各ストローク内をmax集約するため、点の時間順・ストローク内方向は捨てます。しかし集約後のストローク表現をGRUへ順番に入力しているため、ストロークの並べ替えには不変ではありません。これは「書き順を正解根拠にしない」という製品要件に反する実装上の欠陥です。また点ごとのmax集約は、ストローク内の線の連結・局所曲率も大きく捨てます。Top-1低下への寄与量は、順序を置換した同一サンプルの出力差と、置換不変モデルとの同一split比較で測るまで原因と断定しません。
3. **弱教師の勾配**: 現行retrieval系で離散的なgroup decodeへ渡すaffinityをdetachしているため、式多重集合損失は群提案器を学習しません。直接群ラベル損失は別に存在します。この実装は「式ラベルだけで群分けまで端から学習済み」という説明を支持しません。
4. **評価データの再利用**: 既存のdirect-validはチェックポイント選択・類似ペア発見に再利用されており、最終汎化評価ではありません。加えて222/229クラスで、真の群境界が与えられた条件付き分類です。Top-1約50%台、Top-5約80%台はこの限定条件の開発値です。
5. **教師の偏り**: 現行source splitの直接教師はtrain 5,124例/2,739数式ソース、valid 1,281例/686数式ソース。train各クラスは1〜54例、229クラス中7クラスが5例以下、validは222クラスのみ観測され7クラスの評価例がありません。validは平均Top-kを出せても、全229クラスの公平なクラス別比較には不足します。230kの数式Inkは個別記号境界を含まないため、その全数を単記号の教師例数と呼べません。
6. **成果物状態**: ユーザーの明示承認に基づき、却下されたHinotori Core ML配布資産は撤回済みです。元データ・学習チェックポイント・評価履歴は保持されています。したがって「現在Core MLモデルがアプリに組み込み済み」とはいえません。

これらから「50%の原因はひとつ」とは断定できません。少なくとも、点列幾何をつぶす分類表現、ラベル数の少なさ、分布偏り、学習・評価分割の再利用、群分割を含まない測定が、改善と評価を難しくしていることは確認できます。

## 火の鳥で比較すべきモデル仮説

ここで示すのは**採用済みの最適モデルではなく、実測で選ぶ候補**です。

### A. 画像だけの字形分類器

入力: 既知の記号ストローク群を、固定仕様でキャンバスにラスタ化したグレースケール画像。  
モデル: ANEに適した小型ConvNet（depthwise-separable convolutionを含む候補）＋229クラスlogit。必要なら別の正規化embedding head。  
長所: ストロークの入力順・時間順を捨て、書き方向差をラスタ形状として扱う。Core MLの畳み込み実装へ適合しやすい。  
短所: 筆順入力の幾何情報を使わず、正規化・線幅・ラスタ解像度に依存する。

### B. 順序不変のストローク幾何分類器

入力: 生のx/yを保持したストローク群。ストロークの並び替えと各線の逆向き入力の双方を学習時に変えても、同じラベルを返すように学習・評価する。  
モデル: 点座標をPointNet型の対称特徴として集約し、隣接点間の線分を向きを正規化した無向ベクトルとして特徴化する。点群内、ストローク内、ストローク間をmean/maxの対称poolingで集約する。時間位置埋め込みや固定ストローク順を分類ラベルへ直接結び付けない。  
長所: 原座標、点の分布、線分方向を保持しながら、ストロークの並べ替えと同一線の逆向き入力で同一表現となるよう構成できる。  
短所: mean/max集合化は線分の連続順序や複雑な曲率を完全には表せない。少数例クラスでの過学習、ANE適合、順序摂動下の実測安定性は未検証。

### C. 二枝融合候補

同じラベルを持つAとBを融合し、各枝単独と比較する。融合係数は学習分割から固定し、最終評価で調整しない。2016年の孤立記号研究はonline/offline特徴の相補性を示しますが、現在の229記号・iPad条件で融合が勝つ保証はありません。勝たない場合、二枝は採用しません。

## 位置・類似の責務

```text
元ストローク座標を保持
  → (A/B/Cのいずれかで形状分類: 229クラスlogitと特徴embedding)
  → 類似候補をembedding距離で順位付け（正解ラベルは統合しない）
  → 別の位置判定器が座標と候補を使って順位を更新
  → 曖昧なら利用者が確定
```

類似は字形特徴距離、位置は式内の上下左右・基線・包含関係です。同じ規則へ混ぜず、各段階の入力・出力・根拠を記録します。形状分類器へ式中位置を混ぜない主評価と、後段を接続した全経路の両方を同一例で報告します。候補外から追加する類似候補も許しますが、独立評価正解を見て追加してはいけません。

## 実測で「最適」を決める計画

1. **分割を先に固定**: source formula ID単位でtrain/dev/finalを分ける。finalは結果が出るまで読み込まず、チェックポイント・augmentation・距離しきい値・規則の選択へ使わない。書き手IDはMathWritingに含まれないため、書き手独立性は主張しない。
2. **クラス範囲を明記**: 全229ラベルの例数をtrain/dev/finalごとに出し、ゼロ例のラベルを「評価済み」にしない。少数例クラスを隠さずmacro平均と例数加重平均を併記する。
3. **同じ入力群・同じラベルでA/B/Cを比較**: exact Top-1/3/5、macro recall、混同行列、類似群候補recall、校正誤差を報告する。手動・類似群一致と完全ラベル一致は別指標にする。
4. **書き順不変性を測定**: 同じ試料をストローク順の全置換（可能範囲）と各線反転で変換し、Top-k順位・logit変化・正解保持率を測る。単に「左利き対応」と称さない。
5. **位置規則は凍結して後段評価**: 形状単独、類似後、位置後を同じ未使用サンプルで比較。Top-1/Top-5の増減と改変例を示す。
6. **AN E適合は性能選定の後**: 選択済み重みをCore ML化し、同一入力のlogit/Top-k parity、iPad mini A17 ProでのANE実行有無・遅延・メモリ・熱を実測する。変換成功だけをANE使用証拠にしない。
7. **疑似教師は独立した実験枝**: 直接教師だけのモデルを必須基準として残し、2025年拡張の自動TraceGroupを使う枝では、疑似ラベル採択率・人手監査誤り率・クラスごとの偏りを別途測定する。両枝を同一の未使用正解集合で比較し、疑似教師の追加が改善しない、または特定クラスを悪化させる場合は採用しない。
8. **最終testを一度だけ開封**: 全設計と重みをfreeze後、finalを一度評価して、失敗対と信頼区間を保存する。結果を見て設計を変えたら、そのfinalは以後開発用と呼び、別の未使用集合が要る。

### 採用条件

「最適」は抽象的な世界一ではなく、固定した本件入力・229語彙・評価分割・ANE制約に対して、A/B/CのうちTop-1を改善しつつTop-5と類似候補品質を落とさず、変換前後parityを満たし、iPad上で条件内に動く候補です。現状は評価分割に直接ラベルがない公式MathWriting valid/testと、汚染済み開発validが残るため、世界的な優劣や最終Top-1は判定不能です。

## 一次資料

- [Belaid & Haton (1984), A syntactic approach for handwritten mathematical formula recognition](https://doi.org/10.1109/TPAMI.1984.4767483)
- [LeCun et al. (1998), Gradient-Based Learning Applied to Document Recognition](http://yann.lecun.com/exdb/publis/pdf/lecun-98.pdf)
- [Garain & Chaudhuri (2004), Recognition of online handwritten mathematical expressions](https://doi.org/10.1109/TSMCB.2004.836817)
- [Shi, Li & Soong (2007), A Unified Framework for Symbol Segmentation and Recognition of Handwritten Mathematical Expressions](https://www.microsoft.com/en-us/research/publication/a-unified-framework-for-symbol-segmentation-and-recognition-of-handwritten-mathematical-expressions-2/)
- [Nguyen, Le & Nakagawa (2016), Recognition of Online Handwritten Math Symbols Using Deep Neural Networks](https://doi.org/10.1587/transinf.2016EDP7102)
- [Hu & Zanibbi (2011), HMM-Based Recognition of Online Handwritten Mathematical Symbols](https://www.cs.rit.edu/~rlaz/files/HuZanibbiICDAR2011.pdf)
- [Thoma (2015), On-line Recognition of Handwritten Mathematical Symbols](https://arxiv.org/abs/1511.09030)
- [Mouchère et al. (2016), ICFHR 2016 CROHME competition report](https://digitalcommons.isical.ac.in/conf-articles/726/)
- [Mouchère et al. (2014), ICFHR 2014 CROHME competition report](https://www.cs.rit.edu/~rlaz/files/Crohme2014FinalVersion.pdf)
- [Official CROHME 2014 isolated-symbol task protocol](https://tc11.cvc.uab.es/datasets/CROHME-2014_2/task_2_1)
- [Official CROHME 2016 isolated-symbol task protocol](https://tc11.cvc.uab.es/datasets/ICFHR-CROHME-2016_1/task_2_1)
- [Zhang, Du & Dai (2017), A GRU-based Encoder-Decoder Approach with Attention for Online HMER](https://arxiv.org/abs/1712.03991)
- [Wang et al. (2021), Stroke Constrained Attention Network for Online HMER](https://doi.org/10.1016/j.patcog.2021.108047)
- [Yuan et al. (2022), Syntax-Aware Network for HMER](https://openaccess.thecvf.com/content/CVPR2022/papers/Yuan_Syntax-Aware_Network_for_Handwritten_Mathematical_Expression_Recognition_CVPR_2022_paper.pdf)
- [Mouchère et al. (2019), CROHME + TFD competition report](https://www.cs.rit.edu/~rlaz/files/CROHME%2BTFD%E2%80%932019.pdf)
- [Gervais et al. (2024), MathWriting dataset paper](https://arxiv.org/abs/2404.10690)
- [Official MathWriting data protocol and license](https://github.com/google-research/google-research/blob/master/mathwriting/archive_readme.md)
- [Seitz, Lengfeld & Timofte (2025), The Return of Structural Handwritten Mathematical Expression Recognition](https://arxiv.org/abs/2508.19773)
- [MathWriting+ dataset catalogue, including its annotation caveat and license](https://datasetcatalog.nlm.nih.gov/dataset?q=0002080453)
- [Kawakatsu & Ishiyama (2026), GryphOne: Symbol-Aware Masked Diffusion for Structural Refinement in Offline HMER](https://arxiv.org/abs/2602.03370)
- [Jiang et al. (ICML 2026), Seeing Symbols, Missing Structure](https://proceedings.mlr.press/v306/jiang26bg.html)

## 証拠の限界

この資料は、関係する研究の主要な系譜と本プロジェクトの既存履歴を再整理した監査です。「画像認識研究の全論文」を網羅したものではありません。先行研究は課題・クラス数・データ・評価方式が異なるため、火の鳥との勝敗を示しません。次の実行工程は、未使用source分割を固定し、ラスタCNN・順序不変幾何モデル・融合候補を同条件で訓練・評価できる実行経路を整え、iPad ANEに載る候補を測ることです。

## 注記: 順序不変ラスタ分類の実装開始（未評価）

直接教師から得られる入力は、数式全体画像ではなく、ラベル付きの記号ストローク群です。そこで新しい比較枝 `HinotoriRasterClassifier` を追加しました。各ストローク群を同一の単一チャネル64×64二値インク画像へ描き、画素の和集合で重ねます。ストロークの配列順は入力にせず、線分の端点を正準順にしてからラスタ化するため、ストローク順と線内の書き方向を分類特徴として符号化しません。記号内の相対位置・輪郭・交差は画像上に残ります。

分類器は229-logitの正解分類headと128次元L2正規化embeddingを出力します。前者を正解記号Top-kに使用し、後者は別途検証する視覚類似候補の距離に使用します。類似記号を正解クラスへ統合せず、位置判定もこのモデルの出力へ混ぜません。実行時には固定順229ラベル語彙を必須入力として読み、各教師の `classIndex` とラベルの一致を検査し、そのSHA-256と順序を成果物へ保存します。クラス不均衡を含む正解Top-1/Top-5、観測クラスmacro recall、全混同行列、クラス別supportをepochごとに保存し、source-disjoint valid Top-1最高epochをcheckpointとして保持します。

実装ファイルは `hinotori_raster_classifier.py` と `train_hinotori_raster_classifier.py` です。これは既存の軌跡Transformerを上書きせず、比較用の新枝として追加しました。直接教師・sourceSplit・MathWriting train InkMLを使用し、source重複は実行時に拒否します。MPSが使えない場合はCPUへ迂回せず停止します。

この変更は設計仮説をコードにした段階であり、学習、精度測定、置換/反転不変性の実測、Core ML変換、ANE実機実行はまだ行っていません。既存validは過去にチェックポイント選択等へ使われたため、今後ここで得られる値は開発比較に限り、最終独立性能として報告しません。既知の過去使用と独立性の限界を明記したうえで、別の未使用正解集合を用意して最終評価します。

### 実験開始前のラスタ入力欠陥の修正

分類器のバッチ化を照合したところ、既存の `collate_direct_anchors` はバッチ内で最大の筆画数に合わせてゼロ筆画を追加する一方、初版 `collate_rasters` はこの padding mask を無視して全筆画を描画していました。正規化後の原点 `(0,0)` は有効座標なので、ゼロ筆画を「空」と値から判別することはできず、少ない筆画数の記号へ偽の中心点が追加される入力汚染が起きます。`train_hinotori_raster_classifier.py` は `strokePadding` で真の筆画だけをラスタ化するよう修正し、可変筆画数バッチと個別ラスタの画素一致を確認しました。このため、修正前の実装を使ったラスタ学習結果は有効な比較値として扱いません。

公式MathWritingアーカイブは `symbols/` に個別手書きグリフ6,423件を収録し、`symbols.jsonl` に元のtrain式ID、該当ストロークID、グリフLaTeXラベルを直接対応付けています。これは式全体230k件のラベルから切り出し位置を推測する方法ではなく、公開済みの直接記号教師です。一方、同じグリフを作った元Inkは `train/` にあり、`synthetic/` は `symbols/` のグリフを組み合わせて生成されます。したがって、synthetic画像のグリフを6,423件へ単純加算して独立した手書き例と数えることはできません。またsymbols由来の一部を評価へ移した場合、同じ元train式IDの直接記号例は学習側から除外する必要があります。公式仕様は `symbols` の件数、由来、対応情報、CC BY-NC-SA 4.0を明記しています。

## 229クラスのデータ拡張候補と比較の境界

| 資料 | 直接記号教師・対象 | 火の鳥での利用可能性 | 比較上の制約 |
|---|---|---|---|
| MathWriting `symbols/` | 6,423個のオンライン孤立グリフ。元の式IDとtrace IDsを保持 | 229語彙への正規化後、直接教師の主枝に使える | 元式単位で分割し、関連する全グリフを同じsplitへ置く。公開test/validを訓練へ混ぜない |
| MathWriting+ | 約143kの式中グループ注釈を含む。記号群は分類器による自動注釈を含む | 229語彙との交差を測り、直接教師だけの枝と分離して弱教師枝として比較する価値がある | 自動ラベルの誤りとクラス外ラベルがあり得る。独立正解や人手goldとして評価に使わない |
| CROHME 2023 | オンラインInkMLに加え、symbol-level Label Graphを公開。学習用人工オンライン式も含む | 229語彙とのクラス交差を調べ、実記号ノードだけを対応表で抽出できれば直接の追加候補になる | 競技データのライセンス・split・ラベル体系に従い、人工Inkと実筆Inkを別層として記録する。CROHMEの式認識ExpRateを229分類Top-kへ転用しない |
| HWRT / Detexify由来コーパス | オンライン孤立記号、座標とuser ID、複数LaTeXクラス。公開ページ記載のDBライセンスはODbL | クラス名を正規化して229語彙との交差・件数・user分割を先に監査する価値がある | 書き手数・収録条件がMathWritingと異なり、ODbLの派生DB/モデル配布上の適用は未確認。過去論文の369-way Top-3は火の鳥のTop-1/Top-5と比較できない |

したがって「直接教師が約6.4kで固定」とはまだ言えません。追加候補は存在しますが、語彙交差、ラベルの直接性、重複、元式/書き手の分割、ライセンスを実データで監査する前に、229クラスの教師数へ足してはいけません。先にCROHME 2023のsymbol graphとHWRTのクラス対応・分布を監査し、クラス別の追加件数と分割可能性を確定します。MathWriting+はその次に、疑似教師の誤りを測る専用枝として扱います。

歴史的数値の追加注意: HWRTの公開資料にある369出力クラスMLPのTop-3誤り率は、手書き数式専用229語彙でも完全一致の比較条件でもありません。入力にストローク数と固定本数の点列を含み、ユーザーが指定した書き方向・順序不変要件とも違います。参考研究としてのみ保持し、火の鳥の順位表へ混ぜません。CROHME 2016ではMyScriptがvalid isolated-symbol Task 2aで92.81%を報告しましたが、こちらも101クラスで、無効分割記号を含むTask 2bとは別の試験です。

## 2026-11-03 開発用直接教師評価と順序不変モデル実験

既存のsource-disjoint開発集合で、保持済みretrieval checkpoint（`nextWeakPair=1,464,832`）を再評価しました。これは数式式全体認識ではなく、正解記号群が既に切り出された直接教師分類です。評価集合は1,281例・222クラスで、7クラスは評価例ゼロです。Top-1は651/1,281=50.82%、Top-5は1,060/1,281=82.75%。このvalid集合は過去のcheckpoint選択・調整にも使われたため、最終独立テスト値ではありません。

上位の誤認は、`\underline → \frac` 10例、`- → \frac` 8例、`\oplus → \bigoplus` 7例、`T → \top` 6例、`4 → \psi` 6例、`p → P` 6例です。横線系が主要誤りであり、手書き座標・式内位置の情報を残す設計と、横線類の字形表現を改善する根拠になります。ただし誤認表だけから原因を位置またはCNN形状に帰属させてはいけません。

同時に保存されていた位置ルールv1の段階別記録では、Top-1を誤答から正答へ変えた例が10、正答から誤答へ変えた例が2で、差し引き+8/1,281（+0.62ポイント）でした。Top-5 recallは不変です。正しい反転は主に `\underline/\overline/\frac`、`\cup/\bigcup`、`\cap/\bigcap` 群に集中します。これはposition-v1の開発集合結果です。後続の類似距離付きv3実装と同じ指標・同じ生成版を再実行するまで、v3の効果とは扱いません。

この実測とソース監査から、現在の主軌跡モデルにGRUを通じたストローク順依存があることも確認しました。ストローク順と線内方向を入力特徴にしない対照として、既存コードの `HinotoriRasterClassifier` を新しい独立runで学習しています。入力は正準座標から作る64×64二値インク画像の和集合、クラス数229、損失は通常の交差エントロピーです。trainは5,124例/2,739数式ソース、開発validは1,281例/686ソースです。trainに1例しかないクラスが3つあり、5例以下が7クラスあるため、ラスタCNNが優位とは事前に仮定しません。

ラスタ実験はMPSを使い、旧retrieval checkpointと同じsource split上で進行中です。学習完了前のTop-1/Top-5、ANE互換性、最適性は未確定です。validは開発用に限定し、最終性能を主張するには、学習・選択で一度も使わない直接記号gold集合が別途必要です。候補epochはTop-1とTop-5の両方を記録し、片方の最大値をもう片方の指標と切り離して報告しません。

## 2026-11-03 画像認識方式の系譜と火の鳥への適用範囲

「画像学習モデルの歴史」は無限に列挙できる名称一覧ではなく、火の鳥の入力契約（229種の**既に切り出された記号ストローク群**）と制約（順序・線方向をラベル手掛かりにしない、iPad上のCore ML/ANE）に効く方式の系譜として整理します。式全体の系列生成・構造解析の精度を、孤立記号Top-kの実績に読み替えません。

| 系譜 | 代表的な考え方・原典 | 火の鳥での位置づけ |
| --- | --- | --- |
| 手設計特徴＋分類器 | HOG/局所勾配、形状記述子をSVM等へ渡す古典的パターン認識 | 小規模229記号の簡易比較基準としては有用。前処理・特徴の情報損失を明示し、CNNより勝るか同一分割で測る。 |
| 畳み込み分類器 | LeCunらのLeNet系は局所受容野・重み共有・誤差逆伝播で文書画像から特徴を学習 | 画像分類の基礎対照。高解像度を要するか、二値ラスタの線幅・正規化が誤認を生むかを検査する。 |
| 残差CNN | ResNetは恒等スキップで深い表現を最適化しやすくする | 深さが必要かを検証する候補。ただしImageNetでの優位は、少数例・細線・229クラス・ANE条件での優位を証明しない。 |
| モバイルCNN | MobileNetはdepthwise separable convolutionで計算量と精度の交換を設計 | iPad配布に適した候補。Core ML変換後の実測レイテンシ・メモリ・ANE配置を含めて比較し、変換可能性だけで採用しない。 |
| Vision Transformer | ViTはパッチ列へ自己注意を適用。原典は大規模事前学習後の転移で強い結果を報告 | 直接教師5,124例だけでViTを一から学習する根拠にはならない。互換のある事前学習重みとライセンスが確認でき、微調整比較を組める場合のみ候補にする。 |
| オンライン軌跡・ハイブリッド | ペン座標/ストローク列をCNN、RNN/attentionなどで符号化。SCAN等はストローク単位の表現を式認識へ使う | 座標・曲率・連結を保てる一方、時間順がラベルへ漏れる危険がある。既存Hinotori軌跡EncoderはストロークGRUにより順序依存で、契約適合を別途直す必要がある。 |
| 構造・グラフ型HMER | G2G等は式の記号・関係・構造をグラフとして扱い、WAP等は画像から式系列を生成 | 数式全体の構造認識向けであり、229種の孤立記号分類器の代替とは扱わない。アプリの後段構造処理に関する研究として分離する。 |

原典: [LeCun et al., Gradient-Based Learning Applied to Document Recognition (1998)](https://doi.org/10.1109/5.726791)、[He et al., Deep Residual Learning (CVPR 2016)](https://openaccess.thecvf.com/content_cvpr_2016/html/He_Deep_Residual_Learning_CVPR_2016_paper.html)、[Howard et al., MobileNets (2017)](https://arxiv.org/abs/1704.04861)、[Dosovitskiy et al., ViT (ICLR 2021)](https://openreview.net/forum?id=YicbFdNTTy)、[Wang et al., SCAN (2021)](https://arxiv.org/abs/2002.08670)、[Wu et al., Graph-to-Graph HMER (AAAI 2021)](https://doi.org/10.1609/aaai.v35i4.16399)、[Truong et al., HMER survey (2024)](https://doi.org/10.1016/j.patcog.2024.110531)、[Cui et al., Class-Balanced Loss Based on Effective Number of Samples (CVPR 2019)](https://openaccess.thecvf.com/content_CVPR_2019/html/Cui_Class-Balanced_Loss_Based_on_Effective_Number_of_Samples_CVPR_2019_paper.html)。各原典の公表指標は入力、語彙、分割、課題が異なるため、下記の火の鳥実測値と直接順位比較しません。

### この系譜からの暫定判断

1. 火の鳥で競うべき一次指標は同一の切り出し済み直接教師での**完全ラベルTop-1/Top-5**。式全体ExpRateは別の課題・別表にする。
2. 第一候補を「高性能そうな深層モデル」と先に決めず、(a) HOG+線形/SVM、(b) 小型CNN、(c) MobileNet系CNN、(d) 順序・方向不変の座標集合モデルを、同一source-disjoint split・同じ画像/座標入力仕様・同じTop-kで比べる。古典基準を含める理由は、少数例で大きなモデルが実際に勝つかを確かめるためである。
3. ViT/大規模モデルは、229語彙と入力モダリティが合う事前学習重みの出自・ライセンスを確認できない限り、訓練例数が少ない現状で優先しない。根拠なしに外部重みを持ち込まない。
4. ラスタCNNの学習済み分類headだけでは不十分だが、学習embeddingを直接教師群のクラスprototypeと照合すると、同じ開発集合上で大きく改善した。これは最終採用結果ではなく、独立テストと同条件再学習を要する強い仮説である。
5. 最適モデルは、分類性能、Top-5候補の類似群recall、位置後段の増減、順序/方向摂動安定性、ANE上の遅延・メモリ・消費を測った後に選ぶ。さらに、対応する実機iPad上で認識グラフがANEに実配置・実行されたことを「革新的なエッジモデル」と呼ぶための必要条件とする。ANE適合だけでアルゴリズム上の新規性や性能優位は証明されない。現状は実機ANE配置を確認できておらず、採用・革新性・完成・世界首位の結論は出ていない。

### 順序不変ラスタCNNの実測結果（同一分割）

augmentationなしの40 epoch実験は、Top-1最高がepoch 38で、train 5,124例はTop-1 86.05% / Top-5 99.49% / macro recall 79.16%、source-disjoint valid 1,281例はTop-1 35.60% / Top-5 73.46% / macro recall 35.87%でした。valid Top-5最高はepoch 39で75.18%、その時のTop-1は35.60%です。valid Top-1最高点とTop-5最高点を別々に記録しました。train-valid Top-1差50.45ポイントは大きく、少数直接教師への過学習が実測されています。

同一valid上の既存Hinotori形状モデル（retrieval checkpoint）はTop-1 50.82% / Top-5 82.75%でした。augmentationなしのラスタCNNはTop-1で−15.22ポイント、Top-5で−9.29ポイントであり、順序不変にしただけでは置換になりません。validで多い混同は `|→\prime` 12例、`T→\top` 11例、`\underline→\frac` 10例、`K→k` 9例、`-→\frac` 8例です。詳細は `runs/hinotori-valid-evaluation-20261103/raster-order-invariant-results.json` に保存しました。

過学習を抑えるため、訓練ラスタへ最大±0.08 rad回転、0.90–1.10倍拡大縮小、各軸±0.06平行移動を加え、反転は行わない単一要因比較を完了しました。valid処理・ラベル・split・初期化seed・損失・40 epochは同じです。Top-1最高はepoch 40でtrain 64.73% / valid 46.99%、Top-5 97.60% / 89.46%。Top-5最高はepoch 39でtrain 97.74% / valid 89.54%、その時のTop-1は64.46% / 45.90%です。Top-1最高点のtrain-valid差は17.74ポイントで、augmentationなしの50.45ポイントから縮小しました。保持済み形状モデルと比べるとTop-1は−3.82ポイント、Top-5は+6.79ポイントです。完全一致Top-1を上げるには未達ですが、候補Top-5を改善する独立した画像枝として継続検証の価値があります。Valid Top-1最高の混同上位は `T→\top` 13、`|→\prime` 12、`K→k` 10、`\oplus→\bigoplus` 10、`\underline→\frac` 10。精密な指標、両チェックポイントのhash、クラス別誤りは `runs/hinotori-valid-evaluation-20261103/raster-affine-results.json` に保存しました。validは開発用のままであり、最終評価や世界順位の根拠ではありません。


逆平方根クラス重み付け（`n_c^-0.5`、229クラス平均weight=1）を、上記affine設定の他条件を固定して40 epoch実行しました。Top-1最高はepoch 39でtrain 5,124例が67.88% / valid 1,281例が49.96%、Top-5は98.30% / 90.94%、macro recallは60.59% / 51.66%。Top-5最高はepoch 37でtrain Top-1/Top-5 66.92% / 98.24%、valid 49.57% / 91.49%、macro recall valid 50.76%。Top-1はaffineのみの46.99%から+2.97ポイント、Top-5は89.46%から+1.48ポイント改善しましたが、既存retrieval候補Top-1 50.82%を0.86ポイント下回ります。訓練Top-1とvalidの差は17.92ポイントで、過学習は残っています。独立Top-1/Top-5 checkpoints、訓練・valid完全混同行列、class supportとhashは `runs/hinotori-valid-evaluation-20261103/raster-affine-balanced-results.json` に保存しました。

同じepoch 39の128次元L2正規化画像embeddingを、train直接教師5,124例から作った229個のクラス平均prototypeへコサイン照合する開発評価も行いました。各クラスprototypeはtrainのみから作り、valid画像からは一切作っていません。prototype cosine順位だけではvalid Top-1 65.89% (844/1,281)、Top-5 92.90%、観測222クラスmacro recall 66.92%でした。分類logitとの重みをvalid上で走査するとさらに高い値が出ますが、そこでの重み選択はvalidへの適合を含むため採用判断には用いず、別途記録しています。推論仕様としても、これはTop-5候補だけの後処理ではなく、229クラス全体へembedding類似度を適用する別の類似順位器です。位置判定とは分離したままです。結果は `runs/hinotori-valid-evaluation-20261103/raster-balanced-prototype-rerank.json` に保存しました。

#### 数式source単位holdoutでの再検証

開発valid再使用の偏りを避けるため、旧splitの直接教師train sourceだけを、数式 `sourceSampleId` 単位で訓練2,219数式/4,129記号、内部検証246数式/483記号、未使用テスト274数式/512記号へ再分割しました。分割seedは20261103で、source交差は0、全229クラスが訓練に残ることを確認しました。テスト教師は学習・epoch選択・重み付け・prototype生成に使わず、40 epoch学習と内部検証でのTop-1/Top-5各チェックポイント固定後に一度だけ評価しました。

Top-1最良epoch 40のテストでは、分類headがTop-1 256/512=50.00%、Top-5 459/512=89.65%。同じモデルの訓練embeddingからクラス平均prototypeを作り、全229 prototypeとのコサイン類似度で順位付けした方式はTop-1 334/512=65.23%、Top-5 474/512=92.58%、テスト出現195クラスmacro recall 65.66%でした。したがって、この固定holdoutではprototype順位付けが同一入力・同一checkpointの分類headよりTop-1 +15.23ポイント、Top-5 +2.93ポイントでした。Top-5最良epoch 39でもprototypeは64.84% / 91.60%です。これは229記号全体Top-kであり、数式全体認識ではありません。

fold-01テスト512例には195クラス、fold-02テスト490例には188クラスが現れ、各foldで未観測クラスがありました。macro recallはそれぞれのfoldに出現したクラスだけを分母とし、欠測クラスを正解扱いしていません。source partitionの構築時には、クラスが訓練側から消えないようクラスのsource出現情報を読んで割当を制約し、support数もmanifestへ記録しました。予測成績はcheckpoint固定後まで算出せず、test由来の重み、prototype、epoch選択、閾値調整は行っていません。2回とも各モデル固有のsource-group holdoutとして評価しましたが、fold-01とfold-02のtest source 30件が重複するため、統合して2-fold交差検証や独立2倍標本として集計しません。語彙229クラスすべての性能、既存trajectory候補との同条件優劣、世界順位の証拠にも不足します。結果、両checkpoint SHA-256、完全混同行列、クラス別support、誤認ペアを各foldの `test-results.json` と同じフォルダのmanifestに保存しました。prototypeは学習済み表現の一例ごとのコサイン距離を用いるので、既存の類似記号契約のように距離を候補へ保持する設計と整合します。ただし類似群候補・位置後処理・MathML確定UI・Core ML/ANE接続はこの測定に含みません。

fold-02ではTop-1最良epoch 40の残差CNN分類headがTop-1 259/490=52.86%、Top-5 455/490=92.86%。訓練embeddingのみから作った229クラスprototype類似順位はTop-1 334/490=68.16%、Top-5 455/490=92.86%、出現188クラスmacro recall 68.46%でした。同じcheckpointのheadと比べ、prototypeはTop-1を+15.31ポイント上げ、Top-5を維持しました。fold-01のprototypeは65.23% / 92.58%だったのでTop-1は同方向に再現しましたが、テストsourceの重複30件と単一設定のため、これを独立した完全交差検証の平均とは扱いません。fold-02の結果は `runs/hinotori-raster-holdout-v1-20261103/fold-02/residual-test-results.json` にあります。

fold-03は過去fold-01/02の外側テストsourceを除いた新しいsource群から層化して作り、訓練2265数式/4085記号、内側検証252/456、外側テスト222/583としました。テストには229クラス中226クラスが出現し、3クラスは標本がありません。CE基準と、同じ残差CNN・初期seed・分割・拡張・逆平方根クラス重み・optimizerに supervised contrastive loss (weight 0.1, temperature 0.1) を追加したモデルを各40 epoch、MPSで学習しました。checkpointは内側検証だけでTop-1/Top-5別々に固定し、外側テストは両モデルの固定後に一度だけ実施しました。prototypeはそれぞれのcheckpointの訓練source表現だけから作り、全229クラスとコサイン順位を比較しています。

fold-03 outer testでCEモデルのTop-1最良checkpoint (epoch 39) は、分類head 277/583=47.51% / 517/583=88.68%、訓練prototype順位 351/583=60.21% / 529/583=90.74%、出現226クラスmacro recall 60.65%でした。Top-5最良checkpointもepoch 39で、prototypeは361/583=61.92% / 531/583=91.08%、macro recall 61.62%でした。対照学習モデルのTop-1最良epoch 40は分類head 38.77% / 83.02%、prototype 58.49% / 90.57%、macro recall 59.10%。Top-5最良epoch 37は分類head 36.02% / 81.65%、prototype 57.63% / 90.05%でした。CEに対して、対照損失0.1はこのsplitでは分類head・prototype双方のTop-1を改善せず、採用しません。CE prototypeのTop-1は対照学習prototypeより1.72ポイント高く、Top-5も0.17ポイント高い一方、標本誤差があるため微差の一般化は主張しません。分類headで多かった誤りは `\aleph→N`、`0→\odot`、`|→\prime`、`-→\frac`、prototypeでは `\frac→\underline`、`\propto→\alpha`、`/→\prime` などです。前者は形状表現、後者の線記号混同は式中位置・役割を含まない切出し単記号課題の境界を示す観測であり、位置判定効果をこの実験から推定してはいません。結果と混同行列は `runs/hinotori-raster-holdout-v1-20261103/fold-03/paired-test-results.json` にあります。

fold-04では、過去3つの外側テストformula sourceを選定元から除き、229クラスすべてをfit-trainに残したうえでテストの新規クラス被覆を優先するsource単位分割を固定しました。train 1619数式/2748記号、内側検証180/337、外側テスト200/514、テスト出現223/229クラスです。CE残差CNNと座標幾何分類器は同じseed・fit/valid source・inverse-sqrt重み・幾何augmentationでMPS上40 epoch学習し、checkpointとモデル別prototype規則をfreeze後にテストしました。ラスターCNN内側検証はTop-1 38.87% / Top-5 81.31%、順序不変幾何モデルはTop-1 8.61% / Top-5 29.97%でした。外側testでもラスター分類head 224/514=43.58% / 405/514=78.79%、fit-train prototype cosine 315/514=61.28% / 452/514=87.94%、223クラスmacro recall 59.73%。幾何モデル分類headは53/514=10.31% / 182/514=35.41%、prototypeは149/514=28.99% / 322/514=62.65%、macro recall 30.00%でした。prototypeを使っても幾何枝は大幅に劣るため、このPoint/undirected-segment set設計は現時点で不採用です。今回の比較ではラスター枝を優先し、座標モデルはより強い局所形状/接続情報を保持する設計ができるまで配布候補へ進めません。テスト混同行列ではラスターheadの `)→]`、`m→M`、`K→k` が目立ち、prototypeでは `\omega→W`、`k→\kappa`、`K→\kappa` と、字形の近い記号が残りました。分割と全方式の結果は `runs/hinotori-raster-holdout-v1-20261103/fold-04/representation-test-results.json` にあります。

#### 古典HOG線形分類器の同一fold比較

古典的なHOGは局所勾配方向を空間セルに集約し、重複ブロックで正規化した特徴を線形SVMへ渡す画像認識方式として報告されました。オンライン数学記号研究では、画像へ変換した記号にCNN、原軌跡にBLSTMを適用して融合し、MRF/MQDF基準とCROHMEで比較した例があります。これは火の鳥が字形と筆記情報を別経路で検討する根拠にはなりますが、語彙・データ・評価条件が異なるため数値を直接比べません。[Dalal & Triggs (CVPR 2005)](https://doi.org/10.1109/CVPR.2005.177)、[Nguyen, Le & Nakagawa (IEICE 2016)](https://doi.org/10.1587/transinf.2016EDP7102)。

火の鳥ではscikit-learnが使えなかったため、同じ64×64ラスタから9方向bin、8px cell、2×2 cellのL2-Hys正規化ブロックを固定抽出し、学習可能な229-way linear softmax headをMPSで80 epoch学習しました。これは元論文のSVM再現ではなく、HOG系特徴の直接比較です。同じfold-04・同じsource分割・affine augmentation・inverse-sqrt class weightです。内側検証の最高値はTop-1 45.70%（epoch 18で初回、epoch 46も同率）、Top-5 80.71%（epoch 65で初回、epoch 71も同率）でした。strict `>`でcheckpointを保存するためfreezeされたのは初回最高epoch 18/65です。残差CNNの検証Top-1 38.87%、Top-5 81.31%に対して、HOG headはTop-1で上回りTop-5で0.60ポイント下回りました。

両チェックポイントをfreeze後、既に他候補の比較に使った探索的fold-04外側testを一度スコアしました。HOG classifier headはTop-1 238/514=46.30%、Top-5 410/514=79.77%、macro recall 43.43%。CNN classifier headは43.58%/78.79%、fit-train prototype順位は61.28%/87.94%。HOG descriptorをfit-train prototypeで順位付けすると38.91%/70.82%へ落ちました。よって、手設計特徴はこの分割の分類headを上回ったものの、CNNの学習embedding+prototype方式が優位です。これは独立した最終評価ではなく、既使用testを含む探索比較です。HOG prototypeは `3→B`、`\frac→-`、`\sqrt→\neg`、`1→|` の誤りが目立ち、CNN prototypeは `\omega→W`、`k→\kappa`、`K→\kappa` が残りました。完全なhash・混同行列は `runs/hinotori-raster-holdout-v1-20261103/fold-04/hog-linear-test-results.json`、80epoch推移は同フォルダ `hog-linear/metrics.jsonl` に保存しました。HOG+SVM、特徴のbilinear orientation interpolation、古典MQDF/MRFは未実施です。

#### 同じsource fold上のMobileNet系列との比較

ResNetを含む残差学習とMobileNetのdepthwise separable convolutionは異なる画像CNNの設計系列です。これを比較するため、同じfold-01、同じラスタ入力、train-only affine、逆平方根クラス重み、seed、40 epoch予算、最適epochを決める内部検証、封印testで比較しました。MobileNet型は164,789 parameters、残差CNNは624,357 parameters（約73.6%少ない）でした。内部検証ではMobileNetのTop-1最高がepoch 34で34.78%、Top-5最高がepoch 40で76.60%です。

外側test上で、MobileNetのTop-1最良checkpoint（epoch 34）は分類head 31.84% / 70.12%、訓練のみで作るprototype類似順位は51.56% / 83.40%。Top-5最良checkpoint（epoch 40）は分類head 36.72% / 74.41%、prototype順位52.34% / 85.35%でした。残差CNNの同じfold・Top-1最良checkpointは分類head 50.00% / 89.65%、prototype順位65.23% / 92.58%。この実験条件ではMobileNetのパラメータ削減と引き換えの精度低下が大きく、現在の候補としては残差CNN+prototypeを優先します。ただしANE上の遅延・メモリ・消費電力を測っていないため、端末上の総合優劣は未確定です。完全な2系列比較結果は `runs/hinotori-raster-holdout-v1-20261103/fold-01/mobilenet-test-results.json` に保存しました。学習epochが固定予算であったため、MobileNetをより長く学習した場合の可能性までは否定しません。その再調整はこの既使用test foldでは行わず、新しい外側foldで行います。

### 歴史レビュー後の現時点の結論と次工程

モデル史の比較から、数式画像認識全体（HMER）と切り出し済み単記号分類を同じ指標で並べることはできません。LeNet/CNN、残差CNN、MobileNet、ViTは画像表現の系列、オンライン軌跡モデルは座標・筆順系列の系列、SCANやGraph-to-Graphは式全体の構造復元系列です。Hinotoriの課題に直接比較可能なのは同一229語彙・同一入力境界・同一source分割で再評価した結果のみです。fold-04では残差CNN、MobileNet、HOG線形head、順序不変座標集合、classifier/prototype方式を測定しました。HOG-SVM、古典MQDF/MRF、さらに強い接続構造を保持する画像+軌跡融合は未比較です。「最適」はまだ決められません。

prototype順位付けはfold-01/02/03/04で分類headよりTop-1が高く、fold-04では+17.70ポイントでした。HOG線形headはfold-04で残差CNN headをTop-1 +2.72ポイント、Top-5 +0.97ポイント上回りましたが、CNN prototypeよりTop-1 −14.98、Top-5 −8.17ポイントでした。supervised contrastive loss weight 0.1と順序不変Point/segment集合枝は各比較でCE残差CNNより劣りました。

#### fold-05: 凍結済みCNN/HOGとvalidation-only score fusion

fold-05は過去outer-testに一度も含まれないsource formula群から構成し、source単位でtrain 3,061 formula/5,455 symbol、inner validation 155/450、outer test 209/500に分けました。500は統計的検出力計算による十分性の保証ではなく、実験の固定targetであり、クラスあたり標本が少ない探索的な新規holdoutです。outer testには229クラス中227クラスが現れず、source overlapは0です。CNNとHOGを同じtrain/validation分割で比較し、Top-1選択・Top-5選択checkpointを別々に保持しました。HOGは80 epoch、validation最良Top-1は54.44% (epoch 70)、最良Top-5は82.89% (epoch 79)。CNNは40 epoch、validation最良Top-1 54.89% (epoch 36)、Top-5 89.56% (epoch 38)でした。

checkpointとprototypeはtestを開く前に固定しました。各scoreの温度と3方式の凸結合重みはinner validationのNLLだけで選びました。Top-1候補はCNN classifier 0.00、CNN fit-train prototype 0.85、HOG classifier 0.15。Top-5候補も同じ重みです。outer testではCNN Top-1 checkpointのprototype単独が334/500=66.80% Top-1、461/500=92.20% Top-5。Top-1選択融合は328/500=65.60% / 463/500=92.60%、Top-5選択融合は321/500=64.20% / 466/500=93.20%。従って融合はTop-5を最大1.00ポイント上げた一方、Top-1はprototype単独より低く、Top-1最大方式として採用しません。HOG classifier単独は49.20% / 85.80%、CNN classifier単独は52.80% / 89.60%。source formulaをcluster単位に再標本化した2,000回bootstrapの95% percentile区間は、CNN prototype Top-1 [61.84%,72.00%]・Top-5 [89.09%,95.13%]、Top-1融合 [60.50%,70.91%]・[89.79%,95.28%]、Top-5融合 [59.15%,69.52%]・[90.19%,96.02%]です。単fold・500例の区間であり、複数fold一般化や世界順位の証明ではありません。

Top-1選択融合の誤りでは `-→\\frac` (4件)、`X→x` (4)、`\\overline→\\frac` (3)、`X→\\times` (3)、`\\circ→O` (2)、`6→b` (2)が反復しました。CNN prototype単独では `X→\\times`、`T→\\top`、`\\epsilon→\\in`、`\\rho→p`が各3件で、`X→x`、`\\overline→\\frac`、`6→b`などが各2件でした。これは認識後候補や文脈位置判定で改善可能な仮説ですが、今回の集計には類似候補・位置規則は実装も評価も含まれません。raw classifier/HOGとの全指標、誤認ペア、hash、source-cluster区間は `runs/hinotori-raster-holdout-v1-20261103/fold-05/score-fusion-test-results.json` に保存しました。HOG+SVM、MQDF/MRF、Core ML/ANEは未実施です。

次は直接教師v2（矛盾strokeに触れる3 annotationのみ除外し、15件を復元）から、既存fold-01〜05すべてのouter-test sourceを除外した新規foldを作ります。v2で修正した教師生成の影響と、学習済み特徴prototypeが他の未使用sourceにも再現するかを検証し、その後に距離付き類似候補・位置後処理とANE制約へ進みます。なお、現状の比較範囲で「世界最適」や「世界首位」は未証明です。

#### fold-06: 修正済み直接教師v2・CNN/HOG同一分割

fold-06は教師v2を使用し、fit 5,470記号/3,065 source、inner validation 450/162 source、outer test 500/199 sourceをsource formula単位で分離しました。過去fold-01〜05のouter-test sourceとの重複は0、outer testでは229クラス中225クラスが観測されました。テスト500例はfold-05と同じく固定targetで、検出力設計済みの標本数ではありません。

40 epochの残差CNNはinner validation Top-1最良55.78% (epoch 40)、Top-5最良90.22% (epoch 38)。80 epochのHOG線形分類器はTop-1最良56.00% (epoch 47)、Top-5最良86.67% (epoch 60)でした。外部テストの比較前に四つのcheckpointを固定し、prototypeと融合温度・重みはinner validationだけで決めています。outer testではCNN Top-5 checkpointのfit-train prototypeが329/500=65.80% Top-1、464/500=92.80% Top-5。validation選択Top-5融合（prototype 0.80、HOG classifier 0.20、CNN classifier 0.00）は330/500=66.00% / 468/500=93.60%。Top-1選択融合は63.80% / 92.80%。CNN Top-1 prototypeは63.20% / 91.80%、HOG Top-1 classifierは51.20% / 84.20%、CNN Top-1 classifierは51.60% / 89.60%でした。したがってこのfoldではTop-5選択融合が点推定上のTop-1をprototypeより0.20ポイント、Top-5を0.80ポイント上回りましたが、source-cluster bootstrap 95%区間は両者で大きく重なります（Top-5選択融合: Top-1 [61.43%,70.38%], Top-5 [91.00%,96.16%]; CNN Top-5 prototype: [61.34%,70.40%], [90.00%,95.60%]）。この差を有意な改善とは断定しません。

fold-05はTop-1 prototype 66.80% / 92.20%が点推定首位、fold-06はTop-5選択融合66.00% / 93.60%が点推定首位です。外部source群が異なる2 foldの順位差だけから、新モデルの優位・過学習・改善を断定できません。fold-06の誤認ペアでは `/→\\prime` と `9→q` が各3件、`,→\\prime`、`\\tilde→\\sim`、`\\subset→c`、`\\sum→\\Sigma`などが各2件でした。全候補、固定checkpoint SHA、データSHA、calibration、confusionは `runs/hinotori-raster-holdout-v2-20261103/fold-06/score-fusion-test-results.json` に保存しました。類似距離・位置規則・Core ML/ANEはこの評価に含まれていません。

次の未完了ブロックはfold-07のより大きい1200例outer testを使う前に、比較方式と前処理をinner validationで事前固定することです。理論レビューの追加候補であるMQDF、テンプレート/弾性距離、軌跡BLSTM/HMMは未実装・未評価です。現状の比較範囲で「世界最適」や「世界首位」は未証明です。
