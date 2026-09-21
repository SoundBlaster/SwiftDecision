import SwiftDecision

private enum InboxLabel: String, Sendable, Hashable {
    case urgent
    case later
    case ignore
}

@main
private struct InboxTriageExample {
    static func main() async throws {
        let backend = ClosureDecisionBackend { prompt in
            switch prompt.id {
            case "route":
                DecisionPrediction(probabilities: [0.94, 0.04, 0.02], modelIdentifier: "offline-demo")
            case "urgent":
                DecisionPrediction(probabilities: [0.03, 0.97], modelIdentifier: "offline-demo")
            default:
                DecisionPrediction(probabilities: [0.05, 0.90, 0.05], modelIdentifier: "offline-demo")
            }
        }
        let engine = DecisionEngine(backend: backend)
        let email = "Production is down for all customers. Please help immediately."

        let route = try await engine.choice(
            id: "route",
            instructions: "Choose the best inbox action.",
            context: email,
            options: [
                ChoiceOption<InboxLabel>(label: .urgent, description: "urgent: reply immediately"),
                ChoiceOption<InboxLabel>(label: .later, description: "later: respond when available"),
                ChoiceOption<InboxLabel>(label: .ignore, description: "ignore: no response is needed")
            ],
            fallback: .later
        )

        switch route.outcome {
        case let .accepted(label): print("Inbox action: \(label.rawValue)")
        case let .fallback(label, _): print("Fallback action: \(label.rawValue)")
        case let .abstained(reason): print("Manual review needed: \(reason)")
        }

        let isUrgent = try await engine.noul(
            id: "urgent",
            statement: "Does this message require immediate action?",
            context: email
        )
        print("Urgent: \(isUrgent.value ?? false), confidence: \(isUrgent.confidence)")
    }
}
