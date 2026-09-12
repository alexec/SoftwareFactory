import ActivityKit
import SwiftUI
import WidgetKit

@main
struct FactoryWidgetBundle: WidgetBundle {
    var body: some Widget {
        FactoryActivityWidget()
    }
}

/// The question on the Lock Screen and in the Dynamic Island, with its options as buttons.
struct FactoryActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FactoryActivityAttributes.self) { context in
            // The Lock Screen gives an activity 160 points, so everything here is tight.
            LockScreenQuestion(state: context.state)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .activityBackgroundTint(Color.orange.opacity(0.12))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "questionmark.bubble")
                        .foregroundStyle(.orange)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.project)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LockScreenQuestion(state: context.state, compact: true)
                }
            } compactLeading: {
                Image(systemName: "questionmark.bubble")
                    .foregroundStyle(.orange)
            } compactTrailing: {
                Text(context.state.open, format: .number)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "questionmark.bubble")
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct LockScreenQuestion: View {
    var state: FactoryActivityAttributes.ContentState
    var compact = false

    private var shown: [FactoryActivityAttributes.ContentState.Option] { Array(state.options.prefix(3)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !compact {
                HStack(spacing: 6) {
                    Text(state.project)
                        .font(.caption.weight(.semibold))
                    Text("· \(state.raisedBy) asks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if state.open > 1 {
                        Text("\(state.open - 1) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            }
            Text(state.question)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            if !compact, !state.context.isEmpty, shown.count < 3 {
                Text(state.context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            VStack(spacing: 4) {
                ForEach(shown) { option in
                    Button(intent: DecideIntent(escalationID: state.escalationID, optionID: option.id)) {
                        HStack(spacing: 8) {
                            Text(option.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            if option.recommended {
                                Text("Recommended")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.tint.opacity(0.18), in: .capsule)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                        .padding(.horizontal, 10)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 8))
                }
            }
        }
    }
}
