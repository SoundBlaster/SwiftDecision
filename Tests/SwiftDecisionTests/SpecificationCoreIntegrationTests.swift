import SpecificationCore
import XCTest

final class SpecificationCoreIntegrationTests: XCTestCase {
    func testPackageCanEvaluateCoreAsyncSpecification() async throws {
        let specification = AnyAsyncSpecification<Int> { $0 > 0 }
        let isSatisfied = try await specification.isSatisfiedBy(1)

        XCTAssertTrue(isSatisfied)
    }

    func testPackageCanComposeCoreAsyncSpecificationsIntoDecision() async throws {
        let positive = AnyAsyncSpecification<Int> { $0 > 0 }
        let even = AnyAsyncSpecification<Int> { $0.isMultiple(of: 2) }
        let decision = positive.andAsync(even).returningAsync("accepted")
        let accepted = try await decision.decide(4)
        let rejected = try await decision.decide(3)

        XCTAssertEqual(accepted, "accepted")
        XCTAssertNil(rejected)
    }

    func testPackageCanBuildCoreAsyncFirstMatchDecision() async throws {
        let decision = AsyncFirstMatchSpec<Int, String>.builder()
            .addPredicate({ $0 > 0 }, result: "positive")
            .fallback("other")
            .build()
        let positive = try await decision.decide(1)
        let fallback = try await decision.decide(-1)

        XCTAssertEqual(positive, "positive")
        XCTAssertEqual(fallback, "other")
    }
}
