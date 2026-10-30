"""robust 1.2.0 adaptive orient2d, translated without changing its algorithm.

Source: georust/robust 654f34cb8cdb3ae21bf59ef3472f92652942cd74 src/lib.rs.
Copyright 2017 The Spade Developers; 2020 The GeoRust Project Developers.
MIT OR Apache-2.0; see THIRD_PARTY_NOTICES.md. The source itself transcribes
Jonathan Richard Shewchuk's adaptive precision predicates. Lists replace bounded
Rust expansion arrays; each list contains only the source's active prefix.
"""
from std.math import abs


@no_inline
def _product(a: Float64, b: Float64) -> Float64:
    # Expansion arithmetic depends on separately rounded products, not FMA.
    return a * b


def _two_sum(a: Float64, b: Float64) -> Tuple[Float64, Float64]:
    var x = a + b
    var bvirt = x - a
    var avirt = x - bvirt
    var bround = b - bvirt
    var around = a - avirt
    return (x, around + bround)


def _fast_two_sum(a: Float64, b: Float64) -> Tuple[Float64, Float64]:
    var x = a + b
    var bvirt = x - a
    return (x, b - bvirt)


def _two_diff_tail(a: Float64, b: Float64, x: Float64) -> Float64:
    var bvirt = a - x
    var avirt = x + bvirt
    var bround = bvirt - b
    var around = a - avirt
    return around + bround


def _two_diff(a: Float64, b: Float64) -> Tuple[Float64, Float64]:
    var x = a - b
    return (x, _two_diff_tail(a, b, x))


def _split(a: Float64) -> Tuple[Float64, Float64]:
    var c = _product(134_217_729, a)
    var abig = c - a
    var ahi = c - abig
    return (ahi, a - ahi)


def _two_product(a: Float64, b: Float64) -> Tuple[Float64, Float64]:
    var x = _product(a, b)
    var ahi: Float64
    var alo: Float64
    ahi, alo = _split(a)
    var bhi: Float64
    var blo: Float64
    bhi, blo = _split(b)
    var err1 = x - _product(ahi, bhi)
    var err2 = err1 - _product(alo, bhi)
    var err3 = err2 - _product(ahi, blo)
    return (x, _product(alo, blo) - err3)


def _two_one_diff(a1: Float64, a0: Float64, b: Float64) -> Tuple[Float64, Float64, Float64]:
    var i: Float64
    var x0: Float64
    i, x0 = _two_diff(a0, b)
    var x2: Float64
    var x1: Float64
    x2, x1 = _two_sum(a1, i)
    return (x2, x1, x0)


def _two_two_diff(a1: Float64, a0: Float64, b1: Float64, b0: Float64) -> List[Float64]:
    var j: Float64
    var r0: Float64
    var x0: Float64
    j, r0, x0 = _two_one_diff(a1, a0, b0)
    var x3: Float64
    var x2: Float64
    var x1: Float64
    x3, x2, x1 = _two_one_diff(j, r0, b1)
    # Source callers arrange the returned components in this ascending order.
    return [x0, x1, x2, x3]


def _estimate(e: List[Float64]) -> Float64:
    var q = e[0]
    for i in range(1, len(e)):
        q += e[i]
    return q


