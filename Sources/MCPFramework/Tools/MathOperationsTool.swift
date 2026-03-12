// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConfigurationSystem

/// Simple error type for math operation failures.
private struct MathError: Error {
    let message: String
}

/// MCP tool for reliable mathematical calculations, unit conversions, and common formulas.
/// Uses python3 subprocess for computation to avoid LLM math hallucination.
public class MathOperationsTool: ConsolidatedMCP, @unchecked Sendable {
    public let name = "math_operations"
    public let description = """
    Mathematical calculations, unit conversions, and formulas.

    IMPORTANT: ALWAYS use this tool for ANY mathematical computation. NEVER perform math mentally.
    Even simple arithmetic (2+2) should go through this tool for accuracy.

    OPERATIONS:
    • calculate - Evaluate any mathematical expression (arithmetic, algebra, trigonometry, statistics)
    • compute - Run Python code for complex multi-step calculations. Use this when no formula fits your needs. Write Python that prints results. Has access to math, statistics, itertools, decimal, fractions, collections, datetime, json, csv, re, and io modules.
    • convert - Unit conversions (length, weight, temperature, volume, area, speed, data, time)
    • formula - Named formulas with parameters (see list below)

    FORMULAS (Everyday):
    • tip - Calculate tip and split (bill, tip_percent, split)
    • sales_tax - Tax calculator (price, tax_rate, quantity)
    • discount - Discount price (original_price, discount_percent)
    • fuel_cost / gas_cost / trip_cost - Fuel cost (distance, mpg, price_per_gallon)
    • cooking / recipe_scale - Scale recipe (original_servings, target_servings, amounts)
    • grade / gpa - Grade calculator (scores array, optional: weights, total)
    • bmi - Body Mass Index (weight_lbs, height_inches OR weight_kg, height_m)
    • speed_distance_time - Solve for missing variable (provide any 2 of 3)

    FORMULAS (Financial Planning):
    • retirement / retirement_savings - Retirement projection (current_age, retire_age, current_savings, monthly_contribution, annual_return, withdrawal_rate)
    • debt_payoff / debt_snowball - Single debt payoff timeline (balance, rate, monthly_payment, extra_payment)
    • debt_strategy / multi_debt - Multi-debt payoff strategy (debts array, monthly_budget, optional lump_sum) - returns BOTH avalanche AND snowball comparison in a single call. Shows payment priority (where extra money goes) AND elimination timeline (when each debt reaches $0) separately. Only needs: debts (array of {name, balance, rate, minimum_payment}), monthly_budget, and optionally lump_sum (one-time extra payment). Do NOT call multiple times for different strategies.
    • budget / fifty_thirty_twenty - 50/30/20 budget analysis (monthly_income, needs, wants, savings)
    • loan_comparison / compare_loans - Compare loan options (principal, rates array, terms array)
    • savings_goal - Time/amount to reach a goal (goal, current_savings, monthly_contribution, months)
    • net_worth - Net worth calculator (home_value, investments, cash, vehicles, mortgage, student_loans, etc.)
    • paycheck / take_home / salary - Paycheck estimator (annual_salary, pay_frequency, filing_status, state_tax_rate)
    • inflation / future_value - Inflation impact over time (amount, years, inflation_rate)

    FORMULAS (Math/Science):
    • mortgage / loan_payment - Monthly payment (principal, rate, years)
    • compound_interest - Compound interest (principal, rate, years, compounds_per_year)
    • percentage - Percentage of value (value, percentage)
    • markup - Markup/margin (cost, markup_percent)
    • area_circle, area_rectangle, volume_cylinder - Geometry

    EXAMPLES:
    {"operation": "calculate", "expression": "sqrt(144) + 3**2"}
    {"operation": "compute", "code": "# Calculate compound growth with monthly contributions\\nmonthly = 500\\nrate = 0.07\\nbalance = 10000\\nfor year in range(1, 11):\\n    balance = balance * (1 + rate) + monthly * 12\\n    print(f'Year {year}: ${balance:,.2f}')"}
    {"operation": "convert", "value": 72, "from": "fahrenheit", "to": "celsius"}
    {"operation": "formula", "formula": "tip", "parameters": {"bill": 85.50, "tip_percent": 20, "split": 3}}
    {"operation": "formula", "formula": "retirement", "parameters": {"current_age": 35, "retire_age": 65, "current_savings": 50000, "monthly_contribution": 1000}}
    {"operation": "formula", "formula": "debt_payoff", "parameters": {"balance": 15000, "rate": 22.99, "monthly_payment": 400}}
    {"operation": "formula", "formula": "debt_strategy", "parameters": {"debts": [{"name": "Visa", "balance": 5000, "rate": 22.99, "minimum_payment": 100}, {"name": "Amex", "balance": 8000, "rate": 18.99, "minimum_payment": 150}], "monthly_budget": 500, "lump_sum": 3000}}
    {"operation": "formula", "formula": "budget", "parameters": {"monthly_income": 5500, "needs": 2800, "wants": 1200, "savings": 800}}
    {"operation": "formula", "formula": "paycheck", "parameters": {"annual_salary": 85000, "filing_status": "married", "state_tax_rate": 5.75}}
    {"operation": "formula", "formula": "loan_comparison", "parameters": {"principal": 350000, "rates": [6.0, 6.5, 7.0], "terms": [15, 30]}}
    {"operation": "formula", "formula": "savings_goal", "parameters": {"goal": 25000, "current_savings": 5000, "monthly_contribution": 800}}
    """

    public var supportedOperations: [String] {
        ["calculate", "compute", "convert", "formula"]
    }

    public var parameters: [String: MCPToolParameter] {
        [
            "operation": MCPToolParameter(
                type: .string,
                description: "Operation to perform: calculate, compute, convert, or formula",
                required: true,
                enumValues: ["calculate", "compute", "convert", "formula"]
            ),
            "expression": MCPToolParameter(
                type: .string,
                description: "Mathematical expression to evaluate (for calculate operation). Supports Python math syntax: +, -, *, /, **, sqrt(), sin(), cos(), log(), sum(), round(), abs(), etc.",
                required: false
            ),
            "code": MCPToolParameter(
                type: .string,
                description: "Python code for complex calculations (for compute operation). Write complete Python code that uses print() to output results. Available: math, statistics, itertools, decimal, fractions, collections, datetime. Max 100 lines, 10-second timeout.",
                required: false
            ),
            "value": MCPToolParameter(
                type: .string,
                description: "Numeric value to convert (for convert operation). Accepts numbers as strings.",
                required: false
            ),
            "from": MCPToolParameter(
                type: .string,
                description: "Source unit (for convert operation)",
                required: false
            ),
            "to": MCPToolParameter(
                type: .string,
                description: "Target unit (for convert operation)",
                required: false
            ),
            "formula": MCPToolParameter(
                type: .string,
                description: "Named formula to use (for formula operation): tip, mortgage, bmi, compound_interest, loan_payment, percentage, markup, discount, sales_tax, grade, fuel_cost, cooking, retirement, debt_payoff, debt_strategy, budget, loan_comparison, savings_goal, net_worth, paycheck, inflation, area_circle, area_rectangle, volume_cylinder, speed_distance_time",
                required: false
            ),
            "parameters": MCPToolParameter(
                type: .object(properties: [:]),
                description: "Formula-specific parameters as key-value pairs (for formula operation). See examples in tool description.",
                required: false
            )
        ]
    }

    private let logger = Logger(label: "com.sam.mcp.math")

    // MARK: - Lifecycle

    public func initialize() async throws {
        logger.debug("MathOperationsTool initialized")
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        // Accept if operation is explicit OR can be inferred
        if parameters["operation"] as? String != nil {
            return true
        }
        // Infer operation from context
        if inferOperation(from: parameters) != nil {
            return true
        }
        throw MCPError.invalidParameters("'operation' parameter is required")
    }

    /// Infer the operation when LLM omits the operation parameter.
    /// LLMs frequently call with just {"formula":"debt_payoff","parameters":{...}}
    /// instead of {"operation":"formula","formula":"debt_payoff","parameters":{...}}
    private func inferOperation(from parameters: [String: Any]) -> String? {
        if parameters["formula"] as? String != nil {
            return "formula"
        }
        if parameters["expression"] as? String != nil {
            return "calculate"
        }
        if parameters["from"] as? String != nil || parameters["to"] as? String != nil {
            return "convert"
        }
        return nil
    }

    // MARK: - Execute Override (Operation Inference)

    /// Override default execute to auto-infer operation from context.
    /// LLMs often omit the operation parameter when calling math_operations,
    /// sending {"formula":"tip","parameters":{...}} instead of
    /// {"operation":"formula","formula":"tip","parameters":{...}}.
    @MainActor
    public func execute(
        parameters: [String: Any],
        context: MCPExecutionContext
    ) async -> MCPToolResult {
        var params = parameters

        // Auto-infer operation if missing
        if params["operation"] as? String == nil {
            if let inferred = inferOperation(from: params) {
                logger.info("MATH: Auto-inferred operation='\(inferred)' from parameters")
                params["operation"] = inferred
            }
        }

        guard let operation = params["operation"] as? String else {
            return operationError("", message: "Missing 'operation' parameter. Use: calculate, convert, or formula")
        }

        guard validateOperation(operation) else {
            return operationError(operation, message: "Unknown operation '\(operation)'")
        }

        return await routeOperation(operation, parameters: params, context: context)
    }

