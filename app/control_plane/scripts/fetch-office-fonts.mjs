#!/usr/bin/env bun
/**
 * Fetches Ankole's open-licensed Office site fonts from the unified
 * `AgentBull/ankole-fonts` release (or a verified local release directory),
 * writes content-addressed `.ttf` files plus `.gz` sidecars, generates
 * `manifest.json` for browser Web Workers (`/fonts/office/`), and writes
 * `THIRD-PARTY-NOTICES.txt` with verified upstream license texts.
 */

import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { gzipSync } from 'node:zlib'

const ANKOLE_FONTS_REPO = 'AgentBull/ankole-fonts'
const ANKOLE_FONTS_VERSION = 'v2-3544df1485c63aaf'

function parseArgs(argv) {
  let destinationArg = null
  let sourceDirArg = process.env.ANKOLE_FONTS_SOURCE_DIR?.trim() || null

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === '--source-dir') {
      const next = argv[i + 1]
      if (!next) {
        throw new Error('--source-dir requires a directory path')
      }
      sourceDirArg = next
      i += 1
    } else if (arg.startsWith('--source-dir=')) {
      sourceDirArg = arg.slice('--source-dir='.length)
    } else if (arg.startsWith('-')) {
      throw new Error(`Unknown flag: ${arg}`)
    } else if (!destinationArg) {
      destinationArg = arg
    } else {
      throw new Error(`Unexpected positional argument: ${arg}`)
    }
  }

  return {
    destination: path.resolve(destinationArg ?? '/usr/share/ankole/fonts'),
    sourceDir: sourceDirArg ? path.resolve(sourceDirArg) : null
  }
}

const { destination, sourceDir } = parseArgs(process.argv.slice(2))
mkdirSync(destination, { recursive: true })

const defaultCacheRoot = existsSync(path.resolve(import.meta.dirname, '../../../package.json'))
  ? path.resolve(import.meta.dirname, '../../../.cache/ankole-fonts', ANKOLE_FONTS_VERSION)
  : null
const cacheDir = process.env.ANKOLE_FONTS_CACHE_DIR?.trim()
  ? path.resolve(process.env.ANKOLE_FONTS_CACHE_DIR.trim(), ANKOLE_FONTS_VERSION)
  : defaultCacheRoot

