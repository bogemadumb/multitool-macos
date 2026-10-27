import Testing
import Foundation
@testable import MultitulCore

private func calc(_ s: String, _ angle: CalcAngle = .radians) -> Double? {
    if case .success(let v) = CalcEngine.evaluate(s, angle: angle) { return v }
    return nil
}

private func fail(_ s: String) -> CalcError? {
    if case .failure(let e) = CalcEngine.evaluate(s) { return e }
    return nil
}

@Suite struct CbCalcBasicsTests {
    @Test(arguments: [
        ("2+2", 4.0), ("2 + 3 * 4", 14.0), ("(2+3)*4", 20.0), ("10/4", 2.5), ("10 - 2 - 3", 5.0), ("2*3*4", 24.0), ("100/10/2", 5.0),
        ("2^3", 8.0), ("2^3^2", 512.0), ("-2^2", -4.0), ("(-2)^2", 4.0), ("2^-1", 0.5), ("2**10", 1024.0), ("-(-3)", 3.0), ("--3", 3.0), ("+5", 5.0),
        ("7 mod 3", 1.0), ("1+2*3-4/2", 5.0), ("((1+2)*(3+4))", 21.0), ("0.1+0.2", 0.30000000000000004), (".5+.5", 1.0), ("3×4", 12.0), ("12÷4", 3.0),
        ("5−2", 3.0), ("2 · 5", 10.0)
    ])
    func arithmetic(_ expr: String, _ expected: Double) {
        let v = calc(expr)
        #expect(v != nil && abs(v! - expected) < 1e-12, "\(expr) -> \(String(describing: v))")
    }

    @Test func unaryMinusBindsLooserThanPower() {
        #expect(calc("-3^2") == -9)
        #expect(calc("2*-3") == -6)
        #expect(calc("2--3") == 5)
        #expect(calc("-2*-2") == 4)
    }

    @Test func precedenceMixesAllLevels() {
        #expect(calc("2+3*4^2") == 50)
        #expect(calc("(2+3)*4^2/8") == 10)
        #expect(calc("100-10*2+5") == 85)
    }

    @Test func implicitMultiplication() {
        #expect(calc("2(3+4)") == 14)
        #expect(calc("(1+1)(2+2)") == 8)
        #expect(abs((calc("2pi") ?? 0) - 2 * Double.pi) < 1e-12)
        #expect(abs((calc("3 pi") ?? 0) - 3 * Double.pi) < 1e-12)
        #expect(calc("2sqrt(9)") == 6)
    }

    @Test func twoNumbersWithoutOperatorAreAnError() {
        #expect(fail("2 3") == .syntax)
        #expect(fail("12 34") == .syntax)
        #expect(fail("1 2 3") == .syntax)
    }
}

@Suite struct CbCalcNumbersTests {
    @Test(arguments: [("1,5 + 1,5", 3.0), ("1,5*2", 3.0), ("0,25", 0.25), (",5+,5", 1.0), ("1.5+1,5", 3.0)])
    func decimalComma(_ expr: String, _ expected: Double) {
        #expect(abs((calc(expr) ?? .nan) - expected) < 1e-12)
    }

    @Test(arguments: [("1 000 + 2 000", 3000.0), ("1 000 000 / 1 000", 1000.0), ("12 345 678", 12_345_678.0), ("1 000,5 * 2", 2001.0), ("1\u{00A0}000+1", 1001.0), ("1\u{202F}000 + 1", 1001.0)])
    func spacesInNumbers(_ expr: String, _ expected: Double) {
        #expect(abs((calc(expr) ?? .nan) - expected) < 1e-9, "\(expr)")
    }

    @Test func groupMustBeExactlyThreeDigits() {
        #expect(fail("1 00") == .syntax)
        #expect(fail("1 0000") == .syntax)
        #expect(fail("1234 567") == .syntax)
    }

    @Test(arguments: [("1e3", 1000.0), ("2e-3", 0.002), ("1.5e2", 150.0), ("1E3", 1000.0), ("2e+2", 200.0)])
    func exponentNotation(_ expr: String, _ expected: Double) {
        #expect(abs((calc(expr) ?? .nan) - expected) < 1e-12)
    }

    @Test func eFollowedByNonDigitIsTheConstant() {
        #expect(abs((calc("2e") ?? 0) - 2 * M_E) < 1e-12)
        #expect(abs((calc("e^1") ?? 0) - M_E) < 1e-12)
    }
}

