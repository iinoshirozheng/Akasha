"""Source-backed geographic points and spherical distance in meters.

GeoPoint parsing/validation: Qdrant types.rs at
74f3e85b9473c62560006c043e13737ce6b48412 (Apache-2.0).
Distance: geo 0.33.1 HaversineMeasure::distance, commit
5ab50b072e34a915a33eaa46c80763d51d61295e (MIT OR Apache-2.0).
Copyright (c) 2017 The GeoRust Project Developers; see THIRD_PARTY_NOTICES.md.
"""
from akasha.document.value import PayloadValue
from std.math import asin, cos, sin, sqrt


struct GeoPoint(Copyable, Movable):
    var lon: Float64
    var lat: Float64

    def __init__(out self, lon: Float64, lat: Float64) raises:
        self.lon = lon
        self.lat = lat
        self.validate()

    def validate(self) raises:
        # Source inclusive ranges also reject NaN and infinities.
        if not (self.lon >= -180 and self.lon <= 180 and self.lat >= -90 and self.lat <= 90):
            raise Error("geo point requires longitude in [-180, 180] and latitude in [-90, 90]")

    @staticmethod
    def from_payload(value: PayloadValue) raises -> GeoPoint:
        if value.is_object():
            var lon = value.get_key("lon")
            var lat = value.get_key("lat")
            if not lon or not lat:
                raise Error("geo point requires lon and lat")
            return GeoPoint(_coordinate(lon.value()), _coordinate(lat.value()))
        if value.is_array():
            var children = value.children()
            if len(children) == 2:
                return GeoPoint(_coordinate(children[0]), _coordinate(children[1]))
        raise Error("geo point must be an object or a two-coordinate array")


def _coordinate(value: PayloadValue) raises -> Float64:
    if value.is_floating():
        return value.as_float()
    if value.is_integer():
        return Float64(value.as_int())
    if value.is_unsigned():
        return Float64(value.as_uint())
    raise Error("geo point coordinates must be JSON numbers")


@no_inline
def _product(left: Float64, right: Float64) -> Float64:
    # Retain separate Rust scalar products before addition (no implicit FMA).
    return left * right


def haversine_distance(origin: GeoPoint, destination: GeoPoint) -> Float64:
    # geo::HaversineMeasure::GRS80_MEAN_RADIUS and f64::to_radians.
    var radians = Float64(3.141592653589793) / Float64(180)
    var theta1 = origin.lat * radians
    var theta2 = destination.lat * radians
    var delta_theta = (destination.lat - origin.lat) * radians
    var delta_lambda = (destination.lon - origin.lon) * radians
    var lat_sine = sin(delta_theta / Float64(2))
    var lon_sine = sin(delta_lambda / Float64(2))
    var a = _product(lat_sine, lat_sine) + _product(
        _product(cos(theta1), cos(theta2)), _product(lon_sine, lon_sine))
    # Do not clamp a: preserve the source's nonfinite behavior near antipodes.
    var c = Float64(2) * asin(sqrt(a))
    return Float64(6_371_008.8) * c
