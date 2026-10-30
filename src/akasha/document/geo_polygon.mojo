"""Qdrant GeoPolygon validation and GeoRust polygon containment.

Qdrant 74f3e85b9473c62560006c043e13737ce6b48412 (Apache-2.0), geo 0.33.1
5ab50b072e34a915a33eaa46c80763d51d61295e and geo-types 0.7.19
981be9feea12cdede572fb252064536cb8b287b1 (MIT OR Apache-2.0).
Copyright (c) 2017 The GeoRust Project Developers; see THIRD_PARTY_NOTICES.md.
"""
from akasha.compute.robust_orientation import orient2d
from akasha.document.geo import GeoPoint
from akasha.document.value import PayloadValue
from std.math import abs


def _ring(value: PayloadValue) raises -> List[GeoPoint]:
    var points: PayloadValue
    if value.is_object():
        var member = value.get_key("points")
        if not member:
            raise Error("polygon ring requires points")
        points = member.value().clone()
    elif value.is_array():
        # Serde's struct sequence form: GeoLineString([points]).
        var members = value.children()
        if len(members) != 1:
            raise Error("polygon ring sequence requires one member")
        points = members[0].clone()
    else:
        raise Error("polygon ring requires an object or a struct sequence")
    if not points.is_array():
        raise Error("polygon ring points must be an array")
    var values = points.children()
    var ring = List[GeoPoint]()
    for i in range(len(values)):
        ring.append(GeoPoint.from_payload(values[i]))
    if len(ring) <= 3:
        raise Error("polygon ring requires at least four points")
    ref first = ring[0]
    ref last = ring[len(ring) - 1]
    var epsilon = Float64(2.220446049250313e-16)
    if abs(first.lat - last.lat) > epsilon or abs(first.lon - last.lon) > epsilon:
        raise Error("polygon ring first and last points must close")
    # Qdrant accepts EPSILON-close endpoints; Polygon::new then closes exactly.
    if first.lat != last.lat or first.lon != last.lon:
        ring.append(first.copy())
    return ring^


def _between(value: Float64, a: Float64, b: Float64) -> Bool:
    if a < b:
        return a <= value and value <= b
    return b <= value and value <= a


def _orientation(a: GeoPoint, b: GeoPoint, x: Float64, y: Float64) -> Int:
    var result = orient2d(a.lon, a.lat, b.lon, b.lat, x, y)
    # Preserve RobustKernel's mapping, including a nonfinite determinant from
    # extreme unchecked stored coordinates (neither sign means Collinear).
    if result < 0:
        return -1
    if result > 0:
        return 1
    return 0


def _ring_position(ring: List[GeoPoint], x: Float64, y: Float64) -> Int:
    # GeoRust CoordPos: 0 outside, 1 inside, 2 boundary.
    if len(ring) == 0:
        return 0
    if len(ring) == 1:
        return 2 if x == ring[0].lon and y == ring[0].lat else 0
    var winding = 0
    for i in range(len(ring) - 1):
        ref start = ring[i]
        ref end = ring[i + 1]
        if start.lat <= y:
            if end.lat >= y:
                var orientation = _orientation(start, end, x, y)
                if orientation == 1 and end.lat != y:
                    winding += 1
                elif orientation == 0 and _between(x, start.lon, end.lon):
                    return 2
        elif end.lat <= y:
            var orientation = _orientation(start, end, x, y)
            if orientation == -1:
                winding -= 1
            elif orientation == 0 and _between(x, start.lon, end.lon):
                return 2
    return 0 if winding == 0 else 1


struct GeoPolygon(Copyable, Movable):
    var _exterior: List[GeoPoint]
    var _interiors: List[List[GeoPoint]]

    def __init__(out self, value: PayloadValue) raises:
        var exterior: PayloadValue
        var interiors: Optional[PayloadValue]
        if value.is_object():
            var member = value.get_key("exterior")
            if not member:
                raise Error("polygon requires exterior")
            exterior = member.value().clone()
            interiors = value.get_key("interiors")
        elif value.is_array():
            var members = value.children()
            if len(members) != 2:
                raise Error("polygon sequence requires two members")
            exterior = members[0].clone()
            interiors = Optional(members[1].clone())
        else:
            raise Error("polygon requires an object or a struct sequence")
        self._exterior = _ring(exterior)
        self._interiors = List[List[GeoPoint]]()
        if interiors and not interiors.value().is_null():
            if not interiors.value().is_array():
                raise Error("polygon interiors must be an array")
            var holes = interiors.value().children()
            for i in range(len(holes)):
                self._interiors.append(_ring(holes[i]))

    def contains(self, x: Float64, y: Float64) -> Bool:
        # Polygon::coordinate_position, specialized to Contains<Coord> == Inside.
        if _ring_position(self._exterior, x, y) != 1:
            return False
        for i in range(len(self._interiors)):
            if _ring_position(self._interiors[i], x, y) != 0:
                return False
        return True
