import { expect, test } from 'bun:test'
import { spawnSync } from 'node:child_process'

const probe = String.raw`
import hashlib, io, json, math, os, posixpath, re, subprocess, sys, tempfile, zipfile
from pathlib import Path
from xml.etree import ElementTree as E
from openpyxl import Workbook

NS = {'x': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main', 'c': 'http://schemas.openxmlformats.org/drawingml/2006/chart'}
temporary = tempfile.TemporaryDirectory(prefix='ankole-office-data-')
root = Path(temporary.name)

def cli(*args, ok=True):
    result = subprocess.run(['officecli', *map(str, args)], text=True, capture_output=True, timeout=30)
    if ok:
        assert result.returncode == 0, (args, result.stdout, result.stderr)
    return result

def book(name, sheets):
    path = root / (name + '.xlsx')
    workbook = Workbook()
    workbook.remove(workbook.active)
    for title, rows in sheets:
        sheet = workbook.create_sheet(title)
        for row in rows:
            sheet.append(row)
    workbook.save(path)
    return path

def xml(path, name):
    with zipfile.ZipFile(path) as package:
        return E.fromstring(package.read(name))

def pivot_xml(path):
    with zipfile.ZipFile(path) as package:
        parts = [name for name in package.namelist() if name.startswith('xl/pivotTables/') and name.endswith('.xml')]
        assert len(parts) == 1, parts
        return E.fromstring(package.read(parts[0]))

def chart_xml(path):
    with zipfile.ZipFile(path) as package:
        parts = [name for name in package.namelist() if name.endswith('.xml') and E.fromstring(package.read(name)).tag == '{' + NS['c'] + '}chartSpace']
        assert len(parts) == 1, parts
        return E.fromstring(package.read(parts[0]))

def extended_data(path):
    cx = '{http://schemas.microsoft.com/office/drawing/2014/chartex}'
    rel = '{http://schemas.openxmlformats.org/officeDocument/2006/relationships}'
    with zipfile.ZipFile(path) as package:
        parts = [(name, E.fromstring(package.read(name))) for name in package.namelist() if name.endswith('.xml')]
        part, chart = next((name, node) for name, node in parts if node.tag == cx + 'chartSpace')
        external = chart.find(cx + 'chartData/' + cx + 'externalData')
        payload = path.read_bytes()
        if external is not None:
            relationships = E.fromstring(package.read(posixpath.join(posixpath.dirname(part), '_rels', posixpath.basename(part) + '.rels')))
            target = next(node.get('Target') for node in relationships if node.get('Id') == external.get(rel + 'id'))
            payload = package.read(posixpath.normpath(posixpath.join(posixpath.dirname(part), target)).lstrip('/'))
    with zipfile.ZipFile(io.BytesIO(payload)) as workbook_package:
        workbook = E.fromstring(workbook_package.read('xl/workbook.xml'))
        sheet_rid = workbook.find('x:sheets/x:sheet', NS).get(rel + 'id')
        relationships = E.fromstring(workbook_package.read('xl/_rels/workbook.xml.rels'))
        target = next(node.get('Target') for node in relationships if node.get('Id') == sheet_rid)
        sheet = E.fromstring(workbook_package.read(posixpath.normpath(posixpath.join('xl', target)).lstrip('/')))
        actual = {node.get('r'): ''.join(node.itertext()) for node in sheet.findall('.//x:c', NS)}
    return chart, actual

def cells(path, index=2):
    with zipfile.ZipFile(path) as package:
        strings = []
        if 'xl/sharedStrings.xml' in package.namelist():
            strings = [''.join(node.itertext()) for node in E.fromstring(package.read('xl/sharedStrings.xml')).findall('x:si', NS)]
        sheet = E.fromstring(package.read('xl/worksheets/sheet' + str(index) + '.xml'))
        result = {}
        for cell in sheet.findall('.//x:sheetData/x:row/x:c', NS):
            value = cell.find('x:v', NS)
            inline = cell.find('x:is', NS)
            text = value.text if value is not None else ''.join(inline.itertext()) if inline is not None else None
            if cell.get('t') == 's' and text is not None:
                text = strings[int(text)]
            result[cell.get('r')] = (text, cell.get('t'))
        return result

def pivot(path, **properties):
    args = ['add', path, '/Summary', '--type', 'pivottable']
    for name, value in {'source': 'Source!A1:B3', 'rows': 'Group', 'values': 'Value:sum', 'position': 'A1', **properties}.items():
        args.extend(['--prop', name + '=' + value])
    return cli(*args)

def numeric_cells(path):
    return [(value, kind) for value, kind in cells(path).values() if value is not None and kind not in ('s', 'inlineStr', 'str')]

case = sys.argv[1]
if case == 'quoted':
    for index, title in enumerate(["Source's Data", "Source''s!Data"]):
        path = book('quoted-' + str(index), [(title, [['Group', 'Value'], ['A', 10], ['B', 20]]), ('Summary', [])])
        reference = "'" + title.replace("'", "''") + "'!$A$1:$B$3"
        cli('add', path, '/Summary', '--type', 'chart', '--prop', 'chartType=column', '--prop', 'dataRange=' + reference)
        pivot(path, source=reference)
        assert cells(path)['B5' if 'B5' in cells(path) else 'B4'][0] == '30', cells(path)
        with zipfile.ZipFile(path) as package:
            chart = E.fromstring(package.read(next(name for name in package.namelist() if (name.startswith('xl/drawings/charts/') or name.startswith('xl/charts/')) and name.endswith('.xml'))))
            formulas = [node.text for node in chart.findall('.//c:f', NS)]
            assert formulas and all(title.replace("'", "''") in text for text in formulas), formulas
        cli('set', path, '/Summary/pivottable[1]', '--prop', 'source=' + reference)
        cli('validate', path)
        for mode in ('series', 'categories'):
            source = book('range-' + str(index) + mode, [(title, [['Group', 'Value'], ['A', 10], ['B', 20]]), ('Summary', [])])
            prefix = "'" + title.replace("'", "''") + "'!"
            args = ['add', source, '/Summary', '--type', 'chart', '--prop', 'chartType=column', '--prop', 'categories=' + prefix + '$A$2:$A$3']
            args += ['--prop', ('series1=' + prefix + '$B$2:$B$3') if mode == 'series' else ('dataRange=' + prefix + '$B$1:$B$3')]
            cli(*args)
            assert [node.text for node in chart_xml(source).findall('.//c:val//c:pt/c:v', NS)] == ['10', '20']
            cli('set', source, '/' + title + '/B3', '--prop', 'value=25')
            assert [node.text for node in chart_xml(source).findall('.//c:val//c:pt/c:v', NS)] == ['10', '25']
elif case == 'aliases':
    for aggregate, expected in [('stdev', math.sqrt(2)), ('stdevp', 1), ('stddev', math.sqrt(2)), ('stddevp', 1)]:
        path = book(aggregate, [('Source', [['Group', 'Value'], ['A', 2], ['A', 4]]), ('Summary', [])])
        pivot(path, values='Value:' + aggregate)
        assert math.isclose(float(cells(path)['B3'][0]), expected, rel_tol=1e-12), (aggregate, cells(path))
        assert pivot_xml(path).find('x:dataFields/x:dataField', NS).get('subtotal') in ('stdDev', 'stdDevp')
        path = book(aggregate + '-mode', [('Source', [['Group', 'Value'], ['A', 2], ['A', 4]]), ('Summary', [])])
        pivot(path, values='Value:' + aggregate + ':normal:Spread')
        assert math.isclose(float(cells(path)['B3'][0]), expected, rel_tol=1e-12), (aggregate, cells(path))
        assert pivot_xml(path).find('x:dataFields/x:dataField', NS).get('name') == 'Spread'
elif case in ('count', 'sample'):
    axes = [('Group', 'Column'), ('Group,Inner', 'Column'), ('Group', 'Column,Subcolumn'), ('Group,Inner', 'Column,Subcolumn'), ('Group,Inner,Leaf', 'Column')]
    for index, (rows, columns) in enumerate(axes):
        for aggregate, expected in ([('count', '2'), ('countNums', '1')] if case == 'count' else [('var', '#DIV/0!'), ('stddev', '#DIV/0!'), ('varp', '0')]):
            data = [['Group', 'Inner', 'Leaf', 'Column', 'Subcolumn', 'Value'], ['A', 'a', 'leaf', 'X', 'x', 5]]
            if case == 'count':
                data.extend([['A', 'a', 'leaf', 'X', 'x', 'skip'], ['A', 'a', 'leaf', 'X', 'x', None]])
            path = book(case + str(index) + aggregate, [('Source', data), ('Summary', [])])
            pivot(path, source='Source!A1:F' + str(len(data)), rows=rows, cols=columns, values='Value:' + aggregate)
            values = numeric_cells(path)
            assert values and all(value == expected for value, _ in values), (index, aggregate, values)
            if expected == '#DIV/0!':
                assert all(kind == 'e' for _, kind in values), values
            cli('set', path, '/Summary/pivottable[1]', '--prop', 'layout=tabular')
            assert numeric_cells(path) and all(value == expected for value, _ in numeric_cells(path)), numeric_cells(path)
            cli('validate', path)
    if case == 'count':
        path = book('count-top', [('Source', [['Group', 'Value'], ['A', 'one'], ['A', 'two'], ['A', 'three'], ['B', 5]]), ('Summary', [])])
        pivot(path, source='Source!A1:B5', values='Value:count', topN='1')
        assert cells(path)['A3'][0] == 'A' and cells(path)['B3'][0] == '3', cells(path)
elif case == 'reorder':
    path = book('reorder', [('Source', [['Group', 'Value'], ['A', 10], ['B', 20]]), ('Summary', []), ('New', [['Value', 'Group'], [100, 'A'], [200, 'B']]), ('Missing', [['Group', 'Other'], ['A', 1], ['B', 2]])])
    pivot(path)
    cli('set', path, '/Summary/pivottable[1]', '--prop', 'source=New!A1:B3')
    assert cells(path)['A3'][0] == 'A' and cells(path)['B3'][0] == '100', cells(path)
    assert cells(path)['A4'][0] == 'B' and cells(path)['B4'][0] == '200', cells(path)
    definition = pivot_xml(path)
    assert definition.find('x:rowFields/x:field', NS).get('x') == '1'
    assert definition.find('x:dataFields/x:dataField', NS).get('fld') == '0'
    before = hashlib.sha256(path.read_bytes()).hexdigest()
    rejected = cli('set', path, '/Summary/pivottable[1]', '--prop', 'source=Missing!A1:B3', ok=False)
    assert rejected.returncode != 0 and 'Restate' in rejected.stderr, rejected
    assert hashlib.sha256(path.read_bytes()).hexdigest() == before
    cli('validate', path)
elif case == 'running':
    for index, (rows, columns, expected) in enumerate([('Group', 'Period', {'A': [2, 4], 'B': [5, 9]}), ('Period', 'Group', {'X': [2, 5], 'Y': [4, 9]}), ('Group', '', {'A': [6], 'B': [14]})]):
        path = book('running' + str(index), [('Source', [['Group', 'Period', 'Value'], ['A', 'X', 2], ['A', 'Y', 4], ['B', 'X', 3], ['B', 'Y', 5]]), ('Summary', []), ('Moved', [['Value', 'Period', 'Group'], [2, 'X', 'A'], [4, 'Y', 'A'], [3, 'X', 'B'], [5, 'Y', 'B']])])
        pivot(path, source='Source!A1:C5', rows=rows, cols=columns, showDataAs='runningTotal')
        assert pivot_xml(path).find('x:dataFields/x:dataField', NS).get('baseField') == '0'
        for repeat in range(2):
            grid = cells(path)
            for label, values in expected.items():
                row = next(address[1:] for address, (value, _) in grid.items() if address.startswith('A') and value == label)
                assert [float(grid[column + row][0]) for column in ['B', 'C'][:len(values)]] == values, grid
            if repeat == 0:
                cli('set', path, '/Summary/pivottable[1]', '--prop', 'layout=tabular')
        cli('set', path, '/Summary/pivottable[1]', '--prop', 'source=Moved!A1:C5')
        assert pivot_xml(path).find('x:dataFields/x:dataField', NS).get('baseField') == '2'
        grid = cells(path)
        for label, values in expected.items():
            row = next(address[1:] for address, (value, _) in grid.items() if address.startswith('A') and value == label)
            assert [float(grid[column + row][0]) for column in ['B', 'C'][:len(values)]] == values, grid
        cli('validate', path)
elif case == 'filters':
    path = book('filters', [('Source', [['Group', 'Value'], ['Alpha', 10], ['Beta', 20], ['Gamma', 30]]), ('Summary', [])])
    pivot(path, source='Source!A1:B4', topN='2', labelFilter='Group:contains:a')
    filters = pivot_xml(path).findall('x:filters/x:filter', NS)
    assert len(filters) == 2 and len({node.get('id') for node in filters}) == 2, [node.attrib for node in filters]
    assert {node.get('type') for node in filters} == {'count', 'captionContains'}
    cli('validate', path)
elif case == 'hyperlinks':
    for legacy in (False, True):
        path = book('hyperlink-' + str(legacy), [('Source', [['Value'], [10]]), ('Summary', [['link']])])
        if legacy:
            from openpyxl import load_workbook
            workbook = load_workbook(path)
            workbook['Summary']['A1'].hyperlink = '#Source!$A$1'
            workbook.save(path)
        else:
            cli('set', path, '/Summary/A1', '--prop', 'link=#Source!$A$1')
            assert xml(path, 'xl/worksheets/sheet2.xml').find('x:hyperlinks/x:hyperlink', NS).get('location') == 'Source!$A$1'
        cli('set', path, '/Source', '--prop', 'name=Renamed')
        if legacy:
            with zipfile.ZipFile(path) as package:
                relationship = E.fromstring(package.read('xl/worksheets/_rels/sheet2.xml.rels'))[0]
                assert relationship.get('Target') == '#Renamed!$A$1', relationship.attrib
        else:
            assert xml(path, 'xl/worksheets/sheet2.xml').find('x:hyperlinks/x:hyperlink', NS).get('location') == 'Renamed!$A$1'
        before = hashlib.sha256(path.read_bytes()).hexdigest()
        rejected = cli('remove', path, '/Renamed', ok=False)
        assert rejected.returncode != 0 and 'hyperlink' in rejected.stderr, rejected
        assert hashlib.sha256(path.read_bytes()).hexdigest() == before
        cli('set', path, '/Summary/A1', '--prop', 'link=none')
        cli('remove', path, '/Renamed')
        cli('validate', path)
elif case == 'databar':
    path = book('databar', [('Source', [['Value'], [-5], [5]])])
    cli('add', path, '/Source/A2:A3', '--type', 'cf', '--prop', 'type=dataBar', '--prop', 'color=112233', '--prop', 'negativeColor=FF0000', '--prop', 'axisColor=000000')
    ns = {**NS, 'x14': 'http://schemas.microsoft.com/office/spreadsheetml/2009/9/main'}
    sheet = xml(path, 'xl/worksheets/sheet1.xml')
    assert sheet.find('.//x:dataBar/x:color', ns).get('rgb') == 'FF112233'
    extended = sheet.find('.//x14:dataBar', ns)
    assert extended is not None and extended.find('x14:fillColor', ns) is None
    assert extended.find('x14:negativeFillColor', ns).get('rgb') == 'FFFF0000'
    assert extended.find('x14:axisColor', ns).get('rgb') == 'FF000000'
    cli('validate', path)
elif case == 'stock':
    for count in (3, 4):
        path = book('stock' + str(count), [('Summary', [])])
        args = ['add', path, '/Summary', '--type', 'chart', '--prop', 'chartType=stock', '--prop', 'categories=D1,D2,D3']
        for index, data in enumerate(['High:12,15,13', 'Low:8,9,7', 'Close:11,10,12', 'Open:9,11,8'][:count], 1):
            args.extend(['--prop', 'series' + str(index) + '=' + data])
        cli(*args)
        chart = chart_xml(path)
        markers = [node.get('val') for node in chart.findall('.//c:stockChart/c:ser/c:marker/c:symbol', NS)]
        assert markers == (['none', 'none', 'dash'] if count == 3 else ['none'] * 4), markers
        assert (chart.find('.//c:upDownBars', NS) is not None) == (count == 4)
        cli('validate', path)
elif case == 'bubble':
    path = book('bubble', [('Summary', [])])
    cli('add', path, '/Summary', '--type', 'chart', '--prop', 'chartType=bubble', '--prop', 'categories=1,2,4', '--prop', 'series1=Y:2,0,5', '--prop', 'series1.bubbleSize=10,20,40')
    chart = chart_xml(path)
    assert chart.find('.//c:catAx', NS) is None
    axes = chart.findall('.//c:valAx', NS)
    assert len(axes) == 2
    ids = {node.find('c:axId', NS).get('val') for node in axes}
    assert len(ids) == 2 and {node.find('c:crossAx', NS).get('val') for node in axes} == ids
    assert [node.text for node in chart.findall('.//c:xVal//c:pt/c:v', NS)] == ['1', '2', '4']
    assert [node.text for node in chart.findall('.//c:bubbleSize//c:pt/c:v', NS)] == ['10', '20', '40']
    cli('set', path, '/Summary/chart[1]', '--prop', 'combotypes=scatter')
    chart = chart_xml(path)
    assert {node.get('val') for node in chart.findall('.//c:scatterChart/c:axId', NS)} == ids
    cli('validate', path)
elif case == 'quoted-remove':
    from openpyxl.chart import BarChart, Reference
    from openpyxl.formatting.rule import FormulaRule
    from openpyxl.worksheet.datavalidation import DataValidation
    for kind in ('validation', 'conditional', 'chart', 'sparkline'):
        path = root / (kind + '.xlsx')
        workbook = Workbook()
        source = workbook.active
        source.title = "Source's Data"
        source.append(['Group', 'Value'])
        source.append(['A', 1])
        source.append(['B', 2])
        summary = workbook.create_sheet('Summary')
        summary['A1'] = 'Keep'
        reference = "'Source''s Data'!$B$2:$B$3"
        if kind == 'validation':
            validation = DataValidation(type='list', formula1=reference)
            summary.add_data_validation(validation)
            validation.add('A2')
        elif kind == 'conditional':
            summary.conditional_formatting.add('A2', FormulaRule(formula=["'Source''s Data'!B2>0"], font=__import__('openpyxl').styles.Font(bold=True)))
        elif kind == 'chart':
            chart = BarChart()
            chart.add_data(Reference(source, min_col=2, min_row=1, max_row=3), titles_from_data=True)
            summary.add_chart(chart, 'D1')
        workbook.save(path)
        if kind == 'sparkline':
            cli('add', path, '/Summary', '--type', 'sparkline', '--prop', 'location=A2', '--prop', 'dataRange=' + reference)
        cli('validate', path)
        before = hashlib.sha256(path.read_bytes()).hexdigest()
        rejected = cli('remove', path, "/Source's Data", ok=False)
        assert rejected.returncode != 0 and 'Cannot remove sheet' in rejected.stderr, (kind, rejected)
        assert hashlib.sha256(path.read_bytes()).hexdigest() == before, kind
    path = book('unused-quoted', [("Source's Data", [['Value'], [1]]), ('Summary', [['Keep']])])
    cli('remove', path, "/Source's Data")
    assert [node.get('name') for node in xml(path, 'xl/workbook.xml').findall('x:sheets/x:sheet', NS)] == ['Summary']
elif case == 'label-help':
    description = json.loads(cli('help', 'excel', 'pivottable', '--json').stdout)['properties']['labelFilter']['description']
    operators = description.split('Type one of ', 1)[1].split('.', 1)[0].split(', ')
    assert set(operators) == {'equals', 'notEquals', 'beginsWith', 'endsWith', 'contains', 'doesNotContain'}, description
    for operator in operators:
        path = book('label-' + operator, [('Source', [['Group', 'Value'], ['Alpha', 10], ['Beta', 20]]), ('Summary', [])])
        pivot(path, labelFilter='Group:' + operator + ':Alpha')
        assert cells(path)['A3'][0] == ('Beta' if operator in ('notEquals', 'doesNotContain') else 'Alpha'), cells(path)
elif case == 'box':
    cx = '{http://schemas.microsoft.com/office/drawing/2014/chartex}'
    for extension in ('xlsx', 'docx', 'pptx'):
        path = root / ('box.' + extension)
        if extension == 'xlsx':
            path = book('box', [('Source', [['Label', 'A', 'B'], ['X', 10, 1], ['Y', 30, 9], ['Z', 20, 4]])])
            cli('add', path, '/Source', '--type', 'chart', '--prop', 'chartType=boxWhisker', '--prop', 'dataRange=Source!A1:C4')
        else:
            cli('create', path)
            parent = '/body'
            if extension == 'pptx':
                cli('add', path, '/', '--type', 'slide')
                parent = '/slide[1]'
            cli('add', path, parent, '--type', 'chart', '--prop', 'type=boxWhisker', '--prop', 'categories=X,Y,Z', '--prop', 'data=A:10,30,20;B:1,9,4')
        chart, actual = extended_data(path)
        data = chart.findall(cx + 'chartData/' + cx + 'data')
        assert len(data) == 2
        for index, (name, expected) in enumerate([('A', ['10', '30', '20']), ('B', ['1', '9', '4'])]):
            strings = data[index].find(cx + 'strDim')
            assert strings.find(cx + 'f') is None, E.tostring(strings).decode()
            assert [node.text for node in strings.findall('.//' + cx + 'pt')] == [name] * 3
            numeric = data[index].find(cx + 'numDim')
            column = 'B' if index == 0 else 'C'
            sheet = 'Source' if extension == 'xlsx' else 'Sheet1'
            assert numeric.find(cx + 'f').text == sheet + '!$' + column + '$2:$' + column + '$4'
            assert [node.text for node in numeric.findall('.//' + cx + 'pt')] == expected
            assert [actual[column + str(row)] for row in (2, 3, 4)] == expected
elif case == 'pareto':
    cx = '{http://schemas.microsoft.com/office/drawing/2014/chartex}'
    for extension in ('xlsx', 'docx', 'pptx'):
        path = root / ('pareto.' + extension)
        parent = '/body'
        if extension == 'xlsx':
            path = book('pareto', [('Summary', [])])
            parent = '/Summary'
        else:
            cli('create', path)
            if extension == 'pptx':
                cli('add', path, '/', '--type', 'slide')
                parent = '/slide[1]'
        cli('add', path, parent, '--type', 'chart', '--prop', 'type=pareto', '--prop', 'categories=X,Y,Z', '--prop', 'data=Revenue:10,30,20')
        chart, actual = extended_data(path)
        data = chart.find(cx + 'chartData/' + cx + 'data')
        strings = data.find(cx + 'strDim')
        numeric = data.find(cx + 'numDim')
        sheet = 'Summary' if extension == 'xlsx' else 'Sheet1'
        assert strings.find(cx + 'f').text == sheet + '!$A$2:$A$4'
        assert numeric.find(cx + 'f').text == sheet + '!$B$2:$B$4'
        assert [node.text for node in strings.findall('.//' + cx + 'pt')] == ['Y', 'Z', 'X']
        assert [node.text for node in numeric.findall('.//' + cx + 'pt')] == ['30', '20', '10']
        assert [actual['A' + str(row)] for row in (2, 3, 4)] == ['Y', 'Z', 'X'], actual
        assert [actual['B' + str(row)] for row in (2, 3, 4)] == ['30', '20', '10'], actual
elif case == 'waterfall':
    expected = [(0, -5), (-5, 5), (5, -7), (-7, -3), (0, -3)]
    def check_stacks(path):
        series = chart_xml(path).findall('.//c:barChart/c:ser', NS)
        values = [[float(node.text) for node in item.findall('c:val//c:pt/c:v', NS)] for item in series]
        assert series and all(len(points) == 5 for points in values), values
        for column, endpoints in enumerate(expected):
            positive = negative = 0
            intervals = []
            for index, points in enumerate(values):
                value = points[column]
                start = positive if value >= 0 else negative
                finish = start + value
                if value >= 0:
                    positive = finish
                else:
                    negative = finish
                if index > 0 and value:
                    intervals.append(sorted([start, finish]))
            intervals.sort()
            assert intervals, (column, values)
            for left, right in zip(intervals, intervals[1:]):
                assert left[1] == right[0], intervals
            assert [intervals[0][0], intervals[-1][1]] == sorted(endpoints), (column, intervals, endpoints)
    for extension in ('xlsx', 'docx', 'pptx'):
        path = root / ('waterfall.' + extension)
        parent = '/body'
        if extension == 'xlsx':
            path = book('waterfall', [('Summary', [])])
            parent = '/Summary'
        else:
            cli('create', path)
            if extension == 'pptx':
                cli('add', path, '/', '--type', 'slide')
                parent = '/slide[1]'
        cli('add', path, parent, '--type', 'chart', '--prop', 'type=waterfall', '--prop', 'categories=Start,Gain,Loss,Recovery,Total', '--prop', 'data=Delta:-5,10,-12,4,0', '--prop', 'increaseColor=00AA11', '--prop', 'decreaseColor=DD0011', '--prop', 'totalColor=0055AA', '--prop', 'legend=none')
        check_stacks(path)
        html = cli('view', path, 'html').stdout
        svg = E.fromstring(re.search(r'<svg\b.*?</svg>', html, re.S).group())
        bars = {}
        for node in svg.iter():
            if node.tag.split('}')[-1] == 'rect' and node.get('fill', '').lower() in ('#00aa11', '#dd0011', '#0055aa'):
                x = float(node.get('x'))
                bars.setdefault(x, []).append((float(node.get('y')), float(node.get('height'))))
        assert len(bars) == 5, bars
        bounds = [(min(y for y, _ in segments), max(y + height for y, height in segments)) for _, segments in sorted(bars.items())]
        zero = bounds[0][0]
        unit = (bounds[0][1] - zero) / 5
        for actual, endpoints in zip(bounds, expected):
            wanted = (zero - max(endpoints) * unit, zero - min(endpoints) * unit)
            assert all(abs(a - b) < 0.25 for a, b in zip(actual, wanted)), (extension, actual, wanted)
        if extension != 'xlsx':
            blueprint = root / (extension + '-waterfall.json')
            blueprint.write_text(cli('dump', path, '--format', 'batch').stdout)
            replay = root / ('replay.' + extension)
            cli('create', replay)
            cli('batch', replay, '--input', blueprint)
            check_stacks(replay)
else:
    raise AssertionError(case)
print(case + ': passed')
`

