/// The recent replies that share one measured row with the end of a lazy conversation.
public enum ConversationTail {
    /// Keep the two latest turns with a response, their prompts/work folds, and anything newer together. The previous
    /// response stays measured when a live draft becomes a recorded reply. Empty/unanswered histories retain only
    /// their last turn (or last block when no turn boundary is available).
    public static func startIndex(in blocks: [ConversationBlock]) -> Int {
        guard !blocks.isEmpty else { return blocks.endIndex }
        var responseTurns = 0
        var hasResponse = false
        var responseStart: Int?
        var lastTurnStart: Int?
        for index in blocks.indices.reversed() {
            guard case .item(let item) = blocks[index] else { continue }
            switch item.type {
            case .text:
                hasResponse = true
            case .command, .report:
                hasResponse = true
            default:
                break
            }
            guard item.type == .user || item.type == .command || item.type == .report else { continue }
            if lastTurnStart == nil { lastTurnStart = index }
            if hasResponse {
                responseStart = index
                responseTurns += 1
                if responseTurns == 2 { return index }
            }
            hasResponse = false
        }
        // A truncated page can begin in the middle of a response, before its prompt is available.
        if hasResponse { return blocks.startIndex }
        return responseStart ?? lastTurnStart ?? blocks.index(before: blocks.endIndex)
    }
}
