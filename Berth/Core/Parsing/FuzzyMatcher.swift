import Foundation

/// ⌘K 模糊搜索打分:前缀 > 包含 > 子序列;不匹配返回 nil。
enum FuzzyMatcher {

    static func score(query: String, candidate: String) -> Int? {
        let query = query.lowercased()
        let candidate = candidate.lowercased()
        guard !query.isEmpty else { return 0 }
        guard !candidate.isEmpty else { return nil }

        if candidate == query { return 2000 }
        if candidate.hasPrefix(query) { return 1500 - candidate.count }
        if candidate.contains(query) { return 1000 - candidate.count }

        // 子序列:字符按序全部出现,间隙越小分越高
        var gaps = 0
        var searchIndex = candidate.startIndex
        var previousMatch: String.Index?
        for character in query {
            guard let found = candidate[searchIndex...].firstIndex(of: character) else { return nil }
            if let previous = previousMatch {
                gaps += candidate.distance(from: previous, to: found) - 1
            }
            previousMatch = found
            searchIndex = candidate.index(after: found)
        }
        return 500 - gaps * 10 - candidate.count
    }

    /// 多字段取最高分
    static func bestScore(query: String, fields: [String?]) -> Int? {
        fields
            .compactMap { $0 }
            .compactMap { score(query: query, candidate: $0) }
            .max()
    }
}