    // MARK: - Operation Routing

    @MainActor
    public func routeOperation(
        _ operation: String,
        parameters: [String: Any],
        context: MCPExecutionContext
    ) async -> MCPToolResult {
        switch operation {
        case "calculate":
            return await executeCalculate(parameters: parameters)
        case "compute":
            return await executeCompute(parameters: parameters)
        case "convert":
            return await executeConvert(parameters: parameters)
        case "formula":
            return await executeFormula(parameters: parameters)
        default:
            return operationError(operation, message: "Unknown operation '\(operation)'")
        }
    }

    // MARK: - Calculate Operation

    @MainActor
    private func executeCalculate(parameters: [String: Any]) async -> MCPToolResult {
        guard let expression = parameters["expression"] as? String, !expression.isEmpty else {
            return errorResult("'expression' parameter is required for calculate operation")
        }

        // Sanitize the expression to prevent code injection
        let sanitized = sanitizeExpression(expression)
        guard let sanitized = sanitized else {
            return errorResult("Expression contains disallowed characters or patterns. Only mathematical expressions are permitted.")
        }

        let pythonCode = """
        from math import *
        import statistics
        result = \(sanitized)
        if isinstance(result, float) and result == int(result) and abs(result) < 1e15:
            print(int(result))
        else:
            print(result)
        """

        let result = await runPython(pythonCode)

        switch result {
        case .success(let output):
            let trimmed = output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            return successResult("""
            **Expression:** `\(expression)`
            **Result:** \(trimmed)
            """)
        case .failure(let error):
            return errorResult("Calculation failed: \(error.message). Check expression syntax.")
        }
    }

    // MARK: - Compute Operation (Generic Python Sandbox)

    @MainActor
    private func executeCompute(parameters: [String: Any]) async -> MCPToolResult {
        guard let code = parameters["code"] as? String, !code.isEmpty else {
            return errorResult("""
            'code' parameter is required for compute operation.
            Write Python code that uses print() to output results.
            Available modules: math, statistics, itertools, decimal, fractions, collections, datetime, json, csv, re, io.
            Example: {"operation": "compute", "code": "from math import *\\nresult = sum(range(1, 101))\\nprint(f'Sum of 1-100: {result}')"}
            """)
        }

        // Safety checks for compute
        let blocked = ["subprocess", "os.system", "os.popen", "shutil", "__import__",
                        "builtins", "breakpoint", "input(", "exit(", "quit(",
                        "open(", "exec(", "eval(", "compile("]
        let lowerCode = code.lowercased()
        for pattern in blocked {
            if lowerCode.contains(pattern) {
                return errorResult("Blocked: '\(pattern)' is not allowed in compute. Only mathematical/data processing code is permitted.")
            }
        }

        // Line limit
        let lineCount = code.components(separatedBy: "\n").count
        if lineCount > 100 {
            return errorResult("Code too long (\(lineCount) lines). Maximum is 100 lines.")
        }

        // Wrap with safe imports
        let wrappedCode = """
        from math import *
        import statistics
        import itertools
        from decimal import Decimal
        from fractions import Fraction
        from collections import Counter, defaultdict
        from datetime import datetime, timedelta
        import json
        import csv
        import re
        import io
        \(code)
        """

        let result = await runPython(wrappedCode)

        switch result {
        case .success(let output):
            let trimmed = output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if trimmed.isEmpty {
                return successResult("Code executed successfully but produced no output. Use print() to show results.")
            }
            return successResult(trimmed)
        case .failure(let error):
            return errorResult("Compute failed: \(error.message)")
        }
    }

    // MARK: - Convert Operation

    @MainActor
    private func executeConvert(parameters: [String: Any]) async -> MCPToolResult {
        guard let value = extractNumber(parameters, key: "value") else {
            return errorResult("'value' parameter (number) is required for convert operation")
        }

        guard let fromUnit = parameters["from"] as? String, !fromUnit.isEmpty else {
            return errorResult("'from' parameter is required for convert operation")
        }

        guard let toUnit = parameters["to"] as? String, !toUnit.isEmpty else {
            return errorResult("'to' parameter is required for convert operation")
        }

        let from = fromUnit.lowercased().trimmingCharacters(in: CharacterSet.whitespaces)
        let to = toUnit.lowercased().trimmingCharacters(in: CharacterSet.whitespaces)

        // Build conversion expression
        guard let conversionExpr = buildConversionExpression(value: value, from: from, to: to) else {
            return errorResult("Unsupported conversion: \(from) -> \(to). Supported categories: temperature, length, weight/mass, volume, area, speed, data/storage, time.")
        }

        let pythonCode = """
        result = \(conversionExpr)
        print(round(result, 6) if isinstance(result, float) else result)
        """

        let result = await runPython(pythonCode)

        switch result {
        case .success(let output):
            let converted = output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            return successResult("""
            **Conversion:** \(formatNumber(value)) \(fromUnit) → \(toUnit)
            **Result:** \(converted) \(toUnit)
            """)
        case .failure(let error):
            return errorResult("Conversion failed: \(error.message)")
        }
    }

    // MARK: - Formula Operation

    @MainActor
    private func executeFormula(parameters: [String: Any]) async -> MCPToolResult {
        guard let formulaName = parameters["formula"] as? String, !formulaName.isEmpty else {
            return errorResult("""
            'formula' parameter is required. Available formulas:

            EVERYDAY:
            • tip - Calculate tip and split (bill, tip_percent, split)
            • sales_tax - Tax calculator (price, tax_rate, quantity)
            • discount - Discount calculation (original_price, discount_percent)
            • fuel_cost / gas_cost / trip_cost - Fuel cost (distance, mpg, price_per_gallon)
            • cooking / recipe_scale - Scale recipe (original_servings, target_servings, amounts)
            • grade / gpa - Grade calculator (scores, weights, total)
            • bmi - Body Mass Index (weight_lbs, height_inches OR weight_kg, height_m)
            • speed_distance_time - Solve for missing variable (speed, distance, time - provide any 2)

            FINANCIAL PLANNING:
            • retirement - Retirement projection (current_age, retire_age, current_savings, monthly_contribution)
            • debt_payoff - Single debt payoff timeline (balance, rate, monthly_payment, extra_payment)
            • debt_strategy / multi_debt - Multi-debt payoff (debts array, monthly_budget, lump_sum) - returns BOTH avalanche and snowball with payment priority AND elimination timeline
            • budget / fifty_thirty_twenty - 50/30/20 budget analysis (monthly_income, needs, wants, savings)
            • loan_comparison - Compare loans (principal, rates array, terms array)
            • savings_goal - Goal planner (goal, current_savings, monthly_contribution, months)
            • net_worth - Net worth (home_value, investments, cash, mortgage, student_loans, etc.)
            • paycheck / take_home - Paycheck estimator (annual_salary, filing_status, state_tax_rate)
            • inflation - Inflation impact (amount, years, inflation_rate)

            MATH/SCIENCE:
            • mortgage / loan_payment - Monthly payment (principal, rate, years)
            • compound_interest - Compound interest (principal, rate, years, compounds_per_year)
            • percentage - Percentage calculation (value, percentage)
            • markup - Markup/margin (cost, markup_percent)
            • area_circle, area_rectangle, volume_cylinder - Geometry
            """)
        }

        let params = parameters["parameters"] as? [String: Any] ?? [:]

        guard let pythonCode = buildFormulaCode(formulaName.lowercased(), params: params) else {
            return errorResult("Unknown formula '\(formulaName)'. Use the formula list above for available options.")
        }

        let result = await runPython(pythonCode)

        switch result {
        case .success(let output):
            let trimmedOutput = output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            return successResult(trimmedOutput)
        case .failure(let error):
            return errorResult("Formula calculation failed: \(error.message)")
        }
    }

    // MARK: - Formula Builders

