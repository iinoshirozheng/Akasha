# Score-bit fixtures captured from 7b53ce9, Mojo 1.0.0 ed45d567.
# Each dimension: dense Dot/L2/cosine, then 2x3-row MaxSim Dot/L2/cosine.
# Fractional inputs and odd/large dimensions guard sequential F64 accumulation.
from akasha.compute.field_metrics import _numeric_score, score_vector_field
from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from std.memory import bitcast
from std.testing import assert_equal, assert_raises, TestSuite


def _values[dtype: DType](count: Int, seed: Int) -> List[Scalar[dtype]]:
    var values = List[Scalar[dtype]](capacity=count)
    for index in range(count):
        var raw = (index * 73 + seed * 31) % 251
        comptime if dtype == DType.uint8:
            values.append(Scalar[dtype](raw))
        elif dtype == DType.int8:
            values.append(Scalar[dtype](raw - 125))
        else:
            values.append(Scalar[dtype](Float64(raw - 125) / Float64(17)))
    return values^


def _check_cases[dtype: DType](expected: List[UInt64]) raises:
    var cursor = 0
    var dimensions = [1, 2, 3, 7, 16, 127, 128, 129, 1536]
    for dimension in dimensions:
        var query = VectorValue.dense[dtype](_values[dtype](dimension, 3))
        var candidate = VectorValue.dense[dtype](_values[dtype](dimension, 7))
        var multi_query = VectorValue.multivector[dtype](
            dimension, _values[dtype](2 * dimension, 3)
        )
        var multi_candidate = VectorValue.multivector[dtype](
            dimension, _values[dtype](3 * dimension, 7)
        )
        for metric in range(3):
            var field = VectorFieldSpec(
                2, "v", 0, query.scalar(), UInt8(metric), 0, dimension
            )
            assert_equal(
                bitcast[DType.uint64](
                    score_vector_field(query, candidate, field)
                ),
                expected[cursor],
            )
            cursor += 1
        for metric in range(3):
            var field = VectorFieldSpec(
                2, "v", 2, query.scalar(), UInt8(metric), 0, dimension
            )
            assert_equal(
                bitcast[DType.uint64](
                    score_vector_field(multi_query, multi_candidate, field)
                ),
                expected[cursor],
            )
            cursor += 1

    assert_equal(cursor, len(expected))


def test_float32_dense_and_maxsim_score_bits() raises:
    var expected: List[UInt64] = [
        0xC0245FAAF236EBA0,
        0x404A9A219FC038B2,
        0xBFF0000000000000,
        0x4036930B7B4ED660,
        0x40247F8E9D261708,
        0x4000000000000000,
        0xC036633601F72450,
        0x405B40E2BE2C4A69,
        0xBFEF9C0EE9658B8E,
        0x4050526172F16252,
        0x4017641915509C50,
        0x3FFDF3D393483D32,
        0xC03B83FC7221A930,
        0x40649A5A5DB4B4B6,
        0xBFE00A49CB62FCFD,
        0xC046063369CC9F72,
        0x40729327DEF6418E,
        0xBFEBD35AF7C78442,
        0xC050A2FD55F39940,
        0x4077ED9E8FACBBCD,
        0xBFE10D8F0D883692,
        0xC05F3FC74BB30B83,
        0x408770CD82B02370,
        0xBFF0007BF3363662,
        0xC062E6DD7398AA13,
        0x408B55BAE8F99064,
        0xBFE0F3F78A48BE47,
        0x40647D57A61D7B1E,
        0x40887F8EA92BF8F2,
        0x3FE2D0DF77938B3C,
        0xC091FE8F81143BCA,
        0x40BB09137DE34E65,
        0xBFDFEC159C7F010B,
        0xC09F77F55E7019B1,
        0x40C9E30E9E0DCBBA,
        0xBFEBF225DBFAB2F5,
        0xC092310D4A385498,
        0x40BB3E47C13FFC04,
        0xBFE009F623C5A61A,
        0x4091CEB67AD132EF,
        0x40BB4B2B67A1D862,
        0x3FDF7566EAE0B812,
        0xC092545895785498,
        0x40BB761708F92CBC,
        0xBFE0077F4F6AE8E1,
        0x40B10919B0B7355E,
        0x40843320C2FA851E,
        0x3FFDCC2AE4939650,
        0xC0CB3EAA868FA49C,
        0x40F46F5C91D66B3C,
        0xBFDFFF26BDEE1170,
        0x40D1F8930B8F1F41,
        0x40F23E8807477D40,
        0x3FE51F628A83C72B,
    ]
    _check_cases[DType.float32](expected)


