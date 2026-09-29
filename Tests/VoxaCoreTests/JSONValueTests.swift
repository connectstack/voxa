import Foundation
import Testing
@testable import VoxaCore

@Suite("JSONValue")
struct JSONValueTests {
    @Test("every JSON type round-trips through text")
    func roundTrip() throws {
        let value: JSONValue = [
            "name": "Voxa",
            "count": 3,
            "ratio": 0.5,
            "on": true,
            "nothing": nil,
            "list": [1, "two", false, nil],
            "nested": ["deep": ["deeper": "ok"]],
        ]
        let text = value.serialized()
        #expect(try JSONValue.parse(text) == value)
    }

    @Test("integers stay integers and fractions stay fractions")
    func numbers() throws {
        let parsed = try JSONValue.parse(#"{"a": 5, "b": 5.5, "c": 5.0, "big": 12345678901234}"#)
        #expect(parsed["a"] == .int(5))
        #expect(parsed["b"] == .double(5.5))
        #expect(parsed["a"]?.intValue == 5)
        #expect(parsed["c"]?.intValue == 5, "a whole-number double is readable as an int")
        #expect(parsed["b"]?.intValue == nil, "a fraction is not")
        #expect(parsed["big"]?.intValue == 12_345_678_901_234)
    }

    @Test("serialization is deterministic: keys are sorted and slashes stay unescaped")
    func deterministic() {
        let value: JSONValue = ["b": 1, "a": "https://example.com/x", "c": [2, 1]]
        #expect(value.serialized() == #"{"a":"https://example.com/x","b":1,"c":[2,1]}"#)
    }

    @Test("unicode and escapes survive")
    func unicode() throws {
        let original = "café ⌥Space 😀 \"quoted\" \\ back\nline"
        let parsed = try JSONValue.parse(JSONValue.string(original).serialized())
        #expect(parsed.stringValue == original)
    }

    @Test("invalid JSON is rejected, including trailing garbage", arguments: [
        "", "{", "{\"a\":}", "[1,2,", "{\"a\":1} extra", "nope", "{'a':1}",
    ])
    func invalid(text: String) {
        #expect(throws: (any Error).self) { try JSONValue.parse(text) }
    }

    @Test("typed accessors return nil for the wrong type instead of trapping")
    func accessors() {
        let value: JSONValue = ["s": "x", "n": 1, "b": true, "a": [1], "o": ["k": 1]]
        #expect(value["s"]?.stringValue == "x")
        #expect(value["s"]?.intValue == nil)
        #expect(value["n"]?.stringValue == nil)
        #expect(value["b"]?.boolValue == true)
        #expect(value["a"]?.arrayValue?.count == 1)
        #expect(value["o"]?["k"] == .int(1))
        #expect(value["missing"] == nil)
        #expect(JSONValue.null.isNull)
        #expect(JSONValue.string("x")["k"] == nil)
    }
}

@Suite("Schema")
struct SchemaTests {
    @Test("an object schema forbids extra properties and lists what is required")
    func objectSchema() {
        let schema = Schema.object(
            ["name": Schema.string("The app"), "count": Schema.integer("How many", minimum: 1, maximum: 5)],
            required: ["name"]
        )
        #expect(schema["type"] == "object")
        #expect(schema["additionalProperties"] == false)
        #expect(schema["required"] == ["name"])
        #expect(schema["properties"]?["count"]?["maximum"] == 5)
        #expect(schema["properties"]?["name"]?["description"] == "The app")
    }

    @Test("enums and lengths are expressed in the schema")
    func constraints() {
        let field = Schema.string("Mode", enum: ["a", "b"], minLength: 1, maxLength: 9)
        #expect(field["enum"] == ["a", "b"])
        #expect(field["minLength"] == 1)
        #expect(field["maxLength"] == 9)
    }
}