    private func buildFormulaCode(_ formula: String, params: [String: Any]) -> String? {
        switch formula {
        case "tip":
            guard let bill = extractNumber(params, key: "bill") else {
                return pythonPrint("ERROR: 'bill' parameter required for tip formula")
            }
            let tipPercent = extractNumber(params, key: "tip_percent") ?? 20.0
            let split = extractNumber(params, key: "split") ?? 1.0
            return """
            bill = \(bill)
            tip_pct = \(tipPercent)
            split = \(max(split, 1))
            tip_amount = bill * (tip_pct / 100)
            total = bill + tip_amount
            per_person = total / split
            print(f"**Tip Calculator**")
            print(f"Bill: ${bill:0.2f}")
            print(f"Tip ({tip_pct:0.0f}%): ${tip_amount:0.2f}")
            print(f"Total: ${total:0.2f}")
            if split > 1:
                print(f"Split {int(split)} ways: ${per_person:0.2f} per person")
            """

        case "mortgage", "loan_payment":
            guard let principal = extractNumber(params, key: "principal"),
                  let rate = extractNumber(params, key: "rate"),
                  let years = extractNumber(params, key: "years") else {
                return pythonPrint("ERROR: 'principal', 'rate' (annual %), and 'years' required")
            }
            return """
            principal = \(principal)
            annual_rate = \(rate) / 100
            months = int(\(years) * 12)
            monthly_rate = annual_rate / 12
            if monthly_rate == 0:
                payment = principal / months
            else:
                payment = principal * (monthly_rate * (1 + monthly_rate)**months) / ((1 + monthly_rate)**months - 1)
            total_paid = payment * months
            total_interest = total_paid - principal
            print(f"**Mortgage/Loan Calculator**")
            print(f"Principal: ${principal:,.2f}")
            print(f"Annual Rate: {annual_rate*100:0.2f}%")
            print(f"Term: {int(\(years))} years ({months} months)")
            print(f"Monthly Payment: ${payment:,.2f}")
            print(f"Total Paid: ${total_paid:,.2f}")
            print(f"Total Interest: ${total_interest:,.2f}")
            """

        case "bmi":
            if let weightLbs = extractNumber(params, key: "weight_lbs"),
               let heightIn = extractNumber(params, key: "height_inches") {
                return """
                weight_kg = \(weightLbs) * 0.453592
                height_m = \(heightIn) * 0.0254
                bmi = weight_kg / (height_m ** 2)
                if bmi < 18.5: cat = "Underweight"
                elif bmi < 25: cat = "Normal weight"
                elif bmi < 30: cat = "Overweight"
                else: cat = "Obese"
                print(f"**BMI Calculator**")
                print(f"Weight: {int(\(weightLbs))} lbs ({weight_kg:0.1f} kg)")
                print(f"Height: {int(\(heightIn))} inches ({height_m:0.2f} m)")
                print(f"BMI: {bmi:0.1f} ({cat})")
                """
            } else if let weightKg = extractNumber(params, key: "weight_kg"),
                      let heightM = extractNumber(params, key: "height_m") {
                return """
                bmi = \(weightKg) / (\(heightM) ** 2)
                if bmi < 18.5: cat = "Underweight"
                elif bmi < 25: cat = "Normal weight"
                elif bmi < 30: cat = "Overweight"
                else: cat = "Obese"
                print(f"**BMI Calculator**")
                print(f"Weight: {int(\(weightKg))} kg")
                print(f"Height: {\(heightM):0.2f} m")
                print(f"BMI: {bmi:0.1f} ({cat})")
                """
            } else {
                return pythonPrint("ERROR: Need (weight_lbs + height_inches) or (weight_kg + height_m)")
            }

        case "compound_interest":
            guard let principal = extractNumber(params, key: "principal"),
                  let rate = extractNumber(params, key: "rate"),
                  let years = extractNumber(params, key: "years") else {
                return pythonPrint("ERROR: 'principal', 'rate' (annual %), and 'years' required")
            }
            let n = extractNumber(params, key: "compounds_per_year") ?? 12.0
            return """
            P = \(principal)
            r = \(rate) / 100
            t = \(years)
            n = \(n)
            A = P * (1 + r/n) ** (n * t)
            interest = A - P
            print(f"**Compound Interest Calculator**")
            print(f"Principal: ${P:,.2f}")
            print(f"Annual Rate: {r*100:0.2f}%")
            print(f"Compounds/Year: {int(n)}")
            print(f"Period: {int(t)} years")
            print(f"Final Amount: ${A:,.2f}")
            print(f"Interest Earned: ${interest:,.2f}")
            """

        case "percentage":
            guard let value = extractNumber(params, key: "value"),
                  let pct = extractNumber(params, key: "percentage") else {
                return pythonPrint("ERROR: 'value' and 'percentage' required")
            }
            return """
            value = \(value)
            pct = \(pct)
            result = value * (pct / 100)
            print(f"**Percentage**")
            print(f"{pct}% of {value} = {result:0.2f}")
            """

        case "markup":
            guard let cost = extractNumber(params, key: "cost"),
                  let markupPct = extractNumber(params, key: "markup_percent") else {
                return pythonPrint("ERROR: 'cost' and 'markup_percent' required")
            }
            return """
            cost = \(cost)
            markup = \(markupPct)
            price = cost * (1 + markup / 100)
            profit = price - cost
            margin = (profit / price) * 100
            print(f"**Markup Calculator**")
            print(f"Cost: ${cost:,.2f}")
            print(f"Markup: {markup:0.0f}%")
            print(f"Selling Price: ${price:,.2f}")
            print(f"Profit: ${profit:,.2f}")
            print(f"Profit Margin: {margin:0.1f}%")
            """

        case "discount":
            guard let price = extractNumber(params, key: "original_price"),
                  let discountPct = extractNumber(params, key: "discount_percent") else {
                return pythonPrint("ERROR: 'original_price' and 'discount_percent' required")
            }
            return """
            price = \(price)
            discount_pct = \(discountPct)
            savings = price * (discount_pct / 100)
            final = price - savings
            print(f"**Discount Calculator**")
            print(f"Original Price: ${price:,.2f}")
            print(f"Discount: {discount_pct:0.0f}%")
            print(f"Savings: ${savings:,.2f}")
            print(f"Final Price: ${final:,.2f}")
            """

        case "area_circle":
            guard let radius = extractNumber(params, key: "radius") else {
                return pythonPrint("ERROR: 'radius' required")
            }
            return """
            from math import pi
            r = \(radius)
            area = pi * r ** 2
            circumference = 2 * pi * r
            print(f"**Circle**")
            print(f"Radius: {r}")
            print(f"Area: {area:0.4f}")
            print(f"Circumference: {circumference:0.4f}")
            """

        case "area_rectangle":
            guard let length = extractNumber(params, key: "length"),
                  let width = extractNumber(params, key: "width") else {
                return pythonPrint("ERROR: 'length' and 'width' required")
            }
            return """
            l = \(length)
            w = \(width)
            area = l * w
            perimeter = 2 * (l + w)
            print(f"**Rectangle**")
            print(f"Length: {l}, Width: {w}")
            print(f"Area: {area:0.4f}")
            print(f"Perimeter: {perimeter:0.4f}")
            """

        case "volume_cylinder":
            guard let radius = extractNumber(params, key: "radius"),
                  let height = extractNumber(params, key: "height") else {
                return pythonPrint("ERROR: 'radius' and 'height' required")
            }
            return """
            from math import pi
            r = \(radius)
            h = \(height)
            volume = pi * r**2 * h
            surface = 2 * pi * r * (r + h)
            print(f"**Cylinder**")
            print(f"Radius: {r}, Height: {h}")
            print(f"Volume: {volume:0.4f}")
            print(f"Surface Area: {surface:0.4f}")
            """

        case "speed_distance_time":
            let speed = extractNumber(params, key: "speed")
            let distance = extractNumber(params, key: "distance")
            let time = extractNumber(params, key: "time")
            let provided = [speed != nil, distance != nil, time != nil].filter { $0 }.count
            guard provided >= 2 else {
                return pythonPrint("ERROR: Provide any 2 of: 'speed', 'distance', 'time'")
            }
            if let s = speed, let d = distance {
                return """
                s = \(s)
                d = \(d)
                t = d / s
                hours = int(t)
                minutes = (t - hours) * 60
                print(f"**Speed/Distance/Time**")
                print(f"Speed: {s}, Distance: {d}")
                print(f"Time: {t:0.4f} ({hours}h {minutes:0.0f}m)")
                """
            } else if let s = speed, let t = time {
                return """
                s = \(s)
                t = \(t)
                d = s * t
                print(f"**Speed/Distance/Time**")
                print(f"Speed: {s}, Time: {t}")
                print(f"Distance: {d:0.4f}")
                """
            } else if let d = distance, let t = time {
                return """
                d = \(d)
                t = \(t)
                s = d / t
                print(f"**Speed/Distance/Time**")
                print(f"Distance: {d}, Time: {t}")
                print(f"Speed: {s:0.4f}")
                """
            }
            return nil

        case "sales_tax":
            guard let price = extractNumber(params, key: "price") else {
                return pythonPrint("ERROR: 'price' parameter required for sales_tax formula")
            }
            let taxRate = extractNumber(params, key: "tax_rate") ?? 0.0
            let quantity = extractNumber(params, key: "quantity") ?? 1.0
            return """
            price = \(price)
            tax_rate = \(taxRate) / 100
            quantity = \(max(quantity, 1))
            subtotal = price * quantity
            tax = subtotal * tax_rate
            total = subtotal + tax
            print(f"**Sales Tax Calculator**")
            if quantity > 1:
                print(f"Price: ${price:0.2f} x {int(quantity)} = ${subtotal:0.2f}")
            else:
                print(f"Subtotal: ${subtotal:0.2f}")
            print(f"Tax ({tax_rate*100:0.1f}%): ${tax:0.2f}")
            print(f"Total: ${total:0.2f}")
            """

        case "grade", "gpa":
            guard let scores = params["scores"] as? [Any] else {
                return pythonPrint("ERROR: 'scores' array required (e.g. [95, 88, 76, 92]). Optional: 'weights' array, 'total' points possible per assignment")
            }
            let values = scores.compactMap { extractNumber(["v": $0], key: "v") }
            guard !values.isEmpty else {
                return pythonPrint("ERROR: 'scores' must contain numbers")
            }
            let total = extractNumber(params, key: "total") ?? 100.0
            let weightsArray = (params["weights"] as? [Any])?.compactMap { extractNumber(["v": $0], key: "v") }
            let scoresStr = values.map { String($0) }.joined(separator: ", ")
            let weightsStr = weightsArray?.map { String($0) }.joined(separator: ", ") ?? ""
            return """
            scores = [\(scoresStr)]
            total = \(total)
            weights = [\(weightsStr)] if [\(weightsStr)] else None
            
            if weights and len(weights) == len(scores):
                weighted_sum = sum(s * w for s, w in zip(scores, weights))
                weight_total = sum(weights)
                average = weighted_sum / weight_total
            else:
                average = sum(scores) / len(scores)
            
            pct = (average / total) * 100
            if pct >= 93: letter = "A"
            elif pct >= 90: letter = "A-"
            elif pct >= 87: letter = "B+"
            elif pct >= 83: letter = "B"
            elif pct >= 80: letter = "B-"
            elif pct >= 77: letter = "C+"
            elif pct >= 73: letter = "C"
            elif pct >= 70: letter = "C-"
            elif pct >= 67: letter = "D+"
            elif pct >= 60: letter = "D"
            else: letter = "F"
            
            print(f"**Grade Calculator**")
            print(f"Scores: {scores}")
            if weights: print(f"Weights: {weights}")
            print(f"Average: {average:0.2f} / {total}")
            print(f"Percentage: {pct:0.1f}%")
            print(f"Letter Grade: {letter}")
            """

        case "fuel_cost", "gas_cost", "trip_cost":
            guard let distance = extractNumber(params, key: "distance") else {
                return pythonPrint("ERROR: 'distance' parameter required (in miles or km). Also: 'mpg' or 'kpl', 'price_per_gallon' or 'price_per_liter'")
            }
            let mpg = extractNumber(params, key: "mpg")
            let kpl = extractNumber(params, key: "kpl")
            let priceGal = extractNumber(params, key: "price_per_gallon")
            let priceLtr = extractNumber(params, key: "price_per_liter")
            
            let efficiency = mpg ?? (kpl.map { $0 * 3.78541 } ?? 25.0)
            let fuelPrice = priceGal ?? (priceLtr.map { $0 * 3.78541 } ?? 3.50)
            
            return """
            distance = \(distance)
            mpg = \(efficiency)
            price = \(fuelPrice)
            gallons = distance / mpg
            cost = gallons * price
            print(f"**Fuel Cost Calculator**")
            print(f"Distance: {distance:0.1f} miles")
            print(f"Fuel Economy: {mpg:0.1f} MPG")
            print(f"Fuel Price: ${price:0.2f}/gallon")
            print(f"Fuel Needed: {gallons:0.2f} gallons")
            print(f"Estimated Cost: ${cost:0.2f}")
            """

        case "cooking", "recipe_scale":
            guard let originalServings = extractNumber(params, key: "original_servings"),
                  let targetServings = extractNumber(params, key: "target_servings") else {
                return pythonPrint("ERROR: 'original_servings' and 'target_servings' required. Optional: 'amounts' array of ingredient quantities")
            }
            let amounts = (params["amounts"] as? [Any])?.compactMap { extractNumber(["v": $0], key: "v") }
            let amountsStr = amounts?.map { String($0) }.joined(separator: ", ") ?? ""
            return """
            original = \(originalServings)
            target = \(targetServings)
            factor = target / original
            amounts = [\(amountsStr)] if [\(amountsStr)] else []
            print(f"**Recipe Scaler**")
            print(f"Original: {int(original)} servings -> Target: {int(target)} servings")
            print(f"Scale Factor: {factor:0.2f}x")
            if amounts:
                print(f"\\nScaled Amounts:")
                for amt in amounts:
                    scaled = amt * factor
                    print(f"  {amt} -> {scaled:0.2f}")
            """

        // MARK: Financial Planning Formulas

        case "retirement", "retirement_savings":
            guard let currentAge = extractNumber(params, key: "current_age"),
                  let retireAge = extractNumber(params, key: "retire_age") else {
                return pythonPrint("ERROR: 'current_age' and 'retire_age' required. Optional: current_savings, monthly_contribution, annual_return (default 7%), withdrawal_rate (default 4%)")
            }
            let savings = extractNumber(params, key: "current_savings") ?? 0
            let monthly = extractNumber(params, key: "monthly_contribution") ?? 500
            let annualReturn = extractNumber(params, key: "annual_return") ?? 7.0
            let withdrawalRate = extractNumber(params, key: "withdrawal_rate") ?? 4.0
            return """
            current_age = \(currentAge)
            retire_age = \(retireAge)
            savings = \(savings)
            monthly = \(monthly)
            annual_return = \(annualReturn) / 100
            withdrawal_rate = \(withdrawalRate) / 100
            years = int(retire_age - current_age)
            monthly_rate = annual_return / 12

            # Project growth year by year
            balance = savings
            yearly = []
            for y in range(1, years + 1):
                for m in range(12):
                    balance = balance * (1 + monthly_rate) + monthly
                yearly.append(balance)

            total_contributions = savings + (monthly * 12 * years)
            growth = balance - total_contributions
            annual_income = balance * withdrawal_rate
            monthly_income = annual_income / 12

            print(f"**Retirement Savings Projection**")
            print(f"Current Age: {int(current_age)} | Retire At: {int(retire_age)} | Years: {years}")
            print(f"Current Savings: ${savings:,.2f}")
            print(f"Monthly Contribution: ${monthly:,.2f}")
            print(f"Annual Return: {annual_return*100:0.1f}%")
            print(f"")
            print(f"**At Retirement (Age {int(retire_age)}):**")
            print(f"  Projected Balance: ${balance:,.2f}")
            print(f"  Total Contributed: ${total_contributions:,.2f}")
            print(f"  Investment Growth: ${growth:,.2f}")
            print(f"")
            print(f"**Retirement Income ({withdrawal_rate*100:0.0f}% Rule):**")
            print(f"  Annual Income: ${annual_income:,.2f}")
            print(f"  Monthly Income: ${monthly_income:,.2f}")
            milestones = [5, 10, 15, 20, 25, 30]
            print(f"\\n**Milestones:**")
            for m in milestones:
                if m <= years:
                    print(f"  Year {m} (Age {int(current_age+m)}): ${yearly[m-1]:,.2f}")
            """

        case "debt_payoff", "debt_snowball", "debt_avalanche":
            guard let balance = extractNumber(params, key: "balance"),
                  let rate = extractNumber(params, key: "rate"),
                  let payment = extractNumber(params, key: "monthly_payment") else {
                return pythonPrint("ERROR: 'balance', 'rate' (APR %), and 'monthly_payment' required. Optional: extra_payment")
            }
            let extra = extractNumber(params, key: "extra_payment") ?? 0
            return """
            balance = \(balance)
            apr = \(rate) / 100
            payment = \(payment)
            extra = \(extra)
            monthly_rate = apr / 12
            total_payment = payment + extra

            if total_payment <= balance * monthly_rate:
                print("**ERROR:** Payment too low to cover interest. Minimum: ${:0.2f}".format(balance * monthly_rate + 1))
            else:
                b = balance
                months = 0
                total_interest = 0
                total_paid = 0
                while b > 0 and months < 600:
                    interest = b * monthly_rate
                    total_interest += interest
                    principal = min(total_payment - interest, b)
                    b -= principal
                    total_paid += interest + principal
                    months += 1

                years = months // 12
                remaining_months = months % 12

                # Compare minimum payment only
                b2 = balance
                months_min = 0
                total_interest_min = 0
                while b2 > 0 and months_min < 600:
                    interest2 = b2 * monthly_rate
                    total_interest_min += interest2
                    principal2 = min(payment - interest2, b2)
                    b2 -= principal2
                    months_min += 1

                print(f"**Debt Payoff Calculator**")
                print(f"Balance: ${balance:,.2f}")
                print(f"APR: {apr*100:0.2f}%")
                print(f"Monthly Payment: ${total_payment:,.2f}" + (f" (${payment:,.2f} + ${extra:,.2f} extra)" if extra > 0 else ""))
                print(f"")
                print(f"**Payoff Timeline:**")
                print(f"  Months to payoff: {months} ({years}y {remaining_months}m)")
                print(f"  Total Interest: ${total_interest:,.2f}")
                print(f"  Total Paid: ${total_paid:,.2f}")
                if extra > 0:
                    saved = total_interest_min - total_interest
                    months_saved = months_min - months
                    print(f"")
                    print(f"**Extra Payment Savings:**")
                    print(f"  Interest Saved: ${saved:,.2f}")
                    print(f"  Months Saved: {months_saved}")
            """

        case "debt_strategy", "multi_debt", "debt_plan":
            // Multi-debt payoff strategy calculator
            // Accepts an array of debts and a total monthly payment budget
            // Simulates avalanche (highest rate first) and snowball (lowest balance first)
            // Optional: lump_sum for one-time extra payment applied in month 1
            guard let debtsArray = params["debts"] as? [[String: Any]], !debtsArray.isEmpty else {
                return pythonPrint("ERROR: 'debts' array required. Each debt: {name, balance, rate, minimum_payment}. Also: 'monthly_budget' (total monthly payment). Optional: 'lump_sum' (one-time extra payment applied to highest-rate or lowest-balance debt in month 1).\nExample: {\"debts\": [{\"name\": \"Visa\", \"balance\": 5000, \"rate\": 22.99, \"minimum_payment\": 100}], \"monthly_budget\": 1500, \"lump_sum\": 5000}")
            }
            guard let budget = extractNumber(params, key: "monthly_budget") else {
                return pythonPrint("ERROR: 'monthly_budget' (total monthly payment across all debts) is required")
            }

            let lumpSum = extractNumber(params, key: "lump_sum")
                ?? extractNumber(params, key: "one_time_payment")
                ?? extractNumber(params, key: "extra_payment")
                ?? 0

            // Warn about unsupported parameters so the model doesn't retry with them
            let supportedKeys: Set<String> = ["debts", "monthly_budget", "lump_sum", "one_time_payment", "extra_payment"]
            let unknownKeys = Set(params.keys).subtracting(supportedKeys).subtracting(["operation", "formula", "parameters"])
            var warnings: [String] = []
            if !unknownKeys.isEmpty {
                warnings.append("Note: Ignored unsupported parameters: \(unknownKeys.sorted().joined(separator: ", ")). This tool accepts: debts, monthly_budget, lump_sum. Both avalanche and snowball strategies are always calculated and compared automatically - do NOT call separately for each strategy.")
            }

            // Build Python debt list from the array
            var debtDefs: [String] = []
            for debt in debtsArray {
                let name = (debt["name"] as? String) ?? "Debt"
                let bal = extractNumber(debt, key: "balance") ?? 0
                let rate = extractNumber(debt, key: "rate") ?? 0
                let minPay = extractNumber(debt, key: "minimum_payment") ?? extractNumber(debt, key: "min_payment") ?? 0
                debtDefs.append("    {\"name\": \"\(name)\", \"balance\": \(bal), \"rate\": \(rate), \"min\": \(minPay)}")
            }
            let debtsStr = debtDefs.joined(separator: ",\n")

            let warningPrint = warnings.isEmpty ? "" : warnings.map { "print(\"\($0)\")\nprint(\"\")" }.joined(separator: "\n") + "\n"

            return """
            import copy
            \(warningPrint)
            debts = [
            \(debtsStr)
            ]
            budget = \(budget)
            lump_sum = \(lumpSum)

            total_min = sum(d["min"] for d in debts)
            total_balance = sum(d["balance"] for d in debts)
            if budget < total_min:
                print(f"**ERROR:** Monthly budget ${budget:,.2f} is less than total minimum payments ${total_min:,.2f}")
            else:
                def simulate(debts_input, strategy, lump=0):
                    ds = [dict(d) for d in debts_input]
                    months = 0
                    total_interest = 0
                    payoff_order = []
                    lump_remaining = lump
                    while any(d["balance"] > 0 for d in ds) and months < 600:
                        months += 1
                        # Calculate interest first
                        for d in ds:
                            if d["balance"] > 0:
                                interest = d["balance"] * (d["rate"] / 100 / 12)
                                d["balance"] += interest
                                total_interest += interest
                        # Apply lump sum in month 1 to target debt
                        if months == 1 and lump_remaining > 0:
                            if strategy == "avalanche":
                                targets = sorted([d for d in ds if d["balance"] > 0], key=lambda x: -x["rate"])
                            else:
                                targets = sorted([d for d in ds if d["balance"] > 0], key=lambda x: x["balance"])
                            for t in targets:
                                if lump_remaining <= 0:
                                    break
                                pay = min(lump_remaining, t["balance"])
                                t["balance"] -= pay
                                lump_remaining -= pay
                                if t["balance"] <= 0.01:
                                    t["balance"] = 0
                                    payoff_order.append((t["name"], months))
                        # Pay minimums first
                        remaining = budget
                        for d in ds:
                            if d["balance"] > 0:
                                pay = min(d["min"], d["balance"])
                                d["balance"] -= pay
                                remaining -= pay
                                if d["balance"] <= 0.01:
                                    d["balance"] = 0
                                    payoff_order.append((d["name"], months))
                        # Apply extra to target
                        if remaining > 0:
                            if strategy == "avalanche":
                                targets = sorted([d for d in ds if d["balance"] > 0], key=lambda x: -x["rate"])
                            else:
                                targets = sorted([d for d in ds if d["balance"] > 0], key=lambda x: x["balance"])
                            for t in targets:
                                if remaining <= 0:
                                    break
                                pay = min(remaining, t["balance"])
                                t["balance"] -= pay
                                remaining -= pay
                                if t["balance"] <= 0.01:
                                    t["balance"] = 0
                                    payoff_order.append((t["name"], months))
                    return months, total_interest, payoff_order

                months_a, interest_a, order_a = simulate(debts, "avalanche", lump_sum)
                months_s, interest_s, order_s = simulate(debts, "snowball", lump_sum)

                extra = budget - total_min

                # Build priority lists for display
                avalanche_priority = sorted(debts, key=lambda x: -x["rate"])
                snowball_priority = sorted(debts, key=lambda x: x["balance"])

                print(f"**Multi-Debt Payoff Strategy**")
                print(f"Total Debt: ${total_balance:,.2f} across {len(debts)} accounts")
                print(f"Monthly Budget: ${budget:,.2f} (minimums: ${total_min:,.2f} + ${extra:,.2f} extra)")
                if lump_sum > 0:
                    print(f"Lump Sum Payment: ${lump_sum:,.2f} (applied to target debt in month 1)")
                print(f"")

                # Avalanche results
                y_a = months_a // 12
                m_a = months_a % 12
                print(f"**Avalanche Method** (highest interest rate first - saves the most)")
                print(f"  Debt-free in: {months_a} months ({y_a}y {m_a}m)")
                print(f"  Total Interest: ${interest_a:,.2f}")
                print(f"  Total Paid: ${total_balance + interest_a:,.2f}")
                print(f"")
                print(f"  Payment Priority (where extra money goes each month):")
                for i, d in enumerate(avalanche_priority, 1):
                    print(f"    {i}. {d['name']} ({d['rate']}% APR, ${d['balance']:,.2f})")
                print(f"")
                print(f"  Elimination Timeline (when each debt reaches $0):")
                for name, mo in order_a:
                    y = mo // 12
                    m = mo % 12
                    print(f"    {name}: month {mo} ({y}y {m}m)")
                print(f"")

                # Snowball results
                y_s = months_s // 12
                m_s = months_s % 12
                print(f"**Snowball Method** (lowest balance first - fastest wins)")
                print(f"  Debt-free in: {months_s} months ({y_s}y {m_s}m)")
                print(f"  Total Interest: ${interest_s:,.2f}")
                print(f"  Total Paid: ${total_balance + interest_s:,.2f}")
                print(f"")
                print(f"  Payment Priority (where extra money goes each month):")
                for i, d in enumerate(snowball_priority, 1):
                    print(f"    {i}. {d['name']} (${d['balance']:,.2f}, {d['rate']}% APR)")
                print(f"")
                print(f"  Elimination Timeline (when each debt reaches $0):")
                for name, mo in order_s:
                    y = mo // 12
                    m = mo % 12
                    print(f"    {name}: month {mo} ({y}y {m}m)")

                # Comparison
                if interest_a != interest_s:
                    diff = abs(interest_s - interest_a)
                    print(f"")
                    if interest_a < interest_s:
                        print(f"**Avalanche saves ${diff:,.2f}** in interest vs snowball")
                    else:
                        print(f"**Snowball saves ${diff:,.2f}** in interest vs avalanche")
                print(f"")
                print(f"NOTE: Payment priority = where extra $ above minimums goes. Elimination timeline = when each debt is fully paid off (affected by both extra payments AND minimum payments on all debts).")
            """

        case "budget", "budget_analysis", "fifty_thirty_twenty":
            guard let income = extractNumber(params, key: "monthly_income") else {
                return pythonPrint("ERROR: 'monthly_income' (after tax) required. Optional: needs, wants, savings (actual amounts to compare)")
            }
            let needs = extractNumber(params, key: "needs")
            let wants = extractNumber(params, key: "wants")
            let savings = extractNumber(params, key: "savings")
            return """
            income = \(income)
            needs_target = income * 0.50
            wants_target = income * 0.30
            savings_target = income * 0.20
            needs_actual = \(needs ?? 0)
            wants_actual = \(wants ?? 0)
            savings_actual = \(savings ?? 0)
            has_actuals = \(needs != nil ? "True" : "False")

            print(f"**50/30/20 Budget Analysis**")
            print(f"Monthly Income (After Tax): ${income:,.2f}")
            print(f"")
            print(f"{'Category':<12} {'Target':>10} {'%':>6}" + ("  {'Actual':>10}  {'Status':>10}" if has_actuals else ""))
            print(f"{'─'*12} {'─'*10} {'─'*6}" + ("  {'─'*10}  {'─'*10}" if has_actuals else ""))
            if has_actuals:
                for label, target, actual in [("Needs", needs_target, needs_actual), ("Wants", wants_target, wants_actual), ("Savings", savings_target, savings_actual)]:
                    pct = (actual/income)*100 if income > 0 else 0
                    status = "✓ On track" if actual <= target else "⚠ Over"
                    if label == "Savings": status = "✓ On track" if actual >= target else "⚠ Under"
                    print(f"{label:<12} ${target:>9,.2f} {target/income*100:>5.0f}%  ${actual:>9,.2f}  {status:>10}")
                leftover = income - needs_actual - wants_actual - savings_actual
                print(f"\\nUnaccounted: ${leftover:,.2f}")
            else:
                for label, target, pct in [("Needs", needs_target, 50), ("Wants", wants_target, 30), ("Savings", savings_target, 20)]:
                    print(f"{label:<12} ${target:>9,.2f} {pct:>5}%")
            print(f"\\n**Annual View:**")
            print(f"  Needs: ${needs_target*12:,.2f}/yr | Wants: ${wants_target*12:,.2f}/yr | Savings: ${savings_target*12:,.2f}/yr")
            """

        case "loan_comparison", "compare_loans":
            guard let principal = extractNumber(params, key: "principal") else {
                return pythonPrint("ERROR: 'principal' required, plus 'rates' array and 'terms' array (years). Example: rates=[6.5,7.0,7.5], terms=[15,30]")
            }
            let rates = (params["rates"] as? [Any])?.compactMap { extractNumber(["v": $0], key: "v") } ?? [6.0, 6.5, 7.0]
            let terms = (params["terms"] as? [Any])?.compactMap { extractNumber(["v": $0], key: "v") } ?? [15.0, 30.0]
            let ratesStr = rates.map { String($0) }.joined(separator: ", ")
            let termsStr = terms.map { String($0) }.joined(separator: ", ")
            return """
            principal = \(principal)
            rates = [\(ratesStr)]
            terms = [\(termsStr)]

            print(f"**Loan Comparison: ${principal:,.2f}**")
            print(f"")
            print(f"{'Rate':>6}  {'Term':>6}  {'Monthly':>12}  {'Total Paid':>14}  {'Total Interest':>14}")
            print(f"{'─'*6}  {'─'*6}  {'─'*12}  {'─'*14}  {'─'*14}")
            for rate in rates:
                for term in terms:
                    r = rate / 100 / 12
                    n = int(term * 12)
                    if r == 0:
                        pmt = principal / n
                    else:
                        pmt = principal * (r * (1+r)**n) / ((1+r)**n - 1)
                    total = pmt * n
                    interest = total - principal
                    print(f"{rate:>5.2f}%  {int(term):>4}yr  ${pmt:>11,.2f}  ${total:>13,.2f}  ${interest:>13,.2f}")
            """

        case "savings_goal":
            guard let goal = extractNumber(params, key: "goal") else {
                return pythonPrint("ERROR: 'goal' (target amount) required. Optional: current_savings, monthly_contribution, annual_return (default 5%), months")
            }
            let current = extractNumber(params, key: "current_savings") ?? 0
            let monthlyContrib = extractNumber(params, key: "monthly_contribution")
            let annualReturn = extractNumber(params, key: "annual_return") ?? 5.0
            let months = extractNumber(params, key: "months")
            return """
            goal = \(goal)
            current = \(current)
            annual_return = \(annualReturn) / 100
            monthly_rate = annual_return / 12
            remaining = goal - current

            \(monthlyContrib != nil ? "monthly = \(monthlyContrib!)" : "monthly = None")
            \(months != nil ? "months = int(\(months!))" : "months = None")

            print(f"**Savings Goal Calculator**")
            print(f"Goal: ${goal:,.2f}")
            print(f"Current Savings: ${current:,.2f}")
            print(f"Remaining: ${remaining:,.2f}")
            print(f"Annual Return: {annual_return*100:0.1f}%")
            print(f"")

            if monthly is not None and months is None:
                # Calculate time to reach goal
                b = current
                m = 0
                while b < goal and m < 1200:
                    b = b * (1 + monthly_rate) + monthly
                    m += 1
                years = m // 12
                rem_months = m % 12
                print(f"Monthly Contribution: ${monthly:,.2f}")
                print(f"Time to Goal: {m} months ({years}y {rem_months}m)")
                print(f"Total Contributed: ${current + monthly * m:,.2f}")
                print(f"Interest Earned: ${b - current - monthly * m:,.2f}")
            elif months is not None and monthly is None:
                # Calculate required monthly contribution
                if monthly_rate == 0:
                    needed = remaining / months
                else:
                    fv_current = current * (1 + monthly_rate) ** months
                    shortfall = goal - fv_current
                    needed = shortfall * monthly_rate / ((1 + monthly_rate)**months - 1)
                print(f"Timeframe: {int(months)} months ({int(months)//12}y {int(months)%12}m)")
                print(f"Required Monthly Contribution: ${needed:,.2f}")
                print(f"Total Contributed: ${current + needed * int(months):,.2f}")
            elif monthly is not None and months is not None:
                b = current
                for i in range(int(months)):
                    b = b * (1 + monthly_rate) + monthly
                surplus = b - goal
                print(f"Monthly: ${monthly:,.2f} for {int(months)} months")
                print(f"Projected Balance: ${b:,.2f}")
                print(f"{'Surplus' if surplus >= 0 else 'Shortfall'}: ${abs(surplus):,.2f}")
            else:
                # No monthly or months given - show different scenarios
                print(f"**Monthly Contribution Scenarios (to reach goal):**")
                for m in [6, 12, 24, 36, 60]:
                    if monthly_rate == 0:
                        needed = remaining / m
                    else:
                        fv_current = current * (1 + monthly_rate) ** m
                        shortfall = goal - fv_current
                        needed = shortfall * monthly_rate / ((1 + monthly_rate)**m - 1) if shortfall > 0 else 0
                    print(f"  {m:>3} months ({m//12}y {m%12}m): ${needed:,.2f}/month")
            """

        case "net_worth":
            let assets = extractNumber(params, key: "assets") ?? 0
            let liabilities = extractNumber(params, key: "liabilities") ?? 0
            let home = extractNumber(params, key: "home_value") ?? 0
            let investments = extractNumber(params, key: "investments") ?? 0
            let cash = extractNumber(params, key: "cash") ?? 0
            let vehicles = extractNumber(params, key: "vehicles") ?? 0
            let mortgageBalance = extractNumber(params, key: "mortgage") ?? 0
            let studentLoans = extractNumber(params, key: "student_loans") ?? 0
            let carLoans = extractNumber(params, key: "car_loans") ?? 0
            let creditCards = extractNumber(params, key: "credit_cards") ?? 0
            let otherDebt = extractNumber(params, key: "other_debt") ?? 0
            return """
            # Assets
            home = \(home)
            investments = \(investments)
            cash = \(cash)
            vehicles = \(vehicles)
            other_assets = \(assets)
            total_assets = home + investments + cash + vehicles + other_assets

            # Liabilities
            mortgage = \(mortgageBalance)
            student_loans = \(studentLoans)
            car_loans = \(carLoans)
            credit_cards = \(creditCards)
            other_debt = \(otherDebt)
            other_liabilities = \(liabilities)
            total_liabilities = mortgage + student_loans + car_loans + credit_cards + other_debt + other_liabilities

            net_worth = total_assets - total_liabilities

            print(f"**Net Worth Calculator**")
            print(f"")
            print(f"**Assets:**")
            if home > 0: print(f"  Home Value:      ${home:>12,.2f}")
            if investments > 0: print(f"  Investments:     ${investments:>12,.2f}")
            if cash > 0: print(f"  Cash/Savings:    ${cash:>12,.2f}")
            if vehicles > 0: print(f"  Vehicles:        ${vehicles:>12,.2f}")
            if other_assets > 0: print(f"  Other Assets:    ${other_assets:>12,.2f}")
            print(f"  {'─'*30}")
            print(f"  Total Assets:    ${total_assets:>12,.2f}")
            print(f"")
            print(f"**Liabilities:**")
            if mortgage > 0: print(f"  Mortgage:        ${mortgage:>12,.2f}")
            if student_loans > 0: print(f"  Student Loans:   ${student_loans:>12,.2f}")
            if car_loans > 0: print(f"  Car Loans:       ${car_loans:>12,.2f}")
            if credit_cards > 0: print(f"  Credit Cards:    ${credit_cards:>12,.2f}")
            if other_debt > 0: print(f"  Other Debt:      ${other_debt:>12,.2f}")
            if other_liabilities > 0: print(f"  Other Liabilities: ${other_liabilities:>12,.2f}")
            print(f"  {'─'*30}")
            print(f"  Total Liabilities: ${total_liabilities:>12,.2f}")
            print(f"")
            print(f"**Net Worth: ${net_worth:>12,.2f}**")
            ratio = (total_liabilities / total_assets * 100) if total_assets > 0 else 0
            print(f"Debt-to-Asset Ratio: {ratio:0.1f}%")
            """

        case "paycheck", "take_home", "salary":
            guard let gross = extractNumber(params, key: "annual_salary") else {
                return pythonPrint("ERROR: 'annual_salary' required. Optional: pay_frequency ('weekly','biweekly','semimonthly','monthly'), filing_status ('single','married'), state_tax_rate, pre_tax_deductions, post_tax_deductions")
            }
            let frequency = (params["pay_frequency"] as? String)?.lowercased() ?? "biweekly"
            let stateTax = extractNumber(params, key: "state_tax_rate") ?? 5.0
            let preTax = extractNumber(params, key: "pre_tax_deductions") ?? 0
            let postTax = extractNumber(params, key: "post_tax_deductions") ?? 0
            let filing = (params["filing_status"] as? String)?.lowercased() ?? "single"
            return """
            annual = \(gross)
            frequency = "\(frequency)"
            state_tax_rate = \(stateTax) / 100
            pre_tax_annual = \(preTax)
            post_tax_annual = \(postTax)
            filing = "\(filing)"

            periods = {"weekly": 52, "biweekly": 26, "semimonthly": 24, "monthly": 12}
            num_periods = periods.get(frequency, 26)

            taxable = annual - pre_tax_annual

            # 2025 federal brackets (simplified)
            if filing == "married":
                brackets = [(23200, 0), (23200, 0.10), (71550, 0.12), (100000, 0.22), (192150, 0.24), (170050, 0.32), (346875, 0.35), (float('inf'), 0.37)]
                standard_deduction = 30750
            else:
                brackets = [(15400, 0), (11600, 0.10), (35550, 0.12), (53100, 0.22), (96050, 0.24), (14550, 0.32), (346875, 0.35), (float('inf'), 0.37)]
                standard_deduction = 15400

            adjusted = max(taxable - standard_deduction, 0)
            federal_tax = 0
            remaining = adjusted
            for bracket_size, rate in brackets:
                taxed = min(remaining, bracket_size)
                federal_tax += taxed * rate
                remaining -= taxed
                if remaining <= 0: break

            fica_ss = min(annual, 168600) * 0.062
            fica_medicare = annual * 0.0145
            if annual > 200000:
                fica_medicare += (annual - 200000) * 0.009
            state_tax = taxable * state_tax_rate

            total_tax = federal_tax + fica_ss + fica_medicare + state_tax
            net_annual = annual - total_tax - pre_tax_annual - post_tax_annual
            net_period = net_annual / num_periods

            print(f"**Paycheck Estimator ({filing.title()} Filing)**")
            print(f"Annual Salary: ${annual:,.2f}")
            print(f"Pay Frequency: {frequency} ({num_periods} periods/year)")
            print(f"")
            print(f"**Annual Breakdown:**")
            print(f"  Gross Income:        ${annual:>12,.2f}")
            if pre_tax_annual > 0:
                print(f"  Pre-Tax Deductions:  ${pre_tax_annual:>12,.2f}")
            print(f"  Federal Tax:         ${federal_tax:>12,.2f}")
            print(f"  State Tax ({state_tax_rate*100:0.1f}%):     ${state_tax:>12,.2f}")
            print(f"  Social Security:     ${fica_ss:>12,.2f}")
            print(f"  Medicare:            ${fica_medicare:>12,.2f}")
            if post_tax_annual > 0:
                print(f"  Post-Tax Deductions: ${post_tax_annual:>12,.2f}")
            print(f"  {'─'*30}")
            print(f"  Net Annual:          ${net_annual:>12,.2f}")
            print(f"")
            print(f"**Per Paycheck ({frequency}):** ${net_period:,.2f}")
            print(f"Effective Tax Rate: {total_tax/annual*100:0.1f}%")
            """

        case "inflation", "future_value":
            guard let amount = extractNumber(params, key: "amount") else {
                return pythonPrint("ERROR: 'amount' required. Optional: years (default 10), inflation_rate (default 3%)")
            }
            let years = extractNumber(params, key: "years") ?? 10
            let inflationRate = extractNumber(params, key: "inflation_rate") ?? 3.0
            return """
            amount = \(amount)
            years = int(\(years))
            rate = \(inflationRate) / 100

            print(f"**Inflation Impact Calculator**")
            print(f"Current Value: ${amount:,.2f}")
            print(f"Inflation Rate: {rate*100:0.1f}%")
            print(f"")
            print(f"{'Year':>6}  {'Future Cost':>14}  {'Buying Power':>14}")
            print(f"{'─'*6}  {'─'*14}  {'─'*14}")
            for y in [1, 2, 3, 5, 10, 15, 20, 25, 30]:
                if y <= years:
                    future_cost = amount * (1 + rate) ** y
                    buying_power = amount / (1 + rate) ** y
                    print(f"{y:>6}  ${future_cost:>13,.2f}  ${buying_power:>13,.2f}")
            """

        default:
            return nil
        }
    }