for (const [name, scenario] of [
  ['uses escaped sheet names in chart and pivot references', 'quoted'],
  ['calculates the documented sample and population deviation aliases', 'aliases'],
  ['counts text separately from numeric values in every pivot layout', 'count'],
  ['writes Excel error cells for insufficient sample statistics', 'sample'],
  ['preserves pivot field identities when source columns move', 'reorder'],
  ['calculates running totals along the stored base field', 'running'],
  ['writes unique IDs for combined pivot filters', 'filters'],
  ['preserves absolute internal hyperlinks during rename and removal', 'hyperlinks'],
  ['writes valid paired data-bar extensions', 'databar'],
  ['keeps the close value visible in three-series stock charts', 'stock'],
  ['uses two numeric axes for bubbles and preserves them on conversion', 'bubble'],
  ['rejects quoted-sheet dependency deletion before changing the package', 'quoted-remove'],
  ['documents only the six implemented label-filter operations', 'label-help'],
  ['keeps box-plot labels literal and observations linked in all hosts', 'box'],
  ['writes sorted inline Pareto data with matching caches in all hosts', 'pareto'],
  ['preserves cross-zero waterfall intervals in native charts and SVG', 'waterfall']
] as const) {
  test(`OfficeCLI data: ${name}`, () => {
    const result = spawnSync('python', ['-c', probe, scenario], {
      env: { ...process.env, OFFICECLI_SKIP_UPDATE: '1', OFFICECLI_NO_AUTO_RESIDENT: '1' },
      encoding: 'utf8',
      timeout: 90_000,
      maxBuffer: 1024 * 1024
    })
    expect(result.status, `${result.stderr}\n${result.stdout}`).toBe(0)
  }, 95_000)
}
