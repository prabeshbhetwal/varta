import SwiftUI

struct TranslationTabView: View {
    @ObservedObject var viewModel: MeetingDetailViewModel

    var body: some View {
        ContentUnavailableView("Translation Deferred", systemImage: "hourglass")
            .padding(24)
    }
}
