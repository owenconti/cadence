@main
enum CarPlayPageChecks {
    static func main() {
        for count in [0, 1, 9, 10, 11, 19, 20, 21, 50, 80, 1_001] {
            var visited: [Int] = []
            var pages: [CarPlaySongPage] = []
            var number = 0
            while true {
                let page = CarPlaySongPage(count: count, number: number)
                precondition(page.rowCount <= 12)
                precondition(page.range.count <= 10)
                precondition(page.previous == (number == 0 ? nil : number - 1))
                visited += page.range
                pages.append(page)
                guard let next = page.next else { break }
                number = next
            }
            precondition(visited == Array(0..<count), "Skipped or duplicated songs: \(count)")
            var reverse: [Int] = []
            while true {
                let page = CarPlaySongPage(count: count, number: number)
                reverse += page.range.reversed()
                guard let previous = page.previous else { break }
                number = previous
            }
            precondition(reverse == Array((0..<count).reversed()))
            precondition(CarPlaySongPage(count: count, number: -1).number == 0)
            precondition(CarPlaySongPage(count: count, number: Int.max).number == pages.last!.number)
            if count == 0 { precondition(pages[0].rowCount == 0) }
            if count == 10 { precondition(pages.count == 1 && pages[0].rowCount == 10) }
            if count == 20 { precondition(pages.count == 2 && pages[1].next == nil) }
            if count == 21 { precondition(pages[1].rowCount == 12 && pages[2].range == 20..<21) }
        }
        let largest = CarPlaySongPage(count: Int.max, number: Int.max)
        precondition(largest.range.upperBound == Int.max && largest.next == nil && largest.rowCount <= 12)
        precondition(CarPlaySongPage(count: -1, number: 0).rowCount == 0)
        print("PASS CarPlay pages: empty, exact-ten, first/middle/last, forward/backward, no gaps or duplicates, <=12 rows")
    }
}