    // MARK: - Unit Conversion

    private func buildConversionExpression(value: Double, from: String, to: String) -> String? {
        // Temperature (special case - not multiplicative)
        let tempUnits = ["fahrenheit", "f", "celsius", "c", "kelvin", "k"]
        if tempUnits.contains(from) || tempUnits.contains(to) {
            return buildTemperatureConversion(value: value, from: from, to: to)
        }

        // Get conversion factors to base unit
        guard let fromFactor = unitToBase(from),
              let toFactor = unitToBase(to) else {
            return nil
        }

        // Ensure same category
        guard fromFactor.category == toFactor.category else {
            return nil
        }

        // Convert: value * fromFactor / toFactor
        return "\(value) * \(fromFactor.factor) / \(toFactor.factor)"
    }

    private func buildTemperatureConversion(value: Double, from: String, to: String) -> String? {
        let f = normalizeTemp(from)
        let t = normalizeTemp(to)
        guard let f = f, let t = t else { return nil }

        if f == t { return "\(value)" }

        switch (f, t) {
        case ("c", "f"): return "\(value) * 9/5 + 32"
        case ("f", "c"): return "(\(value) - 32) * 5/9"
        case ("c", "k"): return "\(value) + 273.15"
        case ("k", "c"): return "\(value) - 273.15"
        case ("f", "k"): return "(\(value) - 32) * 5/9 + 273.15"
        case ("k", "f"): return "(\(value) - 273.15) * 9/5 + 32"
        default: return nil
        }
    }

