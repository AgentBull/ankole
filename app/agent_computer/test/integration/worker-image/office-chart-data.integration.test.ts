import { expect, test } from 'bun:test'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync } from 'node:fs'
import { join } from 'node:path'

function office(...args: string[]): void {
  const result = spawnSync('officecli', args, {
    env: { ...process.env, OFFICECLI_SKIP_UPDATE: '1' },
    encoding: 'utf8',
    timeout: 20_000
  })
  expect(result.status, `${result.stderr}\n${result.stdout}`).toBe(0)
}

// Resolve the workbook through the chart's package relationship. A chart
// part may be below ppt/slides/charts rather than ppt/charts.
function chartData(path: string): Record<string, string[]>[] {
  office('save', path)
  const result = spawnSync(
    'python3',
    [
      '-c',
      String.raw`
import io, json, posixpath, re, sys, zipfile
import xml.etree.ElementTree as ET
C = '{http://schemas.openxmlformats.org/drawingml/2006/chart}'
R = '{http://schemas.openxmlformats.org/officeDocument/2006/relationships}'
S = '{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'
def target(z, part, rid):
    rels = ET.fromstring(z.read(posixpath.join(posixpath.dirname(part), '_rels', posixpath.basename(part) + '.rels')))
    rel = next(r for r in rels if r.get('Id') == rid)
    assert rel.get('TargetMode') != 'External'
    return posixpath.normpath(posixpath.join(posixpath.dirname(part), rel.get('Target'))).lstrip('/')
with zipfile.ZipFile(sys.argv[1]) as ppt:
    charts = [(n, ET.fromstring(ppt.read(n))) for n in ppt.namelist() if n.endswith('.xml') and '/charts/' in n]
    charts = [(n, e) for n, e in charts if e.tag == C + 'chartSpace']
    assert len(charts) == 1, charts
    part, chart = charts[0]
    external = chart.findall(C + 'externalData')
    assert len(external) == 1, 'chart needs one embedded workbook'
    assert external[0].find(C + 'autoUpdate').get('val') in ('0', 'false')
    workbook = ppt.read(target(ppt, part, external[0].get(R + 'id')))
with zipfile.ZipFile(io.BytesIO(workbook)) as xlsx:
    wb = ET.fromstring(xlsx.read('xl/workbook.xml'))
    sheet = wb.find(S + 'sheets/' + S + 'sheet')
    assert sheet.get('name') == 'Sheet1'
    ws = ET.fromstring(xlsx.read(target(xlsx, 'xl/workbook.xml', sheet.get(R + 'id'))))
    cells = {}
    for cell in ws.iter(S + 'c'):
        cells[cell.get('r')] = (cell.get('t'), ''.join(cell.itertext()))
    assert cells['Z99'] == ('inlineStr', 'User data'), cells.get('Z99')
    output, columns = [], set()
    for series in chart.findall('.//' + C + 'ser'):
        values = {}
        for slot in series:
            kind = slot.tag.removeprefix(C)
            if kind not in ('tx', 'cat', 'val', 'xVal', 'yVal', 'bubbleSize'):
                continue
            numeric = kind in ('val', 'xVal', 'yVal', 'bubbleSize')
            ref = slot.find(C + ('numRef' if numeric else 'strRef'))
            assert ref is not None and len(slot) == 1, kind
            formula = ref.find(C + 'f').text
            match = re.fullmatch(r'Sheet1!\$([A-Z]+)\$1(?::\$\1\$(\d+))?', formula)
            assert match is not None, formula
            col, end = match.groups()
            assert col not in columns, formula
            columns.add(col)
            cache = ref.find(C + ('numCache' if numeric else 'strCache'))
            points = cache.findall(C + 'pt')
            count = int(cache.find(C + 'ptCount').get('val'))
            assert count == int(end or '1') == len(points), formula
            actual = []
            for i, point in enumerate(points):
                assert int(point.get('idx')) == i
                value = point.find(C + 'v').text or ''
                data_type, cell_value = cells[f'{col}{i + 1}']
                assert cell_value == value, (formula, cell_value, value)
                assert data_type in (None, 'n') if numeric else data_type == 'inlineStr'
                actual.append(value)
            values[kind] = actual
        output.append(values)
    assert 'Z' not in columns, columns
open(sys.argv[1] + '.xlsx', 'wb').write(workbook)
print(json.dumps(output))
`,
      path
    ],
    { encoding: 'utf8', timeout: 10_000 }
  )
  expect(result.status, result.stderr).toBe(0)
  office('validate', path)
  office('validate', `${path}.xlsx`)
  return JSON.parse(result.stdout)
}

