import Foundation
import Testing
import VoxaCore
@testable import VoxaPolicy

@Suite("InputValidator")
struct InputValidatorTests {
    private let schema = Schema.object([
        "name": Schema.string("App name", minLength: 1, maxLength: 20),
        "count": Schema.integer("How many", minimum: 1, maximum: 5),
        "mode": Schema.string("Mode", enum: ["fast", "slow"]),
        "flag": Schema.boolean("A flag"),
        "tags": Schema.array(of: Schema.string("tag", maxLength: 3), "Tags"),
        "ratio": Schema.number("A ratio"),
    ], required: ["name"])

    private func problems(_ json: JSONValue) -> [String] {
        InputValidator.validate(json, against: schema)
    }

    @Test("a valid call has no problems, and optional arguments may be left out")
    func valid() {
        #expect(problems(["name": "Safari"]).isEmpty)
        #expect(problems(["name": "Safari", "count": 3, "mode": "fast", "flag": true, "tags": ["a", "b"], "ratio": 0.5]).isEmpty)
    }

    @Test("a missing required argument is named")
    func missing() {
        #expect(problems([:]) == ["Missing required argument 'name'."])
    }

    @Test("an extra argument is refused, including the ones a manipulated model would add")
    func extraArguments() {
        for key in ["confirmed", "user_approved", "risk", "skip_confirmation", "dangerouslyDisableSandbox"] {
            var input: [String: JSONValue] = ["name": "Safari"]
            input[key] = true
            let result = problems(.object(input))
            #expect(result.count == 1)
            #expect(result[0].contains("Unexpected argument '\(key)'"))
            #expect(result[0].contains("count, flag, mode, name, ratio, tags"), "tells the model what it may pass")
        }
        #expect(problems(["name": "x", "b": 1, "a": 2])[0].contains("'a', 'b'"), "several unexpected names are listed, sorted")
    }

    @Test("wrong types are named with what was expected")
    func wrongTypes() {
        let cases: [(input: JSONValue, expected: String)] = [
            (["name": 5], "Argument 'name' must be a string."),
            (["name": "x", "count": "3"], "Argument 'count' must be an integer."),
            (["name": "x", "count": 2.5], "Argument 'count' must be an integer."),
            (["name": "x", "flag": "true"], "Argument 'flag' must be a boolean."),
            (["name": "x", "tags": "a"], "Argument 'tags' must be an array."),
            (["name": "x", "ratio": "0.5"], "Argument 'ratio' must be a number."),
            (["name": .null], "Argument 'name' must be a string."),
        ]
        for testCase in cases {
            #expect(problems(testCase.input) == [testCase.expected], "\(testCase.input)")
        }
    }

    @Test("a whole number written with a decimal point is accepted as an integer")
    func integralDouble() {
        #expect(problems(["name": "x", "count": .double(3)]).isEmpty)
    }

    @Test("ranges and lengths are enforced")
    func ranges() {
        #expect(problems(["name": "x", "count": 0]) == ["Argument 'count' must be at least 1."])
        #expect(problems(["name": "x", "count": 6]) == ["Argument 'count' must be at most 5."])
        #expect(problems(["name": ""]) == ["Argument 'name' must be at least 1 character long."])
        #expect(problems(["name": .string(String(repeating: "a", count: 21))]) == ["Argument 'name' must be at most 20 characters long."])
    }

    @Test("an enum value outside the list is refused and the allowed ones are listed")
    func enumValues() {
        #expect(problems(["name": "x", "mode": "turbo"]) == ["Argument 'mode' must be one of: fast, slow."])
    }

    @Test("array items are checked and reported with their position")
    func arrayItems() {
        #expect(problems(["name": "x", "tags": ["ok", "toolong"]]) == ["Argument 'tags[1]' must be at most 3 characters long."])
        #expect(problems(["name": "x", "tags": ["ok", 5]]) == ["Argument 'tags[1]' must be a string."])
    }

    @Test("nested objects are checked too")
    func nested() {
        let nested = Schema.object(["inner": Schema.object(["x": Schema.integer("x")], required: ["x"])], required: ["inner"])
        #expect(InputValidator.validate(["inner": [:]], against: nested) == ["Missing required argument 'inner.x'."])
        #expect(InputValidator.validate(["inner": ["x": 1, "y": 2]], against: nested).first?.contains("Unexpected argument 'y'") == true)
    }

    @Test("a tool with no parameters rejects any argument")
    func noArguments() {
        let empty = Schema.object([:])
        #expect(InputValidator.validate([:], against: empty).isEmpty)
        #expect(InputValidator.validate(["x": 1], against: empty) == ["Unexpected argument 'x'. This tool takes no arguments."])
    }

    @Test("the input must be an object")
    func notAnObject() {
        #expect(problems("just text") == ["The arguments must be an object."])
        #expect(problems([1, 2]) == ["The arguments must be an object."])
    }

    @Test("a runaway argument is refused before anything reads it")
    func tooLarge() {
        let huge = JSONValue.object(["name": .string(String(repeating: "a", count: InputValidator.maxInputBytes + 1))])
        #expect(problems(huge).first?.contains("too large") == true)
    }

    @Test("a schema without additionalProperties: false doesn't forbid extras")
    func permissive() {
        let loose: JSONValue = ["type": "object", "properties": ["a": ["type": "string"]]]
        #expect(InputValidator.validate(["a": "x", "b": 1], against: loose).isEmpty)
    }
}
