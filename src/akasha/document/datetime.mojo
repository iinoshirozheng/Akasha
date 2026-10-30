"""Qdrant DateTimeWrapper / chrono 0.4.45 UTC parsing and timestamps.

Qdrant 74f3e85b9473c62560006c043e13737ce6b48412 (Apache-2.0).
Chrono 170338250e836976a211e64728ec956e45e78a39 (MIT OR Apache-2.0).
Copyright (c) 2014--2026 Kang Seonghoon and contributors;
parsing portions copyright (c) 2015 John Nagle. See THIRD_PARTY_NOTICES.md.
The fixed parser modes specialize chrono format items used by Qdrant; calendar
validation/ordinal and Unicode whitespace tables are generated from source.
"""
from akasha.document.chrono_tables import (
    MIN_SECONDS, MAX_SECONDS, year_flags, ordinal_adjustments, is_whitespace,
)
from akasha.document.value import PayloadValue


struct DateTimeValue(Copyable, Movable):
    # Keep chrono's leap-second representation, including sub-microsecond bits.
    var seconds: Int64
    var nanoseconds: UInt32

    def __init__(out self, seconds: Int64, nanoseconds: UInt32 = 0) raises:
        self.seconds = seconds
        self.nanoseconds = nanoseconds
        self.validate()

    def validate(self) raises:
        if self.seconds < MIN_SECONDS or self.seconds > MAX_SECONDS:
            raise Error("datetime is outside chrono's supported range")
        var second = Int(self.seconds % 60)
        if second < 0:
            second += 60
        if self.nanoseconds >= 2_000_000_000 or (self.nanoseconds >= 1_000_000_000 and second != 59):
            raise Error("invalid datetime nanoseconds or leap second")

    def timestamp(self) -> Int64:
        # chrono DateTime::timestamp_micros, including negative/leap timestamps.
        return self.seconds * 1_000_000 + Int64(self.nanoseconds // 1000)

    @staticmethod
    def from_timestamp(micros: Int64) raises -> DateTimeValue:
        if micros < Int64(MIN_SECONDS) * 1_000_000 or micros > Int64(MAX_SECONDS) * 1_000_000 + 999_999:
            raise Error("datetime microsecond timestamp is outside chrono's supported range")
        var remainder = micros % 1_000_000
        if remainder < 0:
            remainder += 1_000_000
        return DateTimeValue((micros - remainder) // 1_000_000, UInt32(remainder * 1000))

    @staticmethod
    def from_payload(value: PayloadValue) raises -> DateTimeValue:
        if not value.is_string():
            raise Error("datetime payload must be a string")
        return DateTimeValue.parse(value.as_string())

    @staticmethod
    def parse(text: String) raises -> DateTimeValue:
        if text.byte_length() > 65_536:
            raise Error("datetime input exceeds 65536 bytes")
        var cursor = _DateCursor(text)
        # Original ordered attempts: strict, relaxed, zoned T/space,
        # naive seconds T/space, naive minutes T/space, date only.
        for mode in range(9):
            cursor.position = 0
            try:
                return cursor.parse_mode(mode)
            except:
                pass
        raise Error("invalid datetime: input does not match accepted Qdrant formats")


def _date_days(year: Int, month: Int, day: Int) raises -> Int:
    # chrono NaiveDate::from_ymd_opt/from_mdf, YearFlags and Mdf::ordinal.
    if year < -262143 or year > 262142 or month < 1 or month > 12 or day < 1 or day > 31:
        raise Error("datetime calendar component is out of range")
    var cycle = year % 400
    if cycle < 0:
        cycle += 400
    var flags = year_flags()[cycle]
    var mdl = ((month << 9) | (day << 4) | flags) >> 3
    var adjustment = ordinal_adjustments()[mdl]
    if adjustment == 0:
        raise Error("datetime calendar date does not exist")
    var ordinal = (mdl - adjustment) >> 1
    # chrono NaiveDate::num_days_from_ce, with its negative-year adjustment.
    var previous = year - 1
    var days = 0
    if previous < 0:
        var excess = 1 + (-previous) // 400
        previous += excess * 400
        days -= excess * 146097
    var century = previous // 100
    days += ((previous * 1461) >> 2) - century + (century >> 2)
    return days + ordinal


struct _DateCursor(Movable):
    var characters: List[Int]
    var position: Int

    def __init__(out self, text: String):
        self.characters = []
        self.position = 0
        for cp in text.codepoints():
            self.characters.append(Int(cp))

    def peek(self) -> Int:
        if self.position == len(self.characters):
            return -1
        return self.characters[self.position]

    def space(mut self):
        while self.position < len(self.characters) and is_whitespace(self.characters[self.position]):
            self.position += 1

    def literal(mut self, code: Int) raises:
        if self.peek() != code:
            raise Error("invalid datetime separator")
        self.position += 1

    def number(mut self, minimum: Int, maximum: Int) raises -> Int:
        # chrono scan::number, including signed-i64 magnitude overflow checks.
        var result = 0
        var consumed = 0
        while consumed < maximum:
            var digit = self.peek() - 48
            if digit < 0 or digit > 9:
                break
            if result > (9223372036854775807 - digit) // 10:
                raise Error("datetime numeric component overflows i64")
            result = result * 10 + digit
            self.position += 1
            consumed += 1
        if consumed < minimum:
            raise Error("datetime numeric component is missing")
        return result

    def component(mut self, width: Int, strict: Bool = False) raises -> Int:
        if not strict:
            self.space()
        return self.number(width if strict else 1, width)

    def year(mut self, strict: Bool) raises -> Int:
        if strict:
            return self.number(4, 4)
        self.space()
        var sign = self.peek()
        if sign == 45 or sign == 43:
            self.position += 1
            var value = self.number(1, len(self.characters))
            return -value if sign == 45 else value
        return self.number(1, 4)

    def fraction(mut self) raises -> Int:
        # chrono scan::nanosecond: retain nine digits, discard additional digits.
        if self.peek() != 46:
            return 0
        self.position += 1
        var start = self.position
        var value = self.number(1, 9)
        var consumed = self.position - start
        for _ in range(consumed, 9):
            value *= 10
        while self.peek() >= 48 and self.peek() <= 57:
            self.position += 1
        return value

    def timezone(mut self, strict: Bool, missing_minutes: Bool) raises -> Int:
        # chrono scan::timezone_offset, including Unicode MINUS SIGN.
        if self.peek() == 90 or self.peek() == 122:
            self.position += 1
            return 0
        var sign = self.peek()
        if sign != 43 and sign != 45 and sign != 0x2212:
            raise Error("invalid datetime timezone")
        self.position += 1
        var hours = self.number(2, 2)
        if strict:
            self.literal(58)
        else:
            while self.peek() == 58 or is_whitespace(self.peek()):
                self.position += 1
        var minutes = 0
        if self.position == len(self.characters) and missing_minutes:
            pass
        else:
            minutes = self.number(2, 2)
        if minutes > 59 or hours > 23:
            raise Error("datetime timezone is out of range")
        var offset = hours * 3600 + minutes * 60
        return offset if sign == 43 else -offset

    def parse_mode(mut self, mode: Int) raises -> DateTimeValue:
        var strict = mode == 0
        var relaxed = mode == 1
        var year = self.year(strict)
        if relaxed:
            self.space()
        self.literal(45)
        var month = self.component(2, strict)
        if relaxed:
            self.space()
        self.literal(45)
        var day = self.component(2, strict)
        var days = _date_days(year, month, day)
        var hour = 0
        var minute = 0
        var second = 0
        var nanos = 0
        var offset = 0
        if mode != 8:
            if strict or relaxed:
                var separator = self.peek()
                if separator != 84 and separator != 116 and separator != 32:
                    raise Error("invalid datetime date/time separator")
                self.position += 1
            elif mode == 2 or mode == 4 or mode == 6:
                self.literal(84)
            else:
                # chrono Item::Space consumes zero or more Unicode whitespace.
                self.space()
            hour = self.component(2, strict)
            if relaxed:
                self.space()
            self.literal(58)
            minute = self.component(2, strict)
            if mode < 6:
                if relaxed:
                    self.space()
                self.literal(58)
                second = self.component(2, strict)
                nanos = self.fraction()
            if mode < 4:
                if not strict:
                    self.space()
                if relaxed and self.position + 3 <= len(self.characters) and (
                    self.characters[self.position] | 32) == 117 and (
                    self.characters[self.position + 1] | 32) == 116 and (
                    self.characters[self.position + 2] | 32) == 99:
                    self.position += 3
                else:
                    offset = self.timezone(strict, mode == 2 or mode == 3)
            if relaxed:
                self.space()
        if self.position != len(self.characters):
            raise Error("datetime has trailing input")
        # chrono Parsed::to_naive_time / NaiveTime::from_hms_nano_opt.
        if hour > 23 or minute > 59 or second > 60:
            raise Error("datetime time component is out of range")
        if second == 60:
            second = 59
            nanos += 1_000_000_000
        # chrono DateTime::timestamp and FixedOffset UTC conversion.
        var seconds = (days - 719163) * 86400 + hour * 3600 + minute * 60 + second - offset
        return DateTimeValue(Int64(seconds), UInt32(nanos))