    private func normalizeTemp(_ unit: String) -> String? {
        switch unit {
        case "fahrenheit", "f": return "f"
        case "celsius", "c": return "c"
        case "kelvin", "k": return "k"
        default: return nil
        }
    }

    private struct UnitFactor {
        let category: String
        let factor: Double
    }

    private func unitToBase(_ unit: String) -> UnitFactor? {
        // Length -> meters
        let length: [String: Double] = [
            "mm": 0.001, "millimeter": 0.001, "millimeters": 0.001,
            "cm": 0.01, "centimeter": 0.01, "centimeters": 0.01,
            "m": 1.0, "meter": 1.0, "meters": 1.0,
            "km": 1000.0, "kilometer": 1000.0, "kilometers": 1000.0,
            "in": 0.0254, "inch": 0.0254, "inches": 0.0254,
            "ft": 0.3048, "foot": 0.3048, "feet": 0.3048,
            "yd": 0.9144, "yard": 0.9144, "yards": 0.9144,
            "mi": 1609.344, "mile": 1609.344, "miles": 1609.344,
            "nm": 1852.0, "nautical mile": 1852.0, "nautical miles": 1852.0
        ]
        if let f = length[unit] { return UnitFactor(category: "length", factor: f) }

        // Weight -> grams
        let weight: [String: Double] = [
            "mg": 0.001, "milligram": 0.001, "milligrams": 0.001,
            "g": 1.0, "gram": 1.0, "grams": 1.0,
            "kg": 1000.0, "kilogram": 1000.0, "kilograms": 1000.0,
            "oz": 28.3495, "ounce": 28.3495, "ounces": 28.3495,
            "lb": 453.592, "lbs": 453.592, "pound": 453.592, "pounds": 453.592,
            "ton": 907185.0, "tons": 907185.0, "short ton": 907185.0,
            "tonne": 1000000.0, "tonnes": 1000000.0, "metric ton": 1000000.0,
            "st": 6350.29, "stone": 6350.29
        ]
        if let f = weight[unit] { return UnitFactor(category: "weight", factor: f) }

        // Volume -> milliliters
        let volume: [String: Double] = [
            "ml": 1.0, "milliliter": 1.0, "milliliters": 1.0,
            "l": 1000.0, "liter": 1000.0, "liters": 1000.0,
            "gal": 3785.41, "gallon": 3785.41, "gallons": 3785.41,
            "qt": 946.353, "quart": 946.353, "quarts": 946.353,
            "pt": 473.176, "pint": 473.176, "pints": 473.176,
            "cup": 236.588, "cups": 236.588,
            "fl oz": 29.5735, "fluid ounce": 29.5735, "fluid ounces": 29.5735,
            "tbsp": 14.7868, "tablespoon": 14.7868, "tablespoons": 14.7868,
            "tsp": 4.92892, "teaspoon": 4.92892, "teaspoons": 4.92892
        ]
        if let f = volume[unit] { return UnitFactor(category: "volume", factor: f) }

        // Area -> square meters
        let area: [String: Double] = [
            "sq m": 1.0, "sqm": 1.0, "square meter": 1.0, "square meters": 1.0,
            "sq ft": 0.092903, "sqft": 0.092903, "square foot": 0.092903, "square feet": 0.092903,
            "sq yd": 0.836127, "square yard": 0.836127, "square yards": 0.836127,
            "acre": 4046.86, "acres": 4046.86,
            "hectare": 10000.0, "hectares": 10000.0, "ha": 10000.0,
            "sq km": 1000000.0, "square kilometer": 1000000.0, "square kilometers": 1000000.0,
            "sq mi": 2589988.0, "square mile": 2589988.0, "square miles": 2589988.0
        ]
        if let f = area[unit] { return UnitFactor(category: "area", factor: f) }

        // Speed -> m/s
        let speed: [String: Double] = [
            "m/s": 1.0, "meters per second": 1.0,
            "km/h": 0.277778, "kph": 0.277778, "kilometers per hour": 0.277778,
            "mph": 0.44704, "miles per hour": 0.44704,
            "knot": 0.514444, "knots": 0.514444, "kn": 0.514444,
            "ft/s": 0.3048, "feet per second": 0.3048
        ]
        if let f = speed[unit] { return UnitFactor(category: "speed", factor: f) }

        // Data -> bytes
        let data: [String: Double] = [
            "b": 1.0, "byte": 1.0, "bytes": 1.0,
            "kb": 1024.0, "kilobyte": 1024.0, "kilobytes": 1024.0,
            "mb": 1048576.0, "megabyte": 1048576.0, "megabytes": 1048576.0,
            "gb": 1073741824.0, "gigabyte": 1073741824.0, "gigabytes": 1073741824.0,
            "tb": 1099511627776.0, "terabyte": 1099511627776.0, "terabytes": 1099511627776.0,
            "pb": 1125899906842624.0, "petabyte": 1125899906842624.0
        ]
        if let f = data[unit] { return UnitFactor(category: "data", factor: f) }

        // Time -> seconds
        let time: [String: Double] = [
            "ms": 0.001, "millisecond": 0.001, "milliseconds": 0.001,
            "s": 1.0, "sec": 1.0, "second": 1.0, "seconds": 1.0,
            "min": 60.0, "minute": 60.0, "minutes": 60.0,
            "h": 3600.0, "hr": 3600.0, "hour": 3600.0, "hours": 3600.0,
            "day": 86400.0, "days": 86400.0,
            "week": 604800.0, "weeks": 604800.0,
            "month": 2592000.0, "months": 2592000.0,
            "year": 31536000.0, "years": 31536000.0
        ]
        if let f = time[unit] { return UnitFactor(category: "time", factor: f) }

        return nil
    }

