#!/usr/bin/env bun
/**
 * Fetches Ankole's open-licensed Office site fonts at pinned SHA-256 digests,
 * writes content-addressed font files (`<stem>-<sha12>.ttf`), generates
 * `manifest.json` for browser Web Workers (`/fonts/office/`), and writes
 * `THIRD-PARTY-NOTICES.txt` with verified upstream license texts.
 */

import { createHash } from 'node:crypto'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'

const destination = path.resolve(process.argv[2] ?? '/usr/share/ankole/fonts')
mkdirSync(destination, { recursive: true })

const WORDCRAFT_COMMIT = '45db128c150074a7f6d127ba71626ce4a30d8f3c'
const GOOGLE_FONTS_COMMIT = '8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5'
const LIBERATION_ARCHIVE = {
  url: 'https://github.com/liberationfonts/liberation-fonts/files/7261482/liberation-fonts-ttf-2.1.5.tar.gz',
  sha256: '7191c669bf38899f73a2094ed00f7b800553364f90e2637010a69c0e268f25d0',
  prefix: 'liberation-fonts-ttf-2.1.5'
}

const DIRECT_FONTS = [
  // WordCraft / DeckCraft bundled open defaults (SIL OFL 1.1)
  {
    stem: 'Inter-Regular',
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
    url: `https://raw.githubusercontent.com/storytold/wordcraft/${WORDCRAFT_COMMIT}/assets/fonts/Inter-Regular.ttf`,
    sha256: '40d692fce188e4471e2b3cba937be967878f631ad3ebbbdcd587687c7ebe0c82'
  },
  {
    stem: 'Inter-Medium',
    family: 'Inter',
    url: `https://raw.githubusercontent.com/storytold/wordcraft/${WORDCRAFT_COMMIT}/assets/fonts/Inter-Medium.ttf`,
    sha256: '97ad806f526e41546d46365bb3a393145f75b7b1568913db74549ad8b8dba872'
  },
  {
    stem: 'Inter-SemiBold',
    family: 'Inter',
    url: `https://raw.githubusercontent.com/storytold/wordcraft/${WORDCRAFT_COMMIT}/assets/fonts/Inter-SemiBold.ttf`,
    sha256: '78a843fade9d4612a5567302fb595b56976eb5fcebf4fea5a5912d638bafcde3'
  },
  {
    stem: 'JetBrainsMono-Regular',
    family: 'JetBrains Mono',
    aliases: ['Consolas', 'Cascadia Code', 'Cascadia Mono', 'Fira Code', 'Source Code Pro'],
    url: `https://raw.githubusercontent.com/storytold/wordcraft/${WORDCRAFT_COMMIT}/assets/fonts/JetBrainsMono-Regular.ttf`,
    sha256: 'e6fd0d7e91550b3ed2b735d4312474362c4716edc4fc0577a0f61ed782d5aed1'
  },
  {
    stem: 'SourceSans3-Regular',
    family: 'Source Sans 3',
    aliases: ['Source Sans Pro'],
    url: `https://raw.githubusercontent.com/storytold/wordcraft/${WORDCRAFT_COMMIT}/assets/fonts/SourceSans3-Regular.ttf`,
    sha256: '4644c81b86ec9caaa76b634889968ed3c4f4f52f054855933acc7c2b21e53b0f'
  },
  {
    stem: 'SourceSans3-It',
    family: 'Source Sans 3',
    url: `https://raw.githubusercontent.com/storytold/wordcraft/${WORDCRAFT_COMMIT}/assets/fonts/SourceSans3-It.ttf`,
    sha256: '192afd78f0f54a3c69eaf02d43f4d9a821e9d6110e41d3d25d61a7385cd580e4'
  },
  {
    stem: 'SourceSans3-Semibold',
    family: 'Source Sans 3',
    url: `https://raw.githubusercontent.com/storytold/wordcraft/${WORDCRAFT_COMMIT}/assets/fonts/SourceSans3-Semibold.ttf`,
    sha256: 'a3f4f8dcf343a8f24dc61951de93f3ba1558b15cd250ba24af8a40e957081b7d'
  },
  {
    stem: 'SourceSans3-Bold',
    family: 'Source Sans 3',
    url: `https://raw.githubusercontent.com/storytold/wordcraft/${WORDCRAFT_COMMIT}/assets/fonts/SourceSans3-Bold.ttf`,
    sha256: '9214b9d95e4231c609802815c2646c98174e2102d0d37f88978a7f8e71006e6a'
  },
  {
    stem: 'SourceSerif4-Regular',
    family: 'Source Serif 4',
    aliases: ['Source Serif Pro'],
    url: `https://raw.githubusercontent.com/storytold/wordcraft/${WORDCRAFT_COMMIT}/assets/fonts/SourceSerif4-Regular.ttf`,
    sha256: 'e5a4ee6a3d87bb9024796be390c6771e2a0eb1883dae25effaf57ca01668e24b'
  },
  {
    stem: 'SourceSerif4-It',
    family: 'Source Serif 4',
    url: `https://raw.githubusercontent.com/storytold/wordcraft/${WORDCRAFT_COMMIT}/assets/fonts/SourceSerif4-It.ttf`,
    sha256: '9d2950a8f1da66e21502c35d646a1d2148e79f9ea43fd2158cf02f5232e7f430'
  },
  {
    stem: 'SourceSerif4-Semibold',
    family: 'Source Serif 4',
    url: `https://raw.githubusercontent.com/storytold/wordcraft/${WORDCRAFT_COMMIT}/assets/fonts/SourceSerif4-Semibold.ttf`,
    sha256: '36db62940cb5728b12b1802476dc7fcf4c6c519a7bdd476ba23a4e555fc4655f'
  },
  {
    stem: 'SourceSerif4-Bold',
    family: 'Source Serif 4',
    url: `https://raw.githubusercontent.com/storytold/wordcraft/${WORDCRAFT_COMMIT}/assets/fonts/SourceSerif4-Bold.ttf`,
    sha256: '7cf4f4e1ad74f45058d5bc61716b82560442fbdcd9d3654d2dea96bf6c683d86'
  },
  {
    stem: 'SourceSerif4-BoldIt',
    family: 'Source Serif 4',
    url: `https://raw.githubusercontent.com/storytold/wordcraft/${WORDCRAFT_COMMIT}/assets/fonts/SourceSerif4-BoldIt.ttf`,
    sha256: '7b215b37f8873f5579f3f8d2ded3ca7c588e2f435cd996605ebfc5befe2cd5eb'
  },

  // Carlito (Calibri metric-compatible, SIL OFL 1.1)
  {
    stem: 'Carlito-Regular',
    family: 'Carlito',
    aliases: ['Calibri', 'Calibri Light'],
    url: `https://raw.githubusercontent.com/google/fonts/${GOOGLE_FONTS_COMMIT}/ofl/carlito/Carlito-Regular.ttf`,
    sha256: 'f6418f708baede9789daef5d458c0f53d2a888af9820e8062934e504fedc6595'
  },
  {
    stem: 'Carlito-Bold',
    family: 'Carlito',
    url: `https://raw.githubusercontent.com/google/fonts/${GOOGLE_FONTS_COMMIT}/ofl/carlito/Carlito-Bold.ttf`,
    sha256: 'bb5d20f79b82599ec72983597437373a80f2d2085fa91fc144fd74e876a594db'
  },
  {
    stem: 'Carlito-Italic',
    family: 'Carlito',
    url: `https://raw.githubusercontent.com/google/fonts/${GOOGLE_FONTS_COMMIT}/ofl/carlito/Carlito-Italic.ttf`,
    sha256: '0b019225e58d702bfedcbd35c21696769f8ee115cb6343f84c2f240312450d1c'
  },
  {
    stem: 'Carlito-BoldItalic',
    family: 'Carlito',
    url: `https://raw.githubusercontent.com/google/fonts/${GOOGLE_FONTS_COMMIT}/ofl/carlito/Carlito-BoldItalic.ttf`,
    sha256: 'b32928186c119599e03ca6a1ffc680fdcb7fac95772f4b95d989cf6cd3861517'
  },

  // Caladea (Cambria metric-compatible, SIL OFL 1.1)
  {
    stem: 'Caladea-Regular',
    family: 'Caladea',
    aliases: ['Cambria', 'Cambria Math'],
    url: `https://raw.githubusercontent.com/google/fonts/${GOOGLE_FONTS_COMMIT}/ofl/caladea/Caladea-Regular.ttf`,
    sha256: 'f1e899278b7b4491aba5b6a8253c4b04c050cc59b21865be5c37559a775153cd'
  },
  {
    stem: 'Caladea-Bold',
    family: 'Caladea',
    url: `https://raw.githubusercontent.com/google/fonts/${GOOGLE_FONTS_COMMIT}/ofl/caladea/Caladea-Bold.ttf`,
    sha256: 'ae3cb2dcbc925809dd29d2a44e9802211cab66be541bacbfc9c08c74b27c3742'
  },
  {
    stem: 'Caladea-Italic',
    family: 'Caladea',
    url: `https://raw.githubusercontent.com/google/fonts/${GOOGLE_FONTS_COMMIT}/ofl/caladea/Caladea-Italic.ttf`,
    sha256: '4359a8e24f748b6447b1ff6d7a174febe70961d29f8bb8634b56dacd740a3deb'
  },
  {
    stem: 'Caladea-BoldItalic',
    family: 'Caladea',
    url: `https://raw.githubusercontent.com/google/fonts/${GOOGLE_FONTS_COMMIT}/ofl/caladea/Caladea-BoldItalic.ttf`,
    sha256: 'ccabaa7b7e2fdf253d2b1a5fa699dd8a3df8d835a9eb285ad82631a677eb76c0'
  },

  // Noto Sans CJK & Noto Serif CJK variable fonts (SC, TC, JP, KR — SIL OFL 1.1)
  {
    stem: 'NotoSansSC-VF',
    family: 'Noto Sans SC',
    aliases: [
      'Noto Sans CJK SC',
      'Microsoft YaHei',
      'Microsoft YaHei UI',
      '微软雅黑',
      'DengXian',
      '等线',
      'SimHei',
      '黑体',
      'PingFang SC',
      '苹方-简',
      'Heiti SC'
    ],
    url: `https://raw.githubusercontent.com/google/fonts/${GOOGLE_FONTS_COMMIT}/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf`,
    sha256: 'a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da'
  },
  {
    stem: 'NotoSansTC-VF',
    family: 'Noto Sans TC',
    aliases: [
      'Noto Sans CJK TC',
      'Microsoft JhengHei',
      'Microsoft JhengHei UI',
      '微軟正黑體',
      'PingFang TC',
      '苹方-繁',
      'Heiti TC'
    ],
    url: `https://raw.githubusercontent.com/google/fonts/${GOOGLE_FONTS_COMMIT}/ofl/notosanstc/NotoSansTC%5Bwght%5D.ttf`,
    sha256: '864727d210d54f2537bbe23b3a839436c3992af72de9322af5270897246bd44f'
  },
  {
    stem: 'NotoSansJP-VF',
    family: 'Noto Sans JP',
    aliases: [
      'Noto Sans CJK JP',
      'Yu Gothic',
      'Yu Gothic UI',
      '游ゴシック',
      'Meiryo',
      'Meiryo UI',
      'メイリオ',
      'MS PGothic',
      'ＭＳ Ｐゴシック',
      'MS Gothic',
      'ＭＳ ゴシック',
      'Hiragino Kaku Gothic ProN',
      'ヒラギノ角ゴ ProN'
    ],
    url: `https://raw.githubusercontent.com/google/fonts/${GOOGLE_FONTS_COMMIT}/ofl/notosansjp/NotoSansJP%5Bwght%5D.ttf`,
    sha256: 'c2f3b4d463500a2ddcd3849cded1fceeb9fd6d1c32e6cbecd568453ba50fc68f'
  },
  {
    stem: 'NotoSansKR-VF',
    family: 'Noto Sans KR',
    aliases: [
      'Noto Sans CJK KR',
      'Malgun Gothic',
      '맑은 고딕',
      'Apple SD Gothic Neo',
      'Dotum',
      '돋움',
      'Gulim',
      '굴림'
    ],
    url: `https://raw.githubusercontent.com/google/fonts/${GOOGLE_FONTS_COMMIT}/ofl/notosanskr/NotoSansKR%5Bwght%5D.ttf`,
    sha256: '194018e6b2b293a7964f037b25c0249ce1418bc9ab3c971060a03aa57861e252'
  },
  {
    stem: 'NotoSerifSC-VF',
    family: 'Noto Serif SC',
    aliases: [
      'Noto Serif CJK SC',
      'SimSun',
      '宋体',
      'NSimSun',
      '新宋体',
      'Songti SC',
      'FangSong',
      '仿宋',
      'KaiTi',
      '楷体'
    ],
    url: `https://raw.githubusercontent.com/google/fonts/${GOOGLE_FONTS_COMMIT}/ofl/notoserifsc/NotoSerifSC%5Bwght%5D.ttf`,
    sha256: '050080d9255a86808f2945bffac582b31ef32bc36411ce29563b4961670c66f9'
  },
  {
    stem: 'NotoSerifTC-VF',
    family: 'Noto Serif TC',
    aliases: ['Noto Serif CJK TC', 'PMingLiU', '新細明體', 'MingLiU', '細明體', 'DFKai-SB', '標楷體'],
    url: `https://raw.githubusercontent.com/google/fonts/${GOOGLE_FONTS_COMMIT}/ofl/notoseriftc/NotoSerifTC%5Bwght%5D.ttf`,
    sha256: '0077e18f57c6908f4a000969880940bdb0dad057c0e8d98b49dc364c3d1b09c6'
  },
  {
    stem: 'NotoSerifJP-VF',
    family: 'Noto Serif JP',
    aliases: [
      'Noto Serif CJK JP',
      'MS Mincho',
      'ＭＳ 明朝',
      'MS PMincho',
      'ＭＳ Ｐ明朝',
      'Yu Mincho',
      '游明朝',
      'Hiragino Mincho ProN'
    ],
    url: `https://raw.githubusercontent.com/google/fonts/${GOOGLE_FONTS_COMMIT}/ofl/notoserifjp/NotoSerifJP%5Bwght%5D.ttf`,
    sha256: '2fd527ba12b6a44ec30d796d633360da0aeba6c5d4af1304ce12bb4dc15a7dfc'
  },
  {
    stem: 'NotoSerifKR-VF',
    family: 'Noto Serif KR',
    aliases: ['Noto Serif CJK KR', 'Batang', '바탕', 'Gungsuh', '궁서'],
    url: `https://raw.githubusercontent.com/google/fonts/${GOOGLE_FONTS_COMMIT}/ofl/notoserifkr/NotoSerifKR%5Bwght%5D.ttf`,
    sha256: '11f8d5de6f1b79195efba3828aaa2ec95c1178f5ae976fb23c8d53250a9938f3'
  }
]

