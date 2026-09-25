import SwiftUI
import VikingBarCore

struct HomeUsageCard: View {
    let usage: HomeUsagePresentation
    let card: HomeUsageCardPresentation
    @Binding var detailsExpanded: Bool
    let warning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            self.quota
            Label(self.card.period, systemImage: "calendar")
                .font(.caption)
                .accessibilityLabel(self.usage.periodText)
                .accessibilityIdentifier("vikingbar.home.period")
            Divider()
            self.traffic
            Divider()
            self.details
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("vikingbar.warning")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var quota: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(self.card.headline)
                    .font(.system(size: 34, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .accessibilityLabel("\(self.card.headline) \(self.card.headlineLabel)")
                    .accessibilityIdentifier("vikingbar.home.headline")
                Spacer(minLength: 4)
                Text(self.card.allocation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(self.usage.allocationText)
                    .accessibilityIdentifier("vikingbar.home.allocation")
            }
            HStack(spacing: 7) {
                Text(self.card.headlineLabel).foregroundStyle(.secondary)
                Text(self.card.category)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel(self.usage.categoryText)
                    .accessibilityIdentifier("vikingbar.home.category")
            }
            .font(.caption)
            if let fraction = self.card.quotaFraction, let quotaText = self.card.quotaText {
                self.bar(fraction: fraction, color: .cyan)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(self.card.headlineLabel), \(quotaText)")
                    .accessibilityValue(quotaText)
                    .accessibilityIdentifier("vikingbar.home.quota-progress")
            }
            HStack(alignment: .firstTextBaseline) {
                Text("\(self.card.policyCounter) policy counter")
                    .accessibilityLabel(self.usage.policyCounterText)
                    .accessibilityIdentifier("vikingbar.home.policy-counter")
                Spacer(minLength: 6)
                if let quotaText = self.card.quotaText {
                    Text(quotaText)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let overage = self.card.overage {
                Text(overage).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var traffic: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Downloaded").font(.caption).foregroundStyle(.secondary)
            Text(self.card.downloaded)
                .font(.system(size: 28, weight: .semibold))
                .accessibilityLabel(self.usage.downloadedText)
                .accessibilityIdentifier("vikingbar.home.downloaded")
            if let peakFraction = self.card.peakFraction, let trafficPercentage = self.card.trafficPercentage {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        Color.cyan.frame(width: geometry.size.width * peakFraction)
                        Color.blue
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Downloaded traffic, \(trafficPercentage)")
                .accessibilityValue(trafficPercentage)
                .accessibilityIdentifier("vikingbar.home.traffic-progress")
            }
            HStack {
                Label {
                    Text(self.card.peak)
                } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(.cyan)
                }
                .accessibilityLabel(self.usage.peakText)
                .accessibilityIdentifier("vikingbar.home.peak")
                Spacer(minLength: 6)
                Label {
                    Text(self.card.offPeak)
                } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(.blue)
                }
                .accessibilityLabel(self.usage.offPeakText)
                .accessibilityIdentifier("vikingbar.home.off-peak")
            }
            .font(.caption)
            Text(self.card.speed)
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel(self.usage.speedText)
                .accessibilityIdentifier("vikingbar.home.speed")
        }
    }

    private var details: some View {
        DisclosureGroup(isExpanded: self.$detailsExpanded) {
            VStack(alignment: .leading, spacing: 5) {
                Text(self.usage.providerUpdatedText)
                    .accessibilityIdentifier("vikingbar.home.provider-updated")
                Text(self.usage.fetchedText)
                    .accessibilityIdentifier("vikingbar.home.fetched")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Text("Usage details")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vikingbar.home.details")
    }

    private func bar(fraction: Double, color: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(color).frame(width: geometry.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: 8)
    }
}