    // MARK: - Expression Sanitization

    /// Prevent code injection by only allowing mathematical expressions.
    private func sanitizeExpression(_ expr: String) -> String? {
        let trimmed = expr.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        // Block dangerous patterns
        let blockedPatterns = [
            "import", "exec(", "eval(", "compile(", "open(",
            "__", "os.", "sys.", "subprocess", "shutil",
            "lambda", "class ", "def ", "while ", "for ",
            "globals", "locals", "getattr", "setattr", "delattr",
            "breakpoint", "input(", "print(", "exit(", "quit(",
            "builtins", "dir(", "vars(", "help(",
            ";", "\\n"
        ]

        let lower = trimmed.lowercased()
        for blocked in blockedPatterns {
            if lower.contains(blocked) {
                logger.warning("Blocked expression containing '\(blocked)': \(trimmed)")
                return nil
            }
        }

        // Allow only safe characters: digits, operators, parens, brackets, dots, commas, spaces,
        // letters (for function names like sqrt, sin, cos, log, etc.)
        let allowedCharSet = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "+-*/().,%[] _<>=!|&~^"))
        let exprCharSet = CharacterSet(charactersIn: trimmed)
        guard exprCharSet.isSubset(of: allowedCharSet) else {
            return nil
        }

        return trimmed
    }

    // MARK: - Python Execution

    private func runPython(_ code: String) async -> Result<String, MathError> {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", code]
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = ["PATH": "/usr/bin:/usr/local/bin"]

        do {
            try process.run()

            // Wait for completion with 10-second timeout
            let processResult: Bool = await withCheckedContinuation { continuation in
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
                var completed = false
                let lock = NSLock()

                timer.schedule(deadline: .now() + 10)
                timer.setEventHandler {
                    lock.lock()
                    if !completed {
                        completed = true
                        lock.unlock()
                        process.terminate()
                        continuation.resume(returning: false)
                    } else {
                        lock.unlock()
                    }
                }
                timer.resume()

                DispatchQueue.global().async {
                    process.waitUntilExit()
                    lock.lock()
                    if !completed {
                        completed = true
                        lock.unlock()
                        timer.cancel()
                        continuation.resume(returning: true)
                    } else {
                        lock.unlock()
                    }
                }
            }

            if !processResult {
                return .failure(MathError(message: "Computation timed out after 10 seconds. Simplify the calculation or reduce iterations."))
            }

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errData, encoding: .utf8) ?? ""

            if process.terminationStatus == 0 {
                return .success(output)
            } else {
                let lines = errorOutput.components(separatedBy: "\n")
                let errorLine = lines.last(where: { !$0.isEmpty }) ?? errorOutput
                return .failure(MathError(message: errorLine))
            }
        } catch {
            return .failure(MathError(message: "Failed to run python3: \(error.localizedDescription)"))
        }
    }

    // MARK: - Helpers

    private func extractNumber(_ params: [String: Any], key: String) -> Double? {
        if let d = params[key] as? Double { return d }
        if let i = params[key] as? Int { return Double(i) }
        if let s = params[key] as? String, let d = Double(s) { return d }
        return nil
    }

    private func formatNumber(_ value: Double) -> String {
        if value == floor(value) && abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        return String(value)
    }

    private func pythonPrint(_ message: String) -> String {
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        return "print(\"\(escaped)\")"
    }
}