const LIBERATION_FILES = [
  {
    stem: 'LiberationSans-Regular',
    member: 'LiberationSans-Regular.ttf',
    family: 'Liberation Sans',
    aliases: ['Arial', 'Helvetica', 'Helvetica Neue', 'Arial Nova'],
    sha256: '76d04c18ea243f426b7de1f3ad208e927008f961dc5945e5aad352d0dfde8ee8'
  },
  {
    stem: 'LiberationSans-Bold',
    member: 'LiberationSans-Bold.ttf',
    family: 'Liberation Sans',
    sha256: '788abee4c806d660e8aee46689dd8540cd4bb98da03dcc9d171ce3efd99a9173'
  },
  {
    stem: 'LiberationSans-Italic',
    member: 'LiberationSans-Italic.ttf',
    family: 'Liberation Sans',
    sha256: 'e5bae5c4cde31f22142753855f4f8fb86da6ff39955ed3c0a11248b0d16948b0'
  },
  {
    stem: 'LiberationSans-BoldItalic',
    member: 'LiberationSans-BoldItalic.ttf',
    family: 'Liberation Sans',
    sha256: '698da70fc191cc5f33ad4d6d3fe830fe4624b898ea2e3169955928b7c491f1ee'
  },
  {
    stem: 'LiberationSerif-Regular',
    member: 'LiberationSerif-Regular.ttf',
    family: 'Liberation Serif',
    aliases: ['Times New Roman', 'Times', 'Georgia'],
    sha256: '058ea80864aef09a23f45cbec2bb5400bc3dfbdea01c3f10538a21fcb497fb74'
  },
  {
    stem: 'LiberationSerif-Bold',
    member: 'LiberationSerif-Bold.ttf',
    family: 'Liberation Serif',
    sha256: 'd754ba427cfe0bca54ae052384baa8f842da5bd6550ad4da024ac441e7a7d5ce'
  },
  {
    stem: 'LiberationSerif-Italic',
    member: 'LiberationSerif-Italic.ttf',
    family: 'Liberation Serif',
    sha256: '0e3dea9f8d613e006ccfa62201f33e265d19167bd0907725c3e145368b04fc2e'
  },
  {
    stem: 'LiberationSerif-BoldItalic',
    member: 'LiberationSerif-BoldItalic.ttf',
    family: 'Liberation Serif',
    sha256: 'f17db8af71e24d2066b587546021d4f0b296be389512b658dec3c09affeb11a7'
  },
  {
    stem: 'LiberationMono-Regular',
    member: 'LiberationMono-Regular.ttf',
    family: 'Liberation Mono',
    aliases: ['Courier New', 'Courier', 'Menlo', 'Monaco'],
    sha256: 'f2b83c763e8afd21709333370bed4774337fae82267937e2b5aea7e2fbd922c1'
  },
  {
    stem: 'LiberationMono-Bold',
    member: 'LiberationMono-Bold.ttf',
    family: 'Liberation Mono',
    sha256: 'bd62a0672d0b9b6710b01df434c80ad54fa5f0835207eb7b17b7a761463067bb'
  },
  {
    stem: 'LiberationMono-Italic',
    member: 'LiberationMono-Italic.ttf',
    family: 'Liberation Mono',
    sha256: '605c01c711b44480a7508d349dfbf3264e81fa43d69e61cfa7d10b86e764c4d1'
  },
  {
    stem: 'LiberationMono-BoldItalic',
    member: 'LiberationMono-BoldItalic.ttf',
    family: 'Liberation Mono',
    sha256: '79451f3c09fe25116098853b7a2ca6e2436220ccc11af022979adbcf195be130'
  }
]

