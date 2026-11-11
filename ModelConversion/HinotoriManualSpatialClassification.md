# 229記号の手動分類：位置判定の要否

正本語彙契約は同梱の `Models/Hinotori/HinotoriVocabulary.json` に定義された `hinotori-v1`。以下は手動の設計分類であり、正解ラベルや評価結果ではない。入力座標と隣接候補を保持する。形のみで確定できるという意味ではなく、全記号は上付き・下付き等の構造関係の対象になり得る。位置依存の強い候補は優先して周辺構造を確認し、曖昧なら候補選択へ渡す。記号単体分類の精度と数式構造の評価を区別する。

実装が参照する位置依存の記号部分集合は、`HinotoriPositionSensitiveSubset.json` で定義する。同ファイルは、この文書のA群・B群から選んだ35語彙を、横線、点、句読点、後置・アクセント、大きさ可変演算子、被演算対象を持つ演算子、数字・英字の類似形に分ける。C群を位置だけで別ラベルへ昇格させることは、この定義では許可しない。

## 実装済み位置規則（`hinotori-position-rules-v1`）

規則は元のPencilKit座標（左上原点、下向きy軸）だけを読み、既存のHinotori候補を並べ替える。候補、logit、確定ラベルを生成しない。どの規則も、ユーザー確認前の候補順位である。

- 横線：厳密に上方・下方に記号がある場合は分数線、上方だけなら下線、下方だけなら上線を優先する。
- 点：下方に基底があればドットアクセント、左右同じ行に被演算子があれば中心点を優先する。
- 句読点：縦に整列した点対はコロン、上方の点対かつ基線より下方の成分はセミコロン、基線より下方の単独成分はコンマを優先する。
- 後置・アクセント：基底の右上ならプライム、被覆された基底の上ならアクセント候補を優先する。
- 拡大型集合演算子：中央に上下限があれば `\bigcap`、`\bigcup`、`\bigoplus`、`\bigvee`、`\bigwedge` を対応する通常演算子より優先する。左右に同じ行の被演算子だけがあれば通常演算子を優先する。`\prod` は同じ上下限構造を持つ単独候補として優先対象へ残す。
- 被演算子・スコープ演算子：演算子の横幅に被覆される被開平数があれば `\sqrt`、左右の同一行被演算子があれば `=`、中央の上下限と右側本体があれば `\sum`、`\int`、`\iint`、`\oint` の演算子群を優先する。積分の本数・閉路かどうかは位置だけでは決めず、元のHinotori順位を保持する。
- 数字・英字の類似形：隣接する先頭モデル候補が数字なら `0`、大文字なら `O`、小文字なら `o` を優先する。文脈がない場合は形状モデルの順位を保持する。

横線、点、句読点、アクセント、可変集合演算子の対、数字・英字類似形については、規則に適合する場合にだけ同一群の欠落候補を「位置規則の補助候補」として併記する。補助候補にモデルlogitは存在しないため、モデル候補の順位・scoreとは混ぜず、由来と根拠を保存・表示し、ユーザー選択なしには確定しない。

該当する位置関係がない場合は元のHinotori順位を保持する。これは暗黙の救済ではなく、位置だけで識別不能な場合に形状モデルの根拠を捨てないための明示的な規則である。

## A: 周辺配置が記号の意味・役割を直接左右する候補（21）

`-` `.` `,` `:` `;` `=` `\frac` `\underline` `\overline` `\dot` `\cdot` `\prime` `\hat` `\tilde` `\vec` `\vdots` `\sqrt` `\int` `\iint` `\oint` `\sum`

横線・点は左右や上下の配置、アクセントは付加対象、根号は被覆範囲、積分・総和は被演算対象や上下限を確認する。等号の画構成と周辺の式、句読点等も位置により解釈が変わる。候補の有無だけで確定しない。

## B: 大きさ・配置で同形候補や構造上の役割が変わり得る候補（11）

`\bigcap` `\cap` `\bigcup` `\cup` `\bigoplus` `\oplus` `\bigvee` `\vee` `\bigwedge` `\wedge` `\prod`

大演算子と通常演算子は相対的な大きさや上下限を手掛かりにするが、閾値だけで断定しない。

## C: 形の候補を主に用い、必要に応じて周辺配置・数式構造で確認する候補

`!` `(` `)` `*` `+` `/` `0` `1` `2` `3` `4` `5` `6` `7` `8` `9` `<` `>` `?`

`A` `B` `C` `D` `E` `F` `G` `H` `I` `J` `K` `L` `M` `N` `O` `P` `Q` `R` `S` `T` `U` `V` `W` `X` `Y` `Z` `[` `]`

`\#` `\%` `\&` `\Delta` `\Gamma` `\Lambda` `\Leftrightarrow` `\Omega` `\Phi` `\Pi` `\Psi` `\Rightarrow` `\Sigma` `\Theta` `\Upsilon` `\Vdash` `\Xi` `\aleph` `\alpha` `\angle` `\approx` `\backslash` `\beta` `\bullet` `\chi` `\circ` `\cong` `\dagger` `\delta` `\div` `\emptyset` `\epsilon` `\equiv` `\eta` `\exists` `\forall` `\gamma` `\ge` `\gg` `\hbar` `\hookrightarrow` `\iff` `\in` `\infty` `\iota` `\kappa` `\lambda` `\langle` `\lceil` `\le` `\leftarrow` `\leftrightarrow` `\lfloor` `\ll` `\longrightarrow` `\mapsto`

`\mathbb{A}` `\mathbb{C}` `\mathbb{D}` `\mathbb{E}` `\mathbb{F}` `\mathbb{I}` `\mathbb{K}` `\mathbb{L}` `\mathbb{N}` `\mathbb{P}` `\mathbb{Q}` `\mathbb{R}` `\mathbb{S}` `\mathbb{T}` `\mathbb{W}` `\mathbb{X}` `\mathbb{Z}`

`\models` `\mp` `\mu` `\nabla` `\ne` `\neg` `\ni` `\notin` `\nu` `\odot` `\omega` `\ominus` `\otimes` `\partial` `\perp` `\phi` `\pi` `\pm` `\propto` `\psi` `\rangle` `\rceil` `\rfloor` `\rho` `\rightarrow` `\rightleftharpoons` `\sigma` `\sim` `\simeq` `\subset` `\subseteq` `\subsetneq` `\supset` `\supseteq` `\tau` `\theta` `\times` `\top` `\triangleq` `\upsilon` `\varphi` `\varpi` `\varsigma` `\vartheta` `\vdash` `\xi` `\zeta` `\{` `\|` `\}`

`a` `b` `c` `d` `e` `f` `g` `h` `i` `j` `k` `l` `m` `n` `o` `p` `q` `r` `s` `t` `u` `v` `w` `x` `y` `z` `|`

## 実装・検証の扱い

これは対象選定であり固定ルールの正しさを保証しない。実装前に、分数線・マイナス・下線などを実座標と正解で検証し、各候補に対する失敗と未確定率を計測する。上付き・下付きは記号種別ではなく、任意記号間の関係として別に判定する。
