import Testing

@testable import QooKit

@Test func moduleNameIsQooKit() {
    #expect(QooKit.moduleName == "QooKit")
}
