import AppIntents

struct EvaluateFormulaIntent: AppIntent {
    static let title: LocalizedStringResource = "数式を計算"
    static let description = IntentDescription("入力された算術式を評価します。")
    static let openAppWhenRun = false

    @Parameter(title: "数式")
    var expression: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try NumericExpressionEvaluator.evaluate(expression)
        return .result(value: "= \(result)")
    }
}

struct ArcaneDerivationShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
            AppShortcut(
                intent: EvaluateFormulaIntent(),
                phrases: ["数式を計算して in \(.applicationName)"],
                shortTitle: "数式を計算",
                systemImageName: "function"
            )
    }
}