function createChart(path: string, type: string, ...props: string[]): void {
  office('create', path)
  office('add', path, '/', '--type', 'slide')
  office('add', path, '/slide[1]', '--type', 'chart', '--prop', `type=${type}`, ...props.flatMap(p => ['--prop', p]))
  office('save', path)
  office('close', path)
  const fixture = spawnSync(
    'python3',
    [
      '-c',
      String.raw`
import io, posixpath, sys, zipfile
import xml.etree.ElementTree as ET
from openpyxl import load_workbook
C = '{http://schemas.openxmlformats.org/drawingml/2006/chart}'
R = '{http://schemas.openxmlformats.org/officeDocument/2006/relationships}'
with zipfile.ZipFile(sys.argv[1]) as ppt:
    parts = [(info, ppt.read(info)) for info in ppt.infolist()]
    part, chart = next((info.filename, ET.fromstring(data)) for info, data in parts
        if info.filename.endswith('.xml') and ET.fromstring(data).tag == C + 'chartSpace')
    rels = ET.fromstring(ppt.read(posixpath.join(posixpath.dirname(part), '_rels', posixpath.basename(part) + '.rels')))
    rid = chart.find(C + 'externalData').get(R + 'id')
    target = next(rel.get('Target') for rel in rels if rel.get('Id') == rid)
    embedded = posixpath.normpath(posixpath.join(posixpath.dirname(part), target)).lstrip('/')
    workbook = load_workbook(io.BytesIO(ppt.read(embedded)))
    workbook['Sheet1']['Z99'] = 'User data'
    output = io.BytesIO()
    workbook.save(output)
with zipfile.ZipFile(sys.argv[1], 'w') as ppt:
    for info, data in parts:
        ppt.writestr(info, output.getvalue() if info.filename == embedded else data)
`,
      path
    ],
    { encoding: 'utf8', timeout: 10_000 }
  )
  expect(fixture.status, fixture.stderr).toBe(0)
}

test('standard column chart data stays editable across data lengths and series counts', () => {
  const root = mkdtempSync('/tmp/ankole-office-chart-')
  const path = join(root, 'column.pptx')
  try {
    createChart(path, 'column', 'categories=北 & East,South,West', 'data=Revenue:1.25,-2,3;Cost:4,5,6')
    expect(chartData(path)).toEqual([
      { tx: ['Revenue'], cat: ['北 & East', 'South', 'West'], val: ['1.25', '-2', '3'] },
      { tx: ['Cost'], cat: ['北 & East', 'South', 'West'], val: ['4', '5', '6'] }
    ])
    office('set', path, '/slide[1]/chart[1]', '--prop', 'categories=East,West', '--prop', 'data=Profit:5,6;Fees:1,2')
    expect(chartData(path)).toEqual([
      { tx: ['Profit'], cat: ['East', 'West'], val: ['5', '6'] },
      { tx: ['Fees'], cat: ['East', 'West'], val: ['1', '2'] }
    ])
    office(
      'set',
      path,
      '/slide[1]/chart[1]',
      '--prop',
      'categories=A,B,C,D',
      '--prop',
      'data=Growth:7,8,9,10;Tax:2,3,4,5'
    )
    office('set', path, '/slide[1]/chart[1]/series[1]', '--prop', 'name=Net growth')
    expect(chartData(path)).toEqual([
      { tx: ['Net growth'], cat: ['A', 'B', 'C', 'D'], val: ['7', '8', '9', '10'] },
      { tx: ['Tax'], cat: ['A', 'B', 'C', 'D'], val: ['2', '3', '4', '5'] }
    ])
    office('set', path, '/slide[1]/chart[1]', '--prop', 'categories=North,South', '--prop', 'data=Solo:11,12')
    expect(chartData(path)).toEqual([{ tx: ['Solo'], cat: ['North', 'South'], val: ['11', '12'] }])
    office('set', path, '/slide[1]/chart[1]', '--prop', 'data=Alpha:21,22;Beta:31,32;Gamma:41,42')
    expect(chartData(path)).toEqual([
      { tx: ['Alpha'], cat: ['North', 'South'], val: ['21', '22'] },
      { tx: ['Beta'], cat: ['North', 'South'], val: ['31', '32'] },
      { tx: ['Gamma'], cat: ['North', 'South'], val: ['41', '42'] }
    ])
  } finally {
    office('close', path)
    rmSync(root, { recursive: true, force: true })
  }
}, 60_000)

for (const type of ['scatter', 'bubble']) {
  test(`standard ${type} chart embeds its real numeric dimensions and preserves them on set`, () => {
    const root = mkdtempSync('/tmp/ankole-office-chart-')
    const path = join(root, `${type}.pptx`)
    const size: Record<string, string[]> = type === 'bubble' ? { bubbleSize: ['3', '8', '2'] } : {}
    try {
      createChart(
        path,
        type,
        'categories=1.5,4.25,9',
        'data=Measured:5.5,6.75,-2',
        ...(type === 'bubble' ? ['series1.bubbleSize=3,8,2'] : [])
      )
      expect(chartData(path)).toEqual([
        { tx: ['Measured'], xVal: ['1.5', '4.25', '9'], yVal: ['5.5', '6.75', '-2'], ...size }
      ])
      office('set', path, '/slide[1]/chart[1]', '--prop', 'series1=Updated:9.5,8.25,7')
      expect(chartData(path)).toEqual([
        { tx: ['Updated'], xVal: ['1.5', '4.25', '9'], yVal: ['9.5', '8.25', '7'], ...size }
      ])
      office('set', path, '/slide[1]/chart[1]', '--prop', 'data=First:10,20,30;Second:40,50,60')
      expect(chartData(path)).toEqual([
        { tx: ['First'], xVal: ['1.5', '4.25', '9'], yVal: ['10', '20', '30'], ...size },
        { tx: ['Second'], xVal: ['1.5', '4.25', '9'], yVal: ['40', '50', '60'], ...size }
      ])
    } finally {
      office('close', path)
      rmSync(root, { recursive: true, force: true })
    }
  }, 60_000)
}