// MARK: - Display Info Provider

extension MathOperationsTool: ToolDisplayInfoProvider {
    public static func extractDisplayInfo(from arguments: [String: Any]) -> String? {
        guard let operation = arguments["operation"] as? String else {
            return nil
        }

        switch operation {
        case "calculate":
            if let expr = arguments["expression"] as? String {
                let short = expr.count > 40 ? String(expr.prefix(40)) + "..." : expr
                return "Calculating: \(short)"
            }
            return "Calculating"

        case "convert":
            if let from = arguments["from"] as? String,
               let to = arguments["to"] as? String {
                return "Converting \(from) to \(to)"
            }
            return "Converting units"

        case "formula":
            if let formula = arguments["formula"] as? String {
                return "Computing \(formula)"
            }
            return "Computing formula"

        default:
            return "Math operation"
        }
    }

    public static func extractToolDetails(from arguments: [String: Any]) -> [String]? {
        guard let operation = arguments["operation"] as? String else {
            return nil
        }

        var details: [String] = ["Operation: \(operation)"]

        switch operation {
        case "calculate":
            if let expr = arguments["expression"] as? String {
                details.append("Expression: \(expr)")
            }
        case "convert":
            if let value = arguments["value"],
               let from = arguments["from"] as? String,
               let to = arguments["to"] as? String {
                details.append("\(value) \(from) → \(to)")
            }
        case "formula":
            if let formula = arguments["formula"] as? String {
                details.append("Formula: \(formula)")
            }
        default:
            break
        }

        return details
    }
}