const LICENSE_TEXTS = [
  {
    title: 'Inter (SIL Open Font License 1.1)',
    url: `https://raw.githubusercontent.com/storytold/wordcraft/${WORDCRAFT_COMMIT}/assets/fonts/OFL-Inter.txt`,
    sha256: '262481e844521b326f5ecd053e59b98c8b2da78c8ee1bdbb6e8174305e54935a'
  },
  {
    title: 'JetBrains Mono (SIL Open Font License 1.1)',
    url: `https://raw.githubusercontent.com/storytold/wordcraft/${WORDCRAFT_COMMIT}/assets/fonts/OFL-JetBrainsMono.txt`,
    sha256: 'a76abf002c49097d146e86740a3105a5d00450b1592e820a1109a8c5680cd697'
  },
  {
    title: 'Source Sans 3 (SIL Open Font License 1.1)',
    url: `https://raw.githubusercontent.com/storytold/wordcraft/${WORDCRAFT_COMMIT}/assets/fonts/OFL-SourceSans3.txt`,
    sha256: '56af9b9c6715597e458284a474dc118a50a4150e9d547c70f7b4a33c3e6a9328'
  },
  {
    title: 'Source Serif 4 (SIL Open Font License 1.1)',
    url: `https://raw.githubusercontent.com/storytold/wordcraft/${WORDCRAFT_COMMIT}/assets/fonts/OFL-SourceSerif4.txt`,
    sha256: 'c21d7293d87b6d7ab1d0229a2f55b77f33a7613a6a4e66f6693d68d7d8d09464'
  },
  {
    title: 'Carlito (SIL Open Font License 1.1)',
    url: `https://raw.githubusercontent.com/google/fonts/${GOOGLE_FONTS_COMMIT}/ofl/carlito/OFL.txt`,
    sha256: '58402f82a7c332a700294988fe7554fbb0a63a8d27ccc1ee3bbc640311990a00'
  },
  {
    title: 'Caladea (SIL Open Font License 1.1)',
    url: `https://raw.githubusercontent.com/google/fonts/${GOOGLE_FONTS_COMMIT}/ofl/caladea/OFL.txt`,
    sha256: 'ccdab61d371d8c8683a128a92cd7d498dbdb1d37689f7cb21f1bf6b16658d213'
  },
  {
    title: 'Noto Sans CJK SC/TC/JP/KR (SIL Open Font License 1.1)',
    url: `https://raw.githubusercontent.com/google/fonts/${GOOGLE_FONTS_COMMIT}/ofl/notosanssc/OFL.txt`,
    sha256: '1c05c68c34f9708415aada51f17e1b0092d2cea709bf4a94cd38114f9e73d7d9'
  },
  {
    title: 'Noto Serif CJK SC/TC/JP/KR (SIL Open Font License 1.1)',
    url: `https://raw.githubusercontent.com/google/fonts/${GOOGLE_FONTS_COMMIT}/ofl/notoserifsc/OFL.txt`,
    sha256: '5e0da210fb04058a8c0087985d2d456b931c2579811a49655721d3cf0c36b6d6'
  }
]

