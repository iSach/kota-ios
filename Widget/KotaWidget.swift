import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot
}

struct UsageTimelineProvider: TimelineProvider {
    func placeholder(in _: Context) -> UsageEntry {
        UsageEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: .now, snapshot: context.isPreview ? .placeholder : .cached))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        Task {
            // A widget that takes too long to answer gets no entry at all and renders blank,
            // so fall back to the last saved snapshot after a few seconds.
            let snapshot = await withTaskGroup(of: Snapshot.self) { group in
                group.addTask { await UsageFetcher.fetchAll() }
                group.addTask {
                    try? await Task.sleep(for: .seconds(8))
                    return .cached
                }
                let first = await group.next() ?? .cached
                group.cancelAll()
                return first
            }
            // iOS budgets widget reloads; 15 minutes is a request, not a guarantee.
            completion(Timeline(
                entries: [UsageEntry(date: .now, snapshot: snapshot)],
                policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }
}

struct KotaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        // Small 1, medium 2, large up to 6 (three rows of two).
        let limit = switch self.family {
        case .systemSmall: 1
        case .systemMedium: 2
        default: 6
        }
        let providers = Array(self.entry.snapshot.providers.prefix(limit))
        if providers.isEmpty {
            Text("Open Kota to add an account").font(.caption).foregroundStyle(.secondary)
        } else {
            let columns = min(2, limit)
            let dense = providers.count > 4
            VStack(alignment: .leading, spacing: 6) {
                // Plain Grid: lazy grids don't lay out reliably inside widgets.
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: dense ? 8 : 12) {
                    ForEach(Array(stride(from: 0, to: providers.count, by: columns)), id: \.self) { start in
                        GridRow {
                            ForEach(providers[start..<min(start + columns, providers.count)]) { provider in
                                self.cell(provider, dense: dense)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                Text(self.entry.snapshot.date, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func cell(_ provider: ProviderUsage, dense: Bool) -> some View {
        VStack(alignment: .leading, spacing: dense ? 3 : 6) {
            HStack {
                Text(provider.name).font(dense ? .subheadline.bold() : .headline).lineLimit(1)
                if provider.error != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            ForEach(provider.windows.prefix(3), id: \.self) {
                UsageBar(window: $0, showsReset: false, compact: dense)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@main
struct KotaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KotaWidget", provider: UsageTimelineProvider()) { entry in
            KotaWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Kota")
        .description("Usage limits for your accounts, in the order set in Kota.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