def _fast_expansion_sum_zeroelim(e: List[Float64], f: List[Float64]) -> List[Float64]:
    var enow = e[0]
    var fnow = f[0]
    var eindex = 0
    var findex = 0
    var q: Float64
    if (fnow > enow) == (fnow > -enow):
        q = enow
        eindex += 1
    else:
        q = fnow
        findex += 1
    var h = List[Float64]()
    var hh: Float64
    if eindex < len(e) and findex < len(f):
        enow = e[eindex]
        fnow = f[findex]
        if (fnow > enow) == (fnow > -enow):
            q, hh = _fast_two_sum(enow, q)
            eindex += 1
        else:
            q, hh = _fast_two_sum(fnow, q)
            findex += 1
        if hh != 0:
            h.append(hh)
        while eindex < len(e) and findex < len(f):
            enow = e[eindex]
            fnow = f[findex]
            if (fnow > enow) == (fnow > -enow):
                q, hh = _two_sum(q, enow)
                eindex += 1
            else:
                q, hh = _two_sum(q, fnow)
                findex += 1
            if hh != 0:
                h.append(hh)
    while eindex < len(e):
        q, hh = _two_sum(q, e[eindex])
        eindex += 1
        if hh != 0:
            h.append(hh)
    while findex < len(f):
        q, hh = _two_sum(q, f[findex])
        findex += 1
        if hh != 0:
            h.append(hh)
    if q != 0 or len(h) == 0:
        h.append(q)
    return h^


def orient2d(ax: Float64, ay: Float64, bx: Float64, by: Float64, cx: Float64, cy: Float64) -> Float64:
    var detleft = _product(ax - cx, by - cy)
    var detright = _product(ay - cy, bx - cx)
    var det = detleft - detright
    var detsum = abs(detleft + detright)
    var errbound = _product(3.3306690621773722e-16, detsum)
    if det >= errbound or -det >= errbound:
        return det
    return _orient2dadapt(ax, ay, bx, by, cx, cy, detsum)


def _orient2dadapt(ax: Float64, ay: Float64, bx: Float64, by: Float64, cx: Float64, cy: Float64, detsum: Float64) -> Float64:
    var acx = ax - cx
    var bcx = bx - cx
    var acy = ay - cy
    var bcy = by - cy
    var detleft: Float64
    var detlefttail: Float64
    detleft, detlefttail = _two_product(acx, bcy)
    var detright: Float64
    var detrighttail: Float64
    detright, detrighttail = _two_product(acy, bcx)
    var b = _two_two_diff(detleft, detlefttail, detright, detrighttail)
    var det = _estimate(b)
    var epsilon = Float64(0.000_000_000_000_000_111_022_302_462_515_65)
    var ccw_b = (2 + 12 * epsilon) * epsilon
    var ccw_c = (9 + 64 * epsilon) * epsilon * epsilon
    var result_bound = (3 + 8 * epsilon) * epsilon
    var errbound = _product(ccw_b, detsum)
    if det >= errbound or -det >= errbound:
        return det
    var acxtail = _two_diff_tail(ax, cx, acx)
    var bcxtail = _two_diff_tail(bx, cx, bcx)
    var acytail = _two_diff_tail(ay, cy, acy)
    var bcytail = _two_diff_tail(by, cy, bcy)
    if acxtail == 0 and acytail == 0 and bcxtail == 0 and bcytail == 0:
        return det
    errbound = _product(ccw_c, detsum) + _product(result_bound, abs(det))
    det += (_product(acx, bcytail) + _product(bcy, acxtail)) - (_product(acy, bcxtail) + _product(bcx, acytail))
    if det >= errbound or -det >= errbound:
        return det
    var s1: Float64
    var s0: Float64
    var t1: Float64
    var t0: Float64
    s1, s0 = _two_product(acxtail, bcy)
    t1, t0 = _two_product(acytail, bcx)
    var u = _two_two_diff(s1, s0, t1, t0)
    var c1 = _fast_expansion_sum_zeroelim(b, u)
    s1, s0 = _two_product(acx, bcytail)
    t1, t0 = _two_product(acy, bcxtail)
    u = _two_two_diff(s1, s0, t1, t0)
    var c2 = _fast_expansion_sum_zeroelim(c1, u)
    s1, s0 = _two_product(acxtail, bcytail)
    t1, t0 = _two_product(acytail, bcxtail)
    u = _two_two_diff(s1, s0, t1, t0)
    var d = _fast_expansion_sum_zeroelim(c2, u)
    return d[len(d) - 1]