@Suite struct CbCalcPercentTests {
    @Test(arguments: [("50%", 0.5), ("200 + 10%", 220.0), ("200 - 10%", 180.0), ("200 * 10%", 20.0), ("200 / 50%", 400.0), ("15% от 200", 30.0),
                      ("15 процентов от 200", 30.0), ("15 percent of 200", 30.0), ("100 + 20% + 10%", 132.0), ("(10%)", 0.1)])
    func percent(_ expr: String, _ expected: Double) {
        #expect(abs((calc(expr) ?? .nan) - expected) < 1e-12, "\(expr) -> \(String(describing: calc(expr)))")
    }

    @Test func percentOfExpression() {
        #expect(abs((calc("(100+50) * 10%") ?? 0) - 15) < 1e-12)
    }
}

@Suite struct CbCalcFunctionsTests {
    @Test(arguments: [("sqrt(16)", 4.0), ("sqrt 16", 4.0), ("корень из 25", 5.0), ("√9", 3.0), ("cbrt(27)", 3.0), ("abs(-3)", 3.0), ("floor(2.7)", 2.0), ("ceil(2.1)", 3.0),
                      ("round(2.5)", 3.0), ("round(-2.5)", -3.0), ("trunc(-2.7)", -2.0), ("log(1000)", 3.0), ("lg(100)", 2.0), ("log2(8)", 3.0), ("ln(e)", 1.0),
                      ("exp(0)", 1.0), ("max(1;5;3)", 5.0), ("min(4;2;9)", 2.0), ("pow(2;10)", 1024.0), ("hypot(3;4)", 5.0), ("fact(5)", 120.0), ("5!", 120.0), ("0!", 1.0)])
    func functions(_ expr: String, _ expected: Double) {
        #expect(abs((calc(expr) ?? .nan) - expected) < 1e-9, "\(expr) -> \(String(describing: calc(expr)))")
    }

    @Test func trigInRadians() {
        #expect(calc("sin(0)") == 0)
        #expect(calc("cos(0)") == 1)
        #expect(abs((calc("sin(pi/2)") ?? 0) - 1) < 1e-12)
        #expect(abs((calc("cos(pi)") ?? 0) + 1) < 1e-12)
        #expect(abs((calc("tan(pi/4)") ?? 0) - 1) < 1e-12)
    }

    @Test func trigInDegrees() {
        #expect(abs((calc("sin(90)", .degrees) ?? 0) - 1) < 1e-12)
        #expect(abs((calc("cos(60)", .degrees) ?? 0) - 0.5) < 1e-12)
        #expect(abs((calc("atan(1)", .degrees) ?? 0) - 45) < 1e-9)
        #expect(abs((calc("asin(1)", .degrees) ?? 0) - 90) < 1e-9)
    }

    @Test func piOfSinIsExactlyZeroNotNoise() {
        #expect(calc("sin(pi)") == 0)
        #expect(calc("cos(pi/2)") == 0)
    }

    @Test(arguments: [("pi", Double.pi), ("π", Double.pi), ("пи", Double.pi), ("e", M_E), ("tau", 2 * Double.pi)])
    func constants(_ expr: String, _ expected: Double) {
        #expect(abs((calc(expr) ?? 0) - expected) < 1e-12)
    }

    @Test func russianWordOperators() {
        #expect(calc("2 плюс 3") == 5)
        #expect(calc("10 минус 4") == 6)
        #expect(calc("6 умножить на 7") == 42)
        #expect(calc("20 разделить на 4") == 5)
        #expect(calc("2 в степени 10") == 1024)
        #expect(calc("корень 81") == 9)
    }

    @Test func argumentCountIsChecked() {
        #expect(fail("pow(2)") == .syntax)
        #expect(fail("sin(1;2)") == .syntax)
        #expect(fail("sin()") == .syntax)
    }
}

@Suite struct CbCalcErrorsTests {
    @Test func divisionByZero() {
        #expect(fail("1/0") == .divisionByZero)
        #expect(fail("5 / (3-3)") == .divisionByZero)
        #expect(fail("0^-1") == .divisionByZero)
        #expect(fail("5 mod 0") == .divisionByZero)
    }

    @Test func domainErrors() {
        #expect(fail("sqrt(-1)") == .domain)
        #expect(fail("ln(0)") == .domain)
        #expect(fail("log(-5)") == .domain)
        #expect(fail("asin(2)") == .domain)
        #expect(fail("(-8)^0.5") == .domain)
        #expect(fail("(-1)!") == .domain)
        #expect(fail("2.5!") == .domain)
    }

