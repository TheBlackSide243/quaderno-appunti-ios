"""Writes UnitTests/Fixtures/sample.goodnotes: a small notebook laid out like GoodNotes files are
(zip, protobuf records, Apple LZ4 + "tpl" stroke paths), made from scratch for the import tests.

Pages:
1. grid paper (a PDF attachment), canvas 834.24 x 1078.83: a black even stroke, a yellow
   highlighter stroke, a pressure stroke, a rectangle shape, a picture, a text box, and a
   deleted stroke that must not come back;
2. no paper: one blue even stroke;
3. a page deleted in the event log: must not be imported.

Usage: python scripts/make_goodnotes_fixture.py
"""
import io, os, struct, zipfile, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'UnitTests', 'Fixtures', 'sample.goodnotes')

PAPER = 'C1A2B3C4-0000-4000-8000-000000000001'
IMAGE = 'C1A2B3C4-0000-4000-8000-000000000002'
LAYER1 = 'C1A2B3C4-0000-4000-8000-0000000000A1'
LAYER2 = 'C1A2B3C4-0000-4000-8000-0000000000A2'
# the event log names a page with an id whose last digit differs from its notes/ file, as GoodNotes does
PAGE1 = 'B1000000-0000-4000-8000-00000000000A'
PAGE2 = 'B2000000-0000-4000-8000-00000000000A'
PAGE3 = 'B3000000-0000-4000-8000-00000000000A'


def member(page):
    return 'notes/' + page[:-1] + 'B'


# ---- protobuf writer ---------------------------------------------------------------------
def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7f
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def field(f, v):
    if isinstance(v, bool) or isinstance(v, int):
        return varint(f << 3) + varint(int(v))
    if isinstance(v, float):
        return varint(f << 3 | 5) + struct.pack('<f', v)
    if isinstance(v, str):
        v = v.encode()
    return varint(f << 3 | 2) + varint(len(v)) + v


def message(*pairs):
    return b''.join(field(f, v) for f, v in pairs)


def records(*recs):
    return b''.join(varint(len(r)) + r for r in recs)


def point(x, y):
    return message((1, float(x)), (2, float(y)))


def rgba(r, g, b, a):
    return message((1, float(r)), (2, float(g)), (3, float(b)), (4, float(a)))


# ---- stroke paths ------------------------------------------------------------------------
def tpl(sig, values):
    body = b''.join(values)
    head = sig.encode() + b'\0'
    return b'tpl\0' + struct.pack('<I', 8 + len(head) + len(body)) + head + body


def u16(n):
    return struct.pack('<H', n)


def f32(*xs):
    return b''.join(struct.pack('<f', x) for x in xs)


def arr(items, pack):
    return struct.pack('<I', len(items)) + b''.join(pack(i) for i in items)


