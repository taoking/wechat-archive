import SwiftUI
import WeChatArchiveCore

/// A compact quote preview for the already-safe Core presentation model.
/// Raw archive text is never parsed or rendered in this view.
struct ArchiveQuotePresentationView: View {
    let quote: ArchiveQuotedMessagePresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.secondary.opacity(0.65))
                    .frame(width: 3)
                Text("\(quote.quotedSender) · \(quote.quotedSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !quote.replyText.isEmpty {
                Text(quote.replyText).textSelection(.enabled)
            }
        }
    }
}
