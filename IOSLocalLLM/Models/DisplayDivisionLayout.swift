import CoreGraphics

/// Keeps a control group in one uninterrupted horizontal region. Coordinates
/// come from the group's container, never from a device or predicted fold size.
struct DisplayDivisionInsets: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0

    static func resolve(in bounds: CGRect, avoiding divisions: [CGRect]) -> Self {
        guard bounds.width > 0, bounds.height > 0 else { return Self() }
        var intervals = [bounds.minX...bounds.maxX]
        for division in divisions {
            let overlap = bounds.intersection(division)
            // A horizontal fold needs vertical layout, not horizontal padding.
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0,
                  overlap.width < bounds.width else { continue }
            intervals = intervals.flatMap { interval -> [ClosedRange<CGFloat>] in
                guard overlap.minX < interval.upperBound,
                      overlap.maxX > interval.lowerBound else { return [interval] }
                var remaining: [ClosedRange<CGFloat>] = []
                if overlap.minX > interval.lowerBound {
                    remaining.append(interval.lowerBound...overlap.minX)
                }
                if overlap.maxX < interval.upperBound {
                    remaining.append(overlap.maxX...interval.upperBound)
                }
                return remaining
            }
        }
        guard let widest = intervals.max(by: {
            $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound
        }) else { return Self() }
        return Self(leading: widest.lowerBound - bounds.minX,
                    trailing: bounds.maxX - widest.upperBound)
    }
}
