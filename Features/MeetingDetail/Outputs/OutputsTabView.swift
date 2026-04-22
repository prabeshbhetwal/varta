import SwiftUI

struct OutputsTabView: View {
    @ObservedObject var viewModel: MeetingDetailViewModel

    var body: some View {
        ContentUnavailableView("Outputs Deferred", systemImage: "hourglass")
            .padding(24)
    }
}