const OFFICE_FONTS = [
  // WordCraft / DeckCraft bundled Latin defaults (SIL OFL 1.1)
  {
    stem: 'Inter-Regular',
    asset: 'Inter-Regular.ttf',
    family: 'Inter',
    aliases: [
      'Aptos',
      'Aptos Display',
      'Aptos Narrow',
      'Segoe UI',
      'Segoe UI Light',
      'Segoe UI Semibold',
      'Tahoma',
      'Verdana'
    ],
    sha256: '40d692fce188e4471e2b3cba937be967878f631ad3ebbbdcd587687c7ebe0c82'
  },
  {
    stem: 'Inter-Medium',
    asset: 'Inter-Medium.ttf',
    family: 'Inter',
    sha256: '97ad806f526e41546d46365bb3a393145f75b7b1568913db74549ad8b8dba872'
  },
  {
    stem: 'Inter-SemiBold',
    asset: 'Inter-SemiBold.ttf',
    family: 'Inter',
    sha256: '78a843fade9d4612a5567302fb595b56976eb5fcebf4fea5a5912d638bafcde3'
  },
  {
    stem: 'JetBrainsMono-Regular',
    asset: 'JetBrainsMono-Regular.ttf',
    family: 'JetBrains Mono',
    aliases: ['Consolas', 'Cascadia Code', 'Cascadia Mono', 'Fira Code', 'Source Code Pro'],
    sha256: 'e6fd0d7e91550b3ed2b735d4312474362c4716edc4fc0577a0f61ed782d5aed1'
  },
  {
    stem: 'SourceSans3-Regular',
    asset: 'SourceSans3-Regular.ttf',
    family: 'Source Sans 3',
    aliases: ['Source Sans Pro'],
    sha256: '4644c81b86ec9caaa76b634889968ed3c4f4f52f054855933acc7c2b21e53b0f'
  },
  {
    stem: 'SourceSans3-It',
    asset: 'SourceSans3-It.ttf',
    family: 'Source Sans 3',
    sha256: '192afd78f0f54a3c69eaf02d43f4d9a821e9d6110e41d3d25d61a7385cd580e4'
  },
  {
    stem: 'SourceSans3-Semibold',
    asset: 'SourceSans3-Semibold.ttf',
    family: 'Source Sans 3',
    sha256: 'a3f4f8dcf343a8f24dc61951de93f3ba1558b15cd250ba24af8a40e957081b7d'
  },
  {
    stem: 'SourceSans3-Bold',
    asset: 'SourceSans3-Bold.ttf',
    family: 'Source Sans 3',
    sha256: '9214b9d95e4231c609802815c2646c98174e2102d0d37f88978a7f8e71006e6a'
  },
  {
    stem: 'SourceSerif4-Regular',
    asset: 'SourceSerif4-Regular.ttf',
    family: 'Source Serif 4',
    aliases: ['Source Serif Pro'],
    sha256: 'e5a4ee6a3d87bb9024796be390c6771e2a0eb1883dae25effaf57ca01668e24b'
  },
  {
    stem: 'SourceSerif4-It',
    asset: 'SourceSerif4-It.ttf',
    family: 'Source Serif 4',
    sha256: '9d2950a8f1da66e21502c35d646a1d2148e79f9ea43fd2158cf02f5232e7f430'
  },
  {
    stem: 'SourceSerif4-Semibold',
    asset: 'SourceSerif4-Semibold.ttf',
    family: 'Source Serif 4',
    sha256: '36db62940cb5728b12b1802476dc7fcf4c6c519a7bdd476ba23a4e555fc4655f'
  },
  {
    stem: 'SourceSerif4-Bold',
    asset: 'SourceSerif4-Bold.ttf',
    family: 'Source Serif 4',
    sha256: '7cf4f4e1ad74f45058d5bc61716b82560442fbdcd9d3654d2dea96bf6c683d86'
  },
  {
    stem: 'SourceSerif4-BoldIt',
    asset: 'SourceSerif4-BoldIt.ttf',
    family: 'Source Serif 4',
    sha256: '7b215b37f8873f5579f3f8d2ded3ca7c588e2f435cd996605ebfc5befe2cd5eb'
  },

  // Metric-compatible Office Latin twins (Carlito, Caladea, Liberation — SIL OFL 1.1)
  {
    stem: 'Carlito-Regular',
    asset: 'Carlito-Regular.ttf',
    family: 'Carlito',
    aliases: ['Calibri', 'Calibri Light'],
    sha256: 'f6418f708baede9789daef5d458c0f53d2a888af9820e8062934e504fedc6595'
  },
  {
    stem: 'Carlito-Bold',
    asset: 'Carlito-Bold.ttf',
    family: 'Carlito',
    sha256: 'bb5d20f79b82599ec72983597437373a80f2d2085fa91fc144fd74e876a594db'
  },
  {
    stem: 'Carlito-Italic',
    asset: 'Carlito-Italic.ttf',
    family: 'Carlito',
    sha256: '0b019225e58d702bfedcbd35c21696769f8ee115cb6343f84c2f240312450d1c'
  },
  {
    stem: 'Carlito-BoldItalic',
    asset: 'Carlito-BoldItalic.ttf',
    family: 'Carlito',
    sha256: 'b32928186c119599e03ca6a1ffc680fdcb7fac95772f4b95d989cf6cd3861517'
  },
  {
    stem: 'Caladea-Regular',
    asset: 'Caladea-Regular.ttf',
    family: 'Caladea',
    aliases: ['Cambria', 'Cambria Math'],
    sha256: 'f1e899278b7b4491aba5b6a8253c4b04c050cc59b21865be5c37559a775153cd'
  },
  {
    stem: 'Caladea-Bold',
    asset: 'Caladea-Bold.ttf',
    family: 'Caladea',
    sha256: 'ae3cb2dcbc925809dd29d2a44e9802211cab66be541bacbfc9c08c74b27c3742'
  },
  {
    stem: 'Caladea-Italic',
    asset: 'Caladea-Italic.ttf',
    family: 'Caladea',
    sha256: '4359a8e24f748b6447b1ff6d7a174febe70961d29f8bb8634b56dacd740a3deb'
  },
  {
    stem: 'Caladea-BoldItalic',
    asset: 'Caladea-BoldItalic.ttf',
    family: 'Caladea',
    sha256: 'ccabaa7b7e2fdf253d2b1a5fa699dd8a3df8d835a9eb285ad82631a677eb76c0'
  },
  {
    stem: 'LiberationSans-Regular',
    asset: 'LiberationSans-Regular.ttf',
    family: 'Liberation Sans',
    aliases: ['Arial', 'Helvetica', 'Helvetica Neue', 'Arial Nova'],
    sha256: '76d04c18ea243f426b7de1f3ad208e927008f961dc5945e5aad352d0dfde8ee8'
  },
  {
    stem: 'LiberationSans-Bold',
    asset: 'LiberationSans-Bold.ttf',
    family: 'Liberation Sans',
    sha256: '788abee4c806d660e8aee46689dd8540cd4bb98da03dcc9d171ce3efd99a9173'
  },
  {
    stem: 'LiberationSans-Italic',
    asset: 'LiberationSans-Italic.ttf',
    family: 'Liberation Sans',
    sha256: 'e5bae5c4cde31f22142753855f4f8fb86da6ff39955ed3c0a11248b0d16948b0'
  },
  {
    stem: 'LiberationSans-BoldItalic',
    asset: 'LiberationSans-BoldItalic.ttf',
    family: 'Liberation Sans',
    sha256: '698da70fc191cc5f33ad4d6d3fe830fe4624b898ea2e3169955928b7c491f1ee'
  },
  {
    stem: 'LiberationSerif-Regular',
    asset: 'LiberationSerif-Regular.ttf',
    family: 'Liberation Serif',
    aliases: ['Times New Roman', 'Times', 'Georgia'],
    sha256: '058ea80864aef09a23f45cbec2bb5400bc3dfbdea01c3f10538a21fcb497fb74'
  },
  {
    stem: 'LiberationSerif-Bold',
    asset: 'LiberationSerif-Bold.ttf',
    family: 'Liberation Serif',
    sha256: 'd754ba427cfe0bca54ae052384baa8f842da5bd6550ad4da024ac441e7a7d5ce'
  },
  {
    stem: 'LiberationSerif-Italic',
    asset: 'LiberationSerif-Italic.ttf',
    family: 'Liberation Serif',
    sha256: '0e3dea9f8d613e006ccfa62201f33e265d19167bd0907725c3e145368b04fc2e'
  },
  {
    stem: 'LiberationSerif-BoldItalic',
    asset: 'LiberationSerif-BoldItalic.ttf',
    family: 'Liberation Serif',
    sha256: 'f17db8af71e24d2066b587546021d4f0b296be389512b658dec3c09affeb11a7'
  },
  {
    stem: 'LiberationMono-Regular',
    asset: 'LiberationMono-Regular.ttf',
    family: 'Liberation Mono',
    aliases: ['Courier New', 'Courier', 'Menlo', 'Monaco'],
    sha256: 'f2b83c763e8afd21709333370bed4774337fae82267937e2b5aea7e2fbd922c1'
  },
  {
    stem: 'LiberationMono-Bold',
    asset: 'LiberationMono-Bold.ttf',
    family: 'Liberation Mono',
    sha256: 'bd62a0672d0b9b6710b01df434c80ad54fa5f0835207eb7b17b7a761463067bb'
  },
  {
    stem: 'LiberationMono-Italic',
    asset: 'LiberationMono-Italic.ttf',
    family: 'Liberation Mono',
    sha256: '605c01c711b44480a7508d349dfbf3264e81fa43d69e61cfa7d10b86e764c4d1'
  },
  {
    stem: 'LiberationMono-BoldItalic',
    asset: 'LiberationMono-BoldItalic.ttf',
    family: 'Liberation Mono',
    sha256: '79451f3c09fe25116098853b7a2ca6e2436220ccc11af022979adbcf195be130'
  },

  // Ankole first-party Simplified Chinese fonts (SIL OFL 1.1 — shared with Agent Computer)
  {
    stem: 'IBMPlexSansSC-Regular',
    asset: 'IBMPlexSansSC-Regular.ttf',
    family: 'IBM Plex Sans SC',
    aliases: [
      'IBM Plex Sans',
      'Microsoft YaHei',
      'Microsoft YaHei UI',
      'Microsoft YaHei Light',
      '微软雅黑',
      '微软雅黑 Light',
      'DengXian',
      'DengXian Light',
      '等线',
      '等线 Light',
      'SimHei',
      '黑体',
      'PingFang SC',
      '苹方-简',
      '苹方',
      'Heiti SC',
      '黑体-简',
      'STHeitiSC',
      'STHeiti',
      'STXihei',
      '华文黑体',
      '华文细黑',
      'YouYuan',
      '幼圆',
      'Noto Sans SC',
      'Noto Sans CJK SC',
      'Source Han Sans SC',
      'Source Han Sans CN',
      '思源黑体',
      '思源黑体 CN',
      'HarmonyOS Sans SC',
      'MiSans',
      'MI Sans',
      'OPPO Sans',
      'Alibaba PuHuiTi'
    ],
    sha256: '012e587c5a78d25f456057614b880fc7450b748c352573d8052245df2a71158a'
  },
  {
    stem: 'IBMPlexSansSC-Bold',
    asset: 'IBMPlexSansSC-Bold.ttf',
    family: 'IBM Plex Sans SC',
    sha256: '3e94ef1df394eae336cc1bc98f2160b58e2cab186f47d820e4c808aef1f4e28f'
  },
  {
    stem: 'ChillJinshuSongRegular',
    asset: 'ChillJinshuSongRegular.ttf',
    family: '寒蝉锦书宋',
    aliases: [
      'ChillJinshuSong',
      '寒蟬錦書宋',
      'SimSun',
      'SimSun-ExtB',
      '宋体',
      'NSimSun',
      '新宋体',
      'STSong',
      '华文宋体',
      'STZhongsong',
      '华文中宋',
      'Songti SC',
      '宋体-简',
      'FZXBSJW',
      'FZXBSJW--GB1-0',
      '方正小标宋简体',
      '方正小标宋_GBK',
      '方正书宋简体',
      '方正书宋_GBK',
      'Noto Serif SC',
      'Noto Serif CJK SC',
      'Source Han Serif SC',
      'Source Han Serif CN',
      '思源宋体',
      '思源宋体 CN'
    ],
    sha256: 'e3d7eac75f3ebe68986974ef6bdfc43db8e17d5a3a026d6cd779ddbf7ef7e75f'
  },
  {
    stem: 'ChillJinshuSongBold',
    asset: 'ChillJinshuSongBold.ttf',
    family: '寒蝉锦书宋',
    sha256: '1644dfb81e4777d7ea79ad5af3f9d86304795fd2d48af50e49d7def2fc935ee3'
  },
  {
    stem: 'LXGWWenKaiGB-Regular',
    asset: 'LXGWWenKaiGB-Regular.ttf',
    family: 'LXGW WenKai GB',
    aliases: [
      '霞鹜文楷 GB',
      'LXGW WenKai',
      '霞鹜文楷',
      'LXGW WenKai Lite',
      '霞鹜文楷 轻便版',
      'STKaiti',
      '华文楷体',
      'KaiTi',
      '楷体',
      'KaiTi_GB2312',
      '楷体_GB2312',
      'Kaiti SC',
      '楷体-简',
      'FangSong',
      '仿宋',
      'FangSong_GB2312',
      '仿宋_GB2312',
      'STFangsong',
      '华文仿宋',
      'Fangsong SC',
      '仿宋-简',
      'FZKai-Z03S',
      '方正楷体简体',
      '方正楷体_GBK',
      'FZFangSong-Z02S',
      '方正仿宋简体',
      '方正仿宋_GBK',
      'STXingkai',
      '华文行楷',
      'STLiti',
      '华文隶书',
      'LiSu',
      '隶书'
    ],
    sha256: '5561d48097d92e5ab99fe7b1459d381bbcdff533bfc479207b089c6860c3990e'
  },
  {
    stem: 'IBMPlexMonoSCHalf-Regular',
    asset: 'IBMPlexMonoSCHalf-Regular.ttf',
    family: 'IBMPlexMonoSCHalf',
    aliases: [
      'IBM Plex Mono',
      'IBM Plex Mono SC',
      'Sarasa Mono SC',
      '等距更纱黑体 SC',
      'LXGW WenKai Mono',
      'LXGW WenKai Mono GB',
      '霞鹜文楷等宽',
      '霞鹜文楷等宽 GB',
      'Noto Sans Mono CJK SC'
    ],
    sha256: '5787a22435e2df2df2750cba1ccfabd13f8928fe8508bd160a52cd766cb98178'
  },
  {
    stem: 'IBMPlexMonoSCHalf-Bold',
    asset: 'IBMPlexMonoSCHalf-Bold.ttf',
    family: 'IBMPlexMonoSCHalf',
    sha256: '687a51a66e6541604df2b3637801f9bb24d740aca8fd52fe0f2fca4ac1a9f14a'
  },

  // Self-hosted regional CJK variable fallbacks (TC, JP, KR — SIL OFL 1.1)
  {
    stem: 'NotoSansTC-VF',
    asset: 'NotoSansTC-VF.ttf',
    family: 'Noto Sans TC',
    aliases: [
      'Noto Sans CJK TC',
      'Noto Sans HK',
      'Noto Sans CJK HK',
      'Source Han Sans TC',
      'Source Han Sans TW',
      'Source Han Sans HK',
      '思源黑體',
      'Microsoft JhengHei',
      'Microsoft JhengHei UI',
      'Microsoft JhengHei Light',
      '微軟正黑體',
      'PingFang TC',
      '苹方-繁',
      '蘋方-繁',
      'PingFang HK',
      '蘋方-港',
      'Heiti TC',
      '黑體-繁',
      'LiHei Pro',
      '儷黑 Pro'
    ],
    sha256: '864727d210d54f2537bbe23b3a839436c3992af72de9322af5270897246bd44f'
  },
  {
    stem: 'NotoSerifTC-VF',
    asset: 'NotoSerifTC-VF.ttf',
    family: 'Noto Serif TC',
    aliases: [
      'Noto Serif CJK TC',
      'Source Han Serif TC',
      'Source Han Serif TW',
      '思源宋體',
      'PMingLiU',
      'PMingLiU-ExtB',
      '新細明體',
      'MingLiU',
      'MingLiU-ExtB',
      'MingLiU_HKSCS',
      '細明體',
      'DFKai-SB',
      '標楷體',
      'BiauKai',
      'Kaiti TC',
      '楷體-繁',
      'Songti TC',
      '宋體-繁'
    ],
    sha256: '0077e18f57c6908f4a000969880940bdb0dad057c0e8d98b49dc364c3d1b09c6'
  },
  {
    stem: 'NotoSansJP-VF',
    asset: 'NotoSansJP-VF.ttf',
    family: 'Noto Sans JP',
    aliases: [
      'Noto Sans CJK JP',
      'Source Han Sans JP',
      'Source Han Sans',
      '源ノ角ゴシック',
      'Yu Gothic',
      'Yu Gothic UI',
      'Yu Gothic Medium',
      'YuGothic',
      '游ゴシック',
      '游ゴシック体',
      'Meiryo',
      'Meiryo UI',
      'メイリオ',
      'MS PGothic',
      'ＭＳ Ｐゴシック',
      'MS Gothic',
      'ＭＳ ゴシック',
      'MS UI Gothic',
      'Hiragino Kaku Gothic ProN',
      'ヒラギノ角ゴ ProN',
      'Hiragino Kaku Gothic Pro',
      'Hiragino Sans',
      'ヒラギノ角ゴシック',
      'BIZ UDPGothic',
      'BIZ UDGothic'
    ],
    sha256: 'c2f3b4d463500a2ddcd3849cded1fceeb9fd6d1c32e6cbecd568453ba50fc68f'
  },
  {
    stem: 'NotoSerifJP-VF',
    asset: 'NotoSerifJP-VF.ttf',
    family: 'Noto Serif JP',
    aliases: [
      'Noto Serif CJK JP',
      'Source Han Serif JP',
      '源ノ明朝',
      'MS Mincho',
      'ＭＳ 明朝',
      'MS PMincho',
      'ＭＳ Ｐ明朝',
      'Yu Mincho',
      'YuMincho',
      '游明朝',
      '游明朝体',
      'Hiragino Mincho ProN',
      'ヒラギノ明朝 ProN',
      'Hiragino Mincho Pro',
      'BIZ UDPMincho',
      'BIZ UDMincho'
    ],
    sha256: '2fd527ba12b6a44ec30d796d633360da0aeba6c5d4af1304ce12bb4dc15a7dfc'
  },
  {
    stem: 'NotoSansKR-VF',
    asset: 'NotoSansKR-VF.ttf',
    family: 'Noto Sans KR',
    aliases: [
      'Noto Sans CJK KR',
      'Source Han Sans KR',
      'Source Han Sans K',
      '본고딕',
      'Malgun Gothic',
      '맑은 고딕',
      'Apple SD Gothic Neo',
      'Dotum',
      '돋움',
      'DotumChe',
      '돋움체',
      'Gulim',
      '굴림',
      'GulimChe',
      '굴림체',
      'NanumGothic',
      '나눔고딕'
    ],
    sha256: '194018e6b2b293a7964f037b25c0249ce1418bc9ab3c971060a03aa57861e252'
  },
  {
    stem: 'NotoSerifKR-VF',
    asset: 'NotoSerifKR-VF.ttf',
    family: 'Noto Serif KR',
    aliases: [
      'Noto Serif CJK KR',
      'Source Han Serif KR',
      '본명조',
      'Batang',
      '바탕',
      'BatangChe',
      '바탕체',
      'Gungsuh',
      '궁서',
      'GungsuhChe',
      '궁서체',
      'AppleMyungjo',
      'NanumMyeongjo',
      '나눔명조'
    ],
    sha256: '11f8d5de6f1b79195efba3828aaa2ec95c1178f5ae976fb23c8d53250a9938f3'
  }
]

