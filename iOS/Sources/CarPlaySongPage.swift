/// Page arithmetic is independent of CarPlay's connected vehicle and UI.
/// Two navigation rows plus ten songs fit the conservative 12-row budget.
struct CarPlaySongPage {
    static let size = 10
    let number: Int
    let range: Range<Int>
    let previous: Int?
    let next: Int?

    init(count: Int, number: Int) {
        let count = max(0, count)
        let last = count == 0 ? 0 : (count - 1) / Self.size
        self.number = min(max(0, number), last)
        let start = self.number * Self.size
        range = start..<(start + min(Self.size, count - start))
        previous = self.number > 0 ? self.number - 1 : nil
        next = self.number < last ? self.number + 1 : nil
    }

    var rowCount: Int { range.count + (previous == nil ? 0 : 1) + (next == nil ? 0 : 1) }
}
