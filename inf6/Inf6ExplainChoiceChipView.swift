import SwiftUI

struct Inf6ExplainChoiceChipView: View {
    let title: String
    let systemImage: String
    let tint: Color
    let selected: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        let chipShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((enabled ? tint : Color.secondary).opacity(selected ? 0.18 : 0.12))
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: systemImage)
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(13), weight: .semibold))
                        .foregroundStyle(enabled ? tint : Color.secondary)
                }

            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(16), weight: .semibold))
                .foregroundStyle(selected ? tint : Color.secondary.opacity(0.5))
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(12)
        .background(
            chipShape.fill(
                selected
                    ? tint.opacity(0.12)
                    : Color.secondary.opacity(enabled ? 0.06 : 0.04)
            )
        )
        .overlay {
            chipShape.stroke(
                selected
                    ? tint.opacity(0.38)
                    : Color.secondary.opacity(enabled ? 0.12 : 0.08),
                lineWidth: selected ? 1.5 : 1
            )
        }
        .opacity(enabled ? 1.0 : 0.52)
        .contentShape(chipShape)
        .onTapGesture {
            guard enabled else { return }
            action()
        }
        .accessibilityAddTraits(.isButton)
    }
}

extension InlinePDFPagesView {
    typealias _ExplainChoiceChipView = Inf6ExplainChoiceChipView
}