function sha256Hex(bytes) {
  return createHash('sha256').update(bytes).digest('hex')
}

async function fetchVerified(url, expectedSha256) {
  if (!url.startsWith('https://')) {
    throw new Error(`Refusing non-HTTPS font URL: ${url}`)
  }
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
      return bytes
    } catch (err) {
      if (attempt === 5) throw err
      await new Promise(resolve => setTimeout(resolve, attempt * 1500))
    }
  }
  throw new Error(`Unreachable retry loop for ${url}`)
}

const manifestFonts = []

for (const item of DIRECT_FONTS) {
  const bytes = await fetchVerified(item.url, item.sha256)
  const file = `${item.stem}-${item.sha256.slice(0, 12)}.ttf`
  writeFileSync(path.join(destination, file), bytes)
  manifestFonts.push({
    family: item.family,
    ...(item.aliases ? { aliases: item.aliases } : {}),
    file
  })
}

const scratch = mkdtempSync(path.join(tmpdir(), 'ankole-office-fonts-'))
let liberationLicenseText = ''
try {
  const archiveBytes = await fetchVerified(LIBERATION_ARCHIVE.url, LIBERATION_ARCHIVE.sha256)
  const archivePath = path.join(scratch, 'liberation.tar.gz')
  writeFileSync(archivePath, archiveBytes)
  const extract = Bun.spawnSync(['tar', '-xzf', archivePath, '-C', scratch])
  if (extract.exitCode !== 0) {
    throw new Error(`Failed to extract Liberation archive: ${extract.stderr.toString()}`)
  }
  for (const item of LIBERATION_FILES) {
    const extracted = readFileSync(path.join(scratch, LIBERATION_ARCHIVE.prefix, item.member))
    const actual = sha256Hex(extracted)
    if (actual !== item.sha256) {
      throw new Error(`SHA-256 mismatch for ${item.member}: expected ${item.sha256}, got ${actual}`)
    }
    const file = `${item.stem}-${item.sha256.slice(0, 12)}.ttf`
    writeFileSync(path.join(destination, file), extracted)
    manifestFonts.push({
      family: item.family,
      ...(item.aliases ? { aliases: item.aliases } : {}),
      file
    })
  }
  const libLicenseBytes = readFileSync(path.join(scratch, LIBERATION_ARCHIVE.prefix, 'LICENSE'))
  const libLicenseSha = sha256Hex(libLicenseBytes)
  if (libLicenseSha !== '93fed46019c38bbe566b479d22148e2e8a1e85ada614accb0211c37b2c61c19b') {
    throw new Error(`SHA-256 mismatch for Liberation LICENSE: ${libLicenseSha}`)
  }
  liberationLicenseText = new TextDecoder().decode(libLicenseBytes)
} finally {
  rmSync(scratch, { recursive: true, force: true })
}

const noticeBlocks = [
  'Ankole Office Site Fonts — Third-Party License Notices',
  '======================================================',
  ''
]

for (const notice of LICENSE_TEXTS) {
  const bytes = await fetchVerified(notice.url, notice.sha256)
  noticeBlocks.push(`--- ${notice.title} ---`, new TextDecoder().decode(bytes).trim(), '')
}

noticeBlocks.push(
  '--- Liberation Sans, Liberation Serif, Liberation Mono 2.1.5 (SIL Open Font License 1.1) ---',
  liberationLicenseText.trim(),
  ''
)

writeFileSync(path.join(destination, 'manifest.json'), `${JSON.stringify({ fonts: manifestFonts }, null, 2)}\n`)
writeFileSync(path.join(destination, 'THIRD-PARTY-NOTICES.txt'), noticeBlocks.join('\n'))
process.stdout.write(`Installed ${manifestFonts.length} verified Office font files into ${destination}\n`)
