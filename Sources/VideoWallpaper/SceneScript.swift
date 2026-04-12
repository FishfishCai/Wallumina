import Foundation
import JavaScriptCore

/// Evaluates WE SceneScript property formulas via JavaScriptCore
@MainActor
final class SceneScriptEngine {
    private let context: JSContext

    init() {
        context = JSContext()!
        // Add console.log
        let log: @convention(block) (String) -> Void = { msg in
            fputs("[VW-SCRIPT] \(msg)\n", stderr)
        }
        context.setObject(log, forKeyedSubscript: "log" as NSString)
        context.evaluateScript("var console = { log: log, warn: log, error: log };")

        // Add basic WE math utilities
        context.evaluateScript("""
        var WEMath = {
            lerp: function(a, b, t) { return a + (b - a) * t; },
            clamp: function(v, min, max) { return Math.max(min, Math.min(max, v)); }
        };
        """)
    }

    /// Evaluate a property formula expression
    func evaluate(_ expression: String, properties: [String: Any] = [:]) -> Any? {
        // Set property values in context
        for (key, value) in properties {
            context.setObject(value, forKeyedSubscript: key as NSString)
        }
        return context.evaluateScript(expression)?.toObject()
    }

    /// Evaluate a ScriptedDynamicValue update function
    func evaluateUpdate(_ script: String, value: Double) -> Double? {
        // WE ScriptedDynamicValues are IIFE modules that export { update(value) }
        let wrappedScript = """
        (function() {
            \(script)
            if (typeof update === 'function') return update(\(value));
            return \(value);
        })();
        """
        return context.evaluateScript(wrappedScript)?.toDouble()
    }
}