const LICENSE_TEXTS = [
  {
    title: 'IBM Plex Sans SC (SIL Open Font License 1.1)',
    asset: 'LICENSE-IBM-Plex-Sans-SC.txt',
    sha256: '91c25c350d3cac39da2736d74f7ba37ef648f5237a4e330a240615bc8d8c4360'
  },
  {
    title: 'IBMPlexMonoSCHalf (SIL Open Font License 1.1)',
    asset: 'LICENSE-IBM-Plex-Mono-SC.txt',
    sha256: '91c25c350d3cac39da2736d74f7ba37ef648f5237a4e330a240615bc8d8c4360'
  },
  {
    title: '寒蝉锦书宋 / ChillJinshuSong (SIL Open Font License 1.1)',
    asset: 'LICENSE-ChillJinshuSong.txt',
    sha256: '027f6f68aa3c651a771d3368e7d1620acaeadfd5d00d23da44332565bc151869'
  },
  {
    title: '霞鹜文楷 GB / LXGW WenKai GB (SIL Open Font License 1.1)',
    asset: 'LICENSE-LXGW-WenKai-GB.txt',
    sha256: 'a8aa32c38a3402ba4e40fb6d39c913300dd4a0336290dce5c14e3a2f9308d092'
  },
  {
    title: 'Inter (SIL Open Font License 1.1)',
    asset: 'LICENSE-Inter.txt',
    sha256: '262481e844521b326f5ecd053e59b98c8b2da78c8ee1bdbb6e8174305e54935a'
  },
  {
    title: 'JetBrains Mono (SIL Open Font License 1.1)',
    asset: 'LICENSE-JetBrains-Mono.txt',
    sha256: 'a76abf002c49097d146e86740a3105a5d00450b1592e820a1109a8c5680cd697'
  },
  {
    title: 'Source Sans 3 (SIL Open Font License 1.1)',
    asset: 'LICENSE-Source-Sans-3.txt',
    sha256: '56af9b9c6715597e458284a474dc118a50a4150e9d547c70f7b4a33c3e6a9328'
  },
  {
    title: 'Source Serif 4 (SIL Open Font License 1.1)',
    asset: 'LICENSE-Source-Serif-4.txt',
    sha256: 'c21d7293d87b6d7ab1d0229a2f55b77f33a7613a6a4e66f6693d68d7d8d09464'
  },
  {
    title: 'Carlito (SIL Open Font License 1.1)',
    asset: 'LICENSE-Carlito.txt',
    sha256: '58402f82a7c332a700294988fe7554fbb0a63a8d27ccc1ee3bbc640311990a00'
  },
  {
    title: 'Caladea (SIL Open Font License 1.1)',
    asset: 'LICENSE-Caladea.txt',
    sha256: 'ccdab61d371d8c8683a128a92cd7d498dbdb1d37689f7cb21f1bf6b16658d213'
  },
  {
    title: 'Liberation Sans, Liberation Serif, Liberation Mono 2.1.5 (SIL Open Font License 1.1)',
    asset: 'LICENSE-Liberation.txt',
    sha256: '93fed46019c38bbe566b479d22148e2e8a1e85ada614accb0211c37b2c61c19b'
  },
  {
    title: 'Noto Sans CJK TC/JP/KR (SIL Open Font License 1.1)',
    asset: 'LICENSE-Noto-Sans-CJK.txt',
    sha256: '1c05c68c34f9708415aada51f17e1b0092d2cea709bf4a94cd38114f9e73d7d9'
  },
  {
    title: 'Noto Serif CJK TC/JP/KR (SIL Open Font License 1.1)',
    asset: 'LICENSE-Noto-Serif-CJK.txt',
    sha256: '5e0da210fb04058a8c0087985d2d456b931c2579811a49655721d3cf0c36b6d6'
  }
]

