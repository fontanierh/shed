// The widget extension that draws Shed's Live Activity on the Lock Screen and in the Dynamic Island.
import AgentRemoteKit
import SwiftUI
import WidgetKit

@main
struct ShedLive: WidgetBundle {
    var body: some Widget {
        ShedLiveActivityWidget()
    }
}
