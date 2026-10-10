import SwiftUI

struct UsageBar: View {
    @AppStorage(Kota.showsUsedKey, store: Kota.defaults) private var showsUsed = false
    let window: UsageWindow
    var showsReset = true
    var compact = false

    var body: some View {
        let percent = self.showsUsed ? self.window.percentUsed : self.window.percentLeft
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(self.window.title)
                Spacer()
                Text("\(Int(percent.rounded()))% \(self.showsUsed ? "used" : "left")").monospacedDigit()
            }
            .font(self.compact ? .caption2 : .caption)
            .lineLimit(1)
            ProgressView(value: percent, total: 100)
                .tint(self.window.percentLeft < 20 ? .red : .accentColor)
            if self.showsReset, let resetsAt = self.window.resetsAt {
                Text("Resets in \(resetsAt, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