function sha256Hex(bytes) {
  return createHash('sha256').update(bytes).digest('hex')
}

function releaseAssetUrl(asset) {
  return `https://github.com/${ANKOLE_FONTS_REPO}/releases/download/${ANKOLE_FONTS_VERSION}/${encodeURIComponent(asset)}`
}

async function readOrFetchVerified(asset, expectedSha256) {
  if (sourceDir) {
    const localPath = path.join(sourceDir, asset)
    if (!existsSync(localPath)) {
      throw new Error(`Missing font asset in --source-dir (${sourceDir}): ${asset}`)
    }
    const bytes = new Uint8Array(readFileSync(localPath))
    const actual = sha256Hex(bytes)
    if (actual !== expectedSha256) {
      throw new Error(`SHA-256 mismatch for ${localPath}: expected ${expectedSha256}, got ${actual}`)
    }
    return bytes
  }

  if (cacheDir) {
    const cachedPath = path.join(cacheDir, asset)
    if (existsSync(cachedPath)) {
      const cachedBytes = new Uint8Array(readFileSync(cachedPath))
      if (sha256Hex(cachedBytes) === expectedSha256) {
        return cachedBytes
      }
    }
  }

  const url = releaseAssetUrl(asset)
  for (let attempt = 1; attempt <= 5; attempt++) {
    try {
      const res = await fetch(url, { redirect: 'follow' })
      if (!res.ok) {
        throw new Error(`HTTP ${res.status} fetching ${url}`)
      }
      const bytes = new Uint8Array(await res.arrayBuffer())
      const actual = sha256Hex(bytes)
      if (actual !== expectedSha256) {
        throw new Error(`SHA-256 mismatch for ${url}: expected ${expectedSha256}, got ${actual}`)
      }
      if (cacheDir) {
        mkdirSync(cacheDir, { recursive: true })
        writeFileSync(path.join(cacheDir, asset), bytes)
      }
      return bytes
    } catch (err) {
      if (attempt === 5) throw err
      await new Promise(resolve => setTimeout(resolve, attempt * 1500))
    }
  }
  throw new Error(`Unreachable retry loop for ${url}`)
}

