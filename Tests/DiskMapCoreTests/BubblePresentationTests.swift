import Testing
@testable import DiskMapCore

@Test func bubblePresentationFitsEveryViewportAndReservesLabelSpace() {
    let child = ChartSlice(id: "child", nodeID: 1, size: 100, label: "Child", drillable: false, children: [])
    let parent = ChartSlice(id: "parent", nodeID: 0, size: 100, label: "Parent", drillable: true, children: [child])
    let packed = CirclePack.pack([parent])
    for (width, height) in [(320.0, 180.0), (800, 600), (1500, 400), (300, 900)] {
        let fitted = BubblePresentation.fit(packed, slices: [parent], width: width, height: height)
        #expect(fitted.count == 2)
        for circle in fitted {
            #expect(circle.x - circle.radius >= 9.99)
            #expect(circle.y - circle.radius >= 9.99)
            #expect(circle.x + circle.radius <= width - 9.99)
            #expect(circle.y + circle.radius <= height - 9.99)
        }
        let outer = fitted[0], inner = fitted[1]
        #expect(inner.y - inner.radius > outer.y - outer.radius * 0.6)
        #expect(inner.radius < outer.radius)
    }
    #expect(BubblePresentation.fit(packed, slices: [parent], width: 12, height: 12).isEmpty)
}