    @Test func overflow() {
        #expect(fail("10^400") == .overflow)
        #expect(fail("171!") == .overflow)
        #expect(fail("1e308*10") == .overflow)
        #expect(fail("exp(1000)") == .overflow)
        #expect(calc("170!") != nil)
    }

    @Test func syntaxErrors() {
        #expect(fail("2 +") == .syntax)
        #expect(fail("(2+3") == .syntax)
        #expect(fail("2+3)") == .syntax)
        #expect(fail("*3") == .syntax)
        #expect(fail("2 $ 3") == .syntax)
        #expect(fail("()") == .syntax)
    }

    @Test func emptyAndUnknown() {
        #expect(fail("") == .empty)
        #expect(fail("   ") == .empty)
        #expect(fail("foo(1)") == .unknownName("foo"))
        #expect(fail("5 km") == .unknownName("km"))
    }

    @Test func untrustedInputCannotBlowTheStack() {
        let deep = String(repeating: "(", count: 400) + "1" + String(repeating: ")", count: 400)
        #expect(fail(deep) == .tooComplex)
        #expect(fail(String(repeating: "1+", count: 400) + "1") == .tooComplex)
        let nestedMinus = String(repeating: "-", count: 200) + "1"
        #expect(fail(nestedMinus) != nil || calc(nestedMinus) != nil)
    }

    @Test func messagesAreRussian() {
        for e in [CalcError.empty, .syntax, .divisionByZero, .overflow, .domain, .unknownName("x"), .tooComplex] { #expect(!e.message.isEmpty) }
        #expect(CalcError.divisionByZero.message == "Деление на ноль")
    }
}

@Suite struct CbCalcDetectionTests {
    @Test(arguments: ["2+2", "2 * 3", "sin(1)", "10%", "pi", "5!", "(1+2)", "2^10", "100 / 4", "10 - 5 - 2", "корень из 9", "15% от 200", "1,5*2"])
    func looksLikeCalculation(_ s: String) { #expect(CalcEngine.looksLikeCalculation(s), "\(s)") }

    @Test(arguments: ["tel", "42", "-5", "12.05.2024", "telegram", "e", "2 km", "", "   ", "+7 000 000-00-00", "1 000", "2e", "hello world", "safari 17", "12-05-2024", "8-800-555-35-35"])
    func isNotACalculation(_ s: String) { #expect(!CalcEngine.looksLikeCalculation(s), "\(s)") }
}

@Suite struct CbCalcFormatTests {
    private func f(_ v: Double, comma: Bool = true, grouping: Bool = true) -> String {
        CalcFormat.format(v, CalcFormatOptions(decimalComma: comma, grouping: grouping))
    }

    @Test func integersAreGroupedWithNoBreakSpaces() {
        #expect(f(1_234_567) == "1\u{00A0}234\u{00A0}567")
        #expect(f(100) == "100")
        #expect(f(-1500) == "-1\u{00A0}500")
        #expect(f(0) == "0")
        #expect(f(-0.0) == "0")
    }

    @Test func fractionsUseCommaAndNoNoise() {
        #expect(f(0.1 + 0.2) == "0,3")
        #expect(f(2.5) == "2,5")
        #expect(f(1.0 / 3.0) == "0,333333333333")
        #expect(f(1234.5678) == "1\u{00A0}234,5678")
    }

    @Test func optionsSwitchSeparators() {
        #expect(f(0.5, comma: false) == "0.5")
        #expect(f(1_234_567, grouping: false) == "1234567")
        #expect(f(1234.5, comma: false, grouping: false) == "1234.5")
    }

    @Test func hugeAndTinyUseExponent() {
        #expect(f(1e20) == "1e20")
        #expect(f(1.5e-10) == "1,5e-10")
        #expect(f(1e15) == "1e15")
        #expect(f(-2.5e25) == "-2,5e25")
        #expect(f(123_456_789_012_345) == "123\u{00A0}456\u{00A0}789\u{00A0}012\u{00A0}345")
    }

    @Test func nonFiniteIsReadable() {
        #expect(CalcFormat.format(.infinity) == "∞")
        #expect(CalcFormat.format(-.infinity) == "−∞")
        #expect(CalcFormat.format(.nan) == "не число")
    }

    @Test func significantDigitsAreRespected() {
        #expect(CalcFormat.format(Double.pi, CalcFormatOptions(significantDigits: 5)) == "3,1416")
        #expect(CalcFormat.format(22.0462262185, CalcFormatOptions(significantDigits: 7)) == "22,04623")
    }
}
