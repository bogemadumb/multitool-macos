import Testing
import Foundation

func check(_ cond: Bool, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(cond, Comment(rawValue: name), sourceLocation: sourceLocation)
}