def lz4_literals(raw):
    """An LZ4 block holding only literals (valid, just not smaller)."""
    n = len(raw)
    if n < 15:
        return bytes([n << 4]) + raw
    rest = n - 15
    ext = b'\xff' * (rest // 255) + bytes([rest % 255])
    return bytes([0xf0]) + ext + raw


def apple_lz4(raw):
    block = lz4_literals(raw)
    return b'bv41' + struct.pack('<II', len(raw), len(block)) + block + b'bv4$'


def uniform(width, start, segments):
    """An even pen: one move, then quadratic segments (cx, cy, ex, ey)."""
    flags = [0] + [1] * len(segments)
    return tpl('vuA(v)A(S(uu))A(S(uuuu))', [
        u16(1), f32(width), arr(flags, u16), arr([start], lambda p: f32(*p)), arr(segments, lambda s: f32(*s))])


def pressure(start, segments):
    """Newer pressure pen: every node has its own half-width (flag 2)."""
    flags = [2] + [3] * len(segments)
    starts = [start]  # (x, y, r)
    segs = segments  # (cx, cy, ex, ey, cr, er)
    empty = struct.pack('<I', 0)
    return tpl('vuA(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)', [
        u16(1), f32(-1.0), arr(flags, u16),
        arr([v for s in starts for v in s], f32), arr([v for s in segs for v in s], f32),
        empty, empty, empty, empty, empty, empty, empty])


# ---- page objects ------------------------------------------------------------------------
counter = [0]


def obj(kind, oid, body_fields, deleted=False, header_extra=()):
    counter[0] += 1
    header = [(1, oid), (2, message((1, 1), (2, 1000 + counter[0])))]
    if deleted:
        header.append((3, 1))
    header += [(8, 95355821213104572), (9, counter[0]), (16, 24)] + list(header_extra)
    body = message((1, oid), *body_fields)
    return [message(*header), message((kind, body))]


def stroke(oid, path, color, deleted=False, shape=None):
    fields = [(2, apple_lz4(path)), (3, 1), (4, color), (6, b'')]
    if shape is not None:
        fields.append((9, shape))
    return obj(7, oid, fields, deleted)


def uid(n):
    return 'D0D0D0D0-0000-4000-8000-%012d' % n


page1 = []
page1 += stroke(uid(1), uniform(1.6993, (100, 100), [(150, 100, 200, 100), (250, 100, 300, 100)]), rgba(0, 0, 0, 1))
page1 += stroke(uid(2), uniform(26.18, (100, 200), [(200, 200, 300, 200)]), rgba(1, 1, 0, 0.5))
page1 += stroke(uid(3), pressure((100, 300, 2.0), [(150, 320, 200, 300, 2.5, 3.0)]), rgba(0, 0, 0, 1))
page1 += stroke(uid(4), uniform(1.6993, (100, 400), [(150, 450, 200, 400)]), rgba(1, 0, 0, 1), deleted=True)
rect = message((3, message((1, point(500, 500)), (2, point(100, 60)))), (15, 4.0))
page1 += stroke(uid(5), tpl('vuA(v)A(S(uu))A(S(uuuu))', [u16(1), f32(4.0), arr([], u16), arr([], f32), arr([], f32)]),
                rgba(0, 0.48, 1, 1), shape=rect)
placement = message((1, point(400, 600)), (2, point(200, 150)))
page1 += obj(1, uid(6), [(2, placement)], header_extra=[(4, IMAGE)])
rtf = (b'{\\rtf1\\ansi\\ansicpg1252\\cocoartf2759\n{\\fonttbl\\f0\\fswiss\\fcharset0 Helvetica;}\n'
       b'\\f0\\fs40 \\cf0 Ciao GoodNotes}')
page1 += obj(8, uid(7), [(2, message((1, point(100, 800)), (2, point(400, 80)))), (3, rtf)])

page2 = stroke(uid(8), uniform(3.4, (200, 200), [(250, 260, 300, 200)]), rgba(0, 0.3, 1, 1))


def pdf_paper():
    """One page 455.04 x 588.451 with a light grid, hand-written PDF."""
    lines = []
    for i in range(1, 30):
        y = i * 20
        lines.append('0 %d m 455 %d l' % (y, y))
    content = ('0.85 G 0.5 w ' + ' '.join(lines) + ' S').encode()
    objs = [
        b'<< /Type /Catalog /Pages 2 0 R >>',
        b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 455.04 588.451] /Contents 4 0 R /Resources << >> >>',
        b'<< /Length %d >>\nstream\n' % len(content) + content + b'\nendstream',
    ]
    out = bytearray(b'%PDF-1.5\n')
    offsets = []
    for n, o in enumerate(objs, 1):
        offsets.append(len(out))
        out += b'%d 0 obj\n' % n + o + b'\nendobj\n'
    xref = len(out)
    out += b'xref\n0 %d\n0000000000 65535 f \n' % (len(objs) + 1)
    for off in offsets:
        out += b'%010d 00000 n \n' % off
    out += b'trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' % (len(objs) + 1, xref)
    return bytes(out)


def png(w, h, rgb):
    raw = b''.join(b'\0' + bytes(rgb) * w for _ in range(h))
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def reg(value, version=1):
    return message((1, value), (2, message((1, version))))


canvas = message((1, 834.24), (2, 1078.8268))
events = records(
    message((1, LAYER1), (2, message((4, PAPER), (5, 1), (8, canvas)))),
    message((1, LAYER2), (2, message((8, canvas)))),
    # created out of order: the position keys put PAGE1 first
    message((1, PAGE2), (54, message((2, PAGE2), (3, reg(LAYER2)), (4, reg('Bm'))))),
    message((1, PAGE1), (54, message((2, PAGE1), (3, reg(LAYER1)), (4, reg('Am'))))),
    message((1, PAGE3), (54, message((2, PAGE3), (3, reg(LAYER2)), (4, reg('Cm'))))),
    message((1, PAGE3), (56, message((1, 1)))),
)
notes_index = records(*[message((1, member(p)[6:]), (2, member(p))) for p in (PAGE1, PAGE2, PAGE3)])

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with zipfile.ZipFile(OUT, 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('schema.pb', message((1, 26)))
    z.writestr('index.notes.pb', notes_index)
    z.writestr('index.events.pb', events)
    z.writestr(member(PAGE1), records(*page1))
    z.writestr(member(PAGE2), records(*page2))
    z.writestr(member(PAGE3), records(*stroke(uid(9), uniform(2, (10, 10), [(20, 20, 30, 10)]), rgba(0, 0, 0, 1))))
    z.writestr('attachments/' + PAPER, pdf_paper())
    z.writestr('attachments/' + IMAGE, png(40, 30, (220, 60, 60)))
print('wrote', OUT, os.path.getsize(OUT), 'bytes')
