from latex_structure_teacher import record,ParseError
for s in ('x^2+y','x_2','\\frac{x}{2}','\\sqrt{x}','A\\rightarrow B/C\\_D'):
 assert record('id',s)['latex']==s
try: record('id','$x$')
except ParseError: pass
else: raise AssertionError('unsupported syntax accepted')
try: record('id','\\begin{matrix}x\\end{matrix}')
except ParseError: raise AssertionError('matrix structure was rejected')
matrix=record('id','\\begin{matrix}a&b\\\\c&d\\end{matrix}')
assert matrix['latex']=='\\begin{matrix}a&b\\\\c&d\\end{matrix}'
assert {edge[2] for edge in matrix['relations']} == {'matrix-row','matrix-cell','baseline'}
delimited=record('id','(x+[y])')
assert sum(edge[2]=='delimiter' for edge in delimited['relations']) == 4
assert record('id','[0,u)')['latex']=='[0,u)'
assert record('id','\\frac{}{x}')['latex']=='\\frac{}{x}'
structured=record('id','x_2+\\frac{a}{\\sqrt[3]{b}}')
assert {edge[2] for edge in structured['relations']} == {'baseline','subscript','numerator','denominator','radicand','radical-index'}
assert [node['nodeId'] for node in structured['nodes']] == list(range(len(structured['nodes'])))
print('LATEX_STRUCTURE_TEACHER_OK')
