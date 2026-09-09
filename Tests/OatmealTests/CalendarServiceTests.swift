import XCTest
@testable import Oatmeal

final class CalendarServiceTests: XCTestCase {
    @MainActor func testOnlyProviderDomainsAndTheirSubdomainsAreAccepted() async {
        for url in ["https://teams.microsoft.com.example.org/meeting", "https://evilteams.live.com/call",
                    "https://notzoom.us/j/123", "https://notwebex.com/meeting",
                    "http://teams.microsoft.com/meeting", "https://teams.microsoft.com@evil.example.org/"] {
            XCTAssertNil(CalendarService.detectCall(in: [url]).0, url)
        }
        for (url, provider) in [("https://teams.microsoft.com/l/meetup-join/test", "Teams"),
                                ("https://teams.live.com/meet/123", "Teams"),
                                ("https://us02web.zoom.us/j/123", "Zoom"),
                                ("https://company.webex.com/meeting", "Webex"),
                                ("https://meet.google.com/abc-defg-hij", "Meet")] {
            XCTAssertEqual(CalendarService.detectCall(in: [url]).1, provider)
        }
    }
}