def test_bfloat16_dense_and_maxsim_score_bits() raises:
    var expected: List[UInt64] = [
        0xC0245BA000000000,
        0x404A90B200000000,
        0xBFF0000000000000,
        0x40368A6000000000,
        0x40247F0800000000,
        0x4000000000000000,
        0xC0365C5000000000,
        0x405B3A6900000000,
        0xBFEF9EB837FDF87C,
        0x405054D200000000,
        0x4017AC5000000000,
        0x3FFDF056CE25B72C,
        0xC03B813000000000,
        0x40649DB680000000,
        0xBFE003DBD872C398,
        0xC0460F7200000000,
        0x4072958E40000000,
        0xBFEBDFC3594415AA,
        0xC050A14000000000,
        0x4077EDCD80000000,
        0xBFE10A989172168A,
        0xC05F3CA300000000,
        0x4087714884000000,
        0xBFEFFB46523F3320,
        0xC062E66B00000000,
        0x408B56A118800000,
        0xBFE0F23DADBD47CA,
        0x40647166E0000000,
        0x40888B156A800000,
        0x3FE2C2E1EEB3E172,
        0xC091FF328A000000,
        0x40BB0A1363960000,
        0xBFDFEC024B1DDEB4,
        0xC09F779E5C000000,
        0x40C9E372C6960000,
        0xBFEBF122952C59EF,
        0xC09231C00A000000,
        0x40BB3F51F3960000,
        0xBFE009F771F6C3D4,
        0x4091CF47C8800000,
        0x40BB4B2F86EC0000,
        0x3FDF74D9C13BBB86,
        0xC09255000A000000,
        0x40BB771A33960000,
        0xBFE00777DF933C1C,
        0x40B1098909E40000,
        0x40842FEDEA600000,
        0x3FFDCC8AA956337E,
        0xC0CB405B69000000,
        0x40F46FEF4B718000,
        0xBFE000645633FE71,
        0x40D1F89E1AE00000,
        0x40F23EBDC0801000,
        0x3FE51F3D5DCBE73D,
    ]
    _check_cases[DType.bfloat16](expected)


def test_float16_dense_and_maxsim_score_bits() raises:
    var expected: List[UInt64] = [
        0xC0245F6400000000,
        0x404A97FC80000000,
        0xBFF0000000000000,
        0x4036930380000000,
        0x40247A26A0000000,
        0x4000000000000000,
        0xC036636080000000,
        0x405B3FEC50000000,
        0xBFEF9C47EE75EB08,
        0x40505267F0000000,
        0x4017688040000000,
        0x3FFDF3A1A09D044A,
        0xC03B844740000000,
        0x40649A64BA000000,
        0xBFE00A7B64AB688C,
        0xC0460A4CC0000000,
        0x4072955BFA000000,
        0xBFEBD5F19E9F8948,
        0xC050A36DF0000000,
        0x4077EE4C4A000000,
        0xBFE10D7FF71CC971,
        0xC05F3F72CC000000,
        0x408770A5A7100000,
        0xBFF0005EE656C9A3,
        0xC062E6AD60000000,
        0x408B554F06200000,
        0xBFE0F413E6FC3B47,
        0x40647DC9CC000000,
        0x40887FA04F680000,
        0x3FE2D11D15828F7A,
        0xC091FE8250400000,
        0x40BB08F13DCC0000,
        0xBFDFEC2F2CECB245,
        0xC09F77D93A400000,
        0x40C9E2ED2DDC0000,
        0xBFEBF235BD2AB9B6,
        0xC09230FDF0400000,
        0x40BB3E2136CC0000,
        0xBFE00A03E0AF8A3A,
        0x4091CE7A2E780000,
        0x40BB4B296ADC0000,
        0x3FDF75265974CFE0,
        0xC0925449F0400000,
        0x40BB75F0EF0C0000,
        0xBFE0078D63420FF9,
        0x40B1091F17880000,
        0x40843182B8000000,
        0x3FFDCC5576C975AE,
        0xC0CB3E9A13200000,
        0x40F46F44D696A000,
        0xBFDFFF417F3DFD0A,
        0x40D1F8631A568000,
        0x40F23E7995768000,
        0x3FE51F47DB2450B2,
    ]
    _check_cases[DType.float16](expected)