function writeWithGzipSidecar(filePath, bytes) {
  writeFileSync(filePath, bytes)
  const gz = gzipSync(bytes)
  const gzPath = `${filePath}.gz`
  if (gz.byteLength < bytes.byteLength) {
    writeFileSync(gzPath, gz)
    return `${path.basename(filePath)}.gz`
  }
  rmSync(gzPath, { force: true })
  return null
}

const expectedFiles = new Set([
  'manifest.json',
  'manifest.json.gz',
  'THIRD-PARTY-NOTICES.txt',
  'THIRD-PARTY-NOTICES.txt.gz'
])
const manifestFonts = []

for (const item of OFFICE_FONTS) {
  const bytes = await readOrFetchVerified(item.asset, item.sha256)
  const file = `${item.stem}-${item.sha256.slice(0, 12)}.ttf`
  const gzFile = writeWithGzipSidecar(path.join(destination, file), bytes)
  expectedFiles.add(file)
  if (gzFile) expectedFiles.add(gzFile)
  manifestFonts.push({
    family: item.family,
    ...(item.aliases ? { aliases: item.aliases } : {}),
    file
  })
}

const noticeBlocks = [
  'Ankole Office Site Fonts — Third-Party License Notices',
  '======================================================',
  ''
]

for (const notice of LICENSE_TEXTS) {
  const bytes = await readOrFetchVerified(notice.asset, notice.sha256)
  noticeBlocks.push(`--- ${notice.title} ---`, new TextDecoder().decode(bytes).trim(), '')
}

const manifestBytes = new TextEncoder().encode(`${JSON.stringify({ fonts: manifestFonts }, null, 2)}\n`)
writeWithGzipSidecar(path.join(destination, 'manifest.json'), manifestBytes)

const noticesBytes = new TextEncoder().encode(noticeBlocks.join('\n'))
writeWithGzipSidecar(path.join(destination, 'THIRD-PARTY-NOTICES.txt'), noticesBytes)

for (const entry of readdirSync(destination)) {
  if (!expectedFiles.has(entry)) {
    rmSync(path.join(destination, entry), { recursive: true, force: true })
  }
}

process.stdout.write(
  `Installed ${manifestFonts.length} verified Office font files (${ANKOLE_FONTS_VERSION}) into ${destination}\n`
)
