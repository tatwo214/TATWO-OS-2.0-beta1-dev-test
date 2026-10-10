import Foundation

enum GroupFastModel {
    /// TAP already exposes Instant/Light/etc. through model labels and effort.level.
    static func choose(_ models: [TapModel]) -> (model: TapModel, effort: String?)? {
        let tiers = ["instant|即時|立即|快速|\\bfast\\b|\\bquick\\b", "light|輕量|\\blow\\b|\\bmin(imal)?\\b", "standard|medium|標準|中等", "high|extended|延長", "extra.?high|xhigh|\\bmax\\b|heavy|深入|最高", "pro|專業"]
        func rank(_ text: String) -> Int {
            if text.range(of: tiers[4], options: [.regularExpression, .caseInsensitive]) != nil { return 4 }
            return tiers.firstIndex { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil } ?? tiers.count
        }
        let candidates = models.filter(ChatGPTTapModelCatalog.isCoderModel).flatMap { model in
            model.efforts.isEmpty ? [(model, Optional<String>.none, rank(model.id + " " + model.title + " " + model.detail))]
                : model.efforts.map { (model, Optional($0.id), rank($0.id + " " + $0.title + " " + $0.level + " " + $0.detail)) }
        }
        guard let best = candidates.min(by: { $0.2 < $1.2 }), best.2 < tiers.count || candidates.count == 1 else { return nil }
        return (best.0, best.1)
    }
}