def test_int8_dense_and_maxsim_score_bits() raises:
    var expected: List[UInt64] = [
        0xC0A7000000000000,
        0x40CE080000000000,
        0xBFF0000000000000,
        0x40B97C0000000000,
        0x40A7240000000000,
        0x4000000000000000,
        0xC0B9460000000000,
        0x40DEC44000000000,
        0xBFEF9C0EE6B83FFB,
        0x40D26D0000000000,
        0x409A680000000000,
        0x3FFDF3D396C2A1A4,
        0xC0BF100000000000,
        0x40E7424000000000,
        0xBFE00A49D1D168CB,
        0xC0C8DD0000000000,
        0x40F4F82000000000,
        0xBFEBD35AEB5850DA,
        0xC0D2C80000000000,
        0x40FB034000000000,
        0xBFE10D8F107E47FD,
        0xC0E1A38000000000,
        0x410A765800000000,
        0xBFF0007BF60D2546,
        0xC0E556A000000000,
        0x410EDBC800000000,
        0xBFE0F3F78C009CFD,
        0x40E7218000000000,
        0x410BA80000000000,
        0x3FE2D0DF858EC3EA,
        0xC114506000000000,
        0x413E853F00000000,
        0xBFDFEC159C8DAE7F,
        0xC121C33600000000,
        0x414D395380000000,
        0xBFEBF225DCFA932E,
        0xC114896000000000,
        0x413EC14F00000000,
        0xBFE009F623C202A0,
        0x41141A5C00000000,
        0x413ECFDC00000000,
        0x3FDF7566EB65A203,
        0xC114B13800000000,
        0x413F005000000000,
        0xBFE0077F4F7008B4,
        0x41333B4600000000,
        0x4106CDB800000000,
        0x3FFDCC2AE42D51D0,
        0xC14EC1BE80000000,
        0x417711B780000000,
        0xBFDFFF26BC479235,
        0x4154499E00000000,
        0x4174989790000000,
        0x3FE51F628AA5802E,
    ]
    _check_cases[DType.int8](expected)


def test_uint8_dense_and_maxsim_score_bits() raises:
    var expected: List[UInt64] = [
        0x40D3B54000000000,
        0x40CE080000000000,
        0x3FF0000000000000,
        0x40EB716000000000,
        0x40A7240000000000,
        0x4000000000000000,
        0x40DA07C000000000,
        0x40DEC44000000000,
        0x3FE455027C5E94F4,
        0x40F7488000000000,
        0x409A680000000000,
        0x3FFFF30A29155BCC,
        0x40EA15E000000000,
        0x40E7424000000000,
        0x3FE6A1032A64F852,
        0x40FB882000000000,
        0x40F4F82000000000,
        0x3FF7363270E7F21E,
        0x40F5273000000000,
        0x40FB034000000000,
        0x3FE3AAC0E4E8BC73,
        0x410A3EC800000000,
        0x410A765800000000,
        0x3FF549ADDEF36FD2,
        0x410B942000000000,
        0x410EDBC800000000,
        0x3FE496650FD2FFA4,
        0x41203F2800000000,
        0x410BA80000000000,
        0x3FFA722A9F72A20A,
        0x4138E0DA00000000,
        0x413E853F00000000,
        0x3FE3D5861F48121A,
        0x4149C6D500000000,
        0x414D395380000000,
        0x3FF4664D1463759A,
        0x41391D4F00000000,
        0x413EC14F00000000,
        0x3FE3D8F7BECC7890,
        0x41508917C0000000,
        0x413ECFDC00000000,
        0x3FF9F9C7BD1F161E,
        0x41392AC900000000,
        0x413F005000000000,
        0x3FE3CD9A38B6098E,
        0x41543F5540000000,
        0x4106CDB800000000,
        0x3FFF72BA08E85DA4,
        0x41730CAED0000000,
        0x417711B780000000,
        0x3FE3EE71FD1AD62B,
        0x41896D33E8000000,
        0x4174989790000000,
        0x3FFA9C064928ADC8,
    ]
    _check_cases[DType.uint8](expected)


def test_dot_preserves_sequential_cancellation_and_signed_zero() raises:
    var query = VectorValue.dense[DType.float32]([1, 1, 1, 1])
    var candidate = VectorValue.dense[DType.float32](
        [1152921504606846976.0, 1, -1152921504606846976.0, 3]
    )
    var field = VectorFieldSpec(2, "v", 0, 0, 0, 0, 4)
    # A grouped reduction can produce four; ordered accumulation produces three.
    assert_equal(score_vector_field(query, candidate, field), Float64(3))
    var zeros = VectorValue.dense[DType.float32]([-0.0, 0.0, -0.0, 0.0])
    assert_equal(
        bitcast[DType.uint64](score_vector_field(zeros, candidate, field)),
        UInt64(0),
    )


def test_native_metric_requires_equal_span_lengths_before_iteration() raises:
    var empty = List[Float32]()
    var other_empty = List[Float32]()
    var one: List[Float32] = [1]
    var two: List[Float32] = [1, 2]
    for metric in range(3):
        with assert_raises():
            _ = _numeric_score[DType.float32](
                UInt8(metric), Span(empty), Span(one)
            )
        with assert_raises():
            _ = _numeric_score[DType.float32](
                UInt8(metric), Span(two), Span(one)
            )
        with assert_raises():
            _ = _numeric_score[DType.float32](
                UInt8(metric), Span(one), Span(two)
            )
    for metric in range(2):
        assert_equal(
            _numeric_score[DType.float32](
                UInt8(metric), Span(empty), Span(other_empty)
            ),
            Float64(0),
        )
    with assert_raises():
        _ = _numeric_score[DType.float32](2, Span(empty), Span(other_empty))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
