import MarkdownUI
import SwiftUI
import XCTest
@testable import ShedKit

final class ThemeRenderTests: XCTestCase {
    /// The agent theme's closures are bound to the main actor. Rendering every kind of block runs each of them the
    /// way MarkdownUI really calls them, so a call from anywhere else would stop the test here.
    @MainActor func testEveryBlockOfTheAgentThemeRenders() {
        let text = """
        # One
        ## Two
        ### Three
        Prose with `code`, **strong**, *emphasis*, ~~struck~~ and [a link](https://example.com).

        > A quote.

        - a list
          - nested
        1. numbered
        - [x] done

        ```swift
        let x = 1
        ```

        | a | b |
        |---|---|
        | 1 | 2 |

        ---
        """
        let renderer = ImageRenderer(content: Markdown(text).markdownTheme(.agent).frame(width: 400))
        let image = renderer.cgImage
        XCTAssertNotNil(image)
        XCTAssertGreaterThan(image?.height ?? 0, 200)
    }
}
