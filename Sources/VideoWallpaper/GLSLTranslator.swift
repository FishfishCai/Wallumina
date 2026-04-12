import Foundation

/// Translates Wallpaper Engine GLSL effect shaders to Metal Shading Language
struct GLSLTranslator {

    /// Translate a WE fragment shader to MSL
    static func translateFragment(source: String, name: String, includes: [String: String] = [:]) -> String {
        var src = resolveIncludes(source, includes: includes)
        src = stripComments(src)

        // Parse declarations
        let varyings = parseDeclarations(src, keyword: "varying")
        let uniforms = parseUniforms(src)
        let samplerUniforms = uniforms.filter { $0.type == "sampler2D" }
        let valueUniforms = uniforms.filter { $0.type != "sampler2D" }

        // Remove original declarations
        src = removeLines(src, containing: ["varying ", "uniform ", "attribute ", "#version", "#include", "#extension"])
        // Remove COMBO comments
        src = removeLines(src, containing: ["// [COMBO", "// [OFF_COMBO"])

        // Apply WE macro replacements
        src = applyMacros(src)

        // Replace texture sampling
        for su in samplerUniforms {
            // texSample2D(g_TextureN, uv) → g_TextureN.sample(s, uv)
            src = replaceTextureSampling(src, samplerName: su.name)
        }

        // Replace gl_FragColor
        src = src.replacingOccurrences(of: "gl_FragColor", with: "_fragColor")

        // Build MSL
        var msl = "#include <metal_stdlib>\nusing namespace metal;\n\n"

        // Fragment input struct (from varyings)
        msl += "struct Frag_\(name)_In {\n"
        msl += "    float4 position [[position]];\n"
        for v in varyings {
            msl += "    \(glslTypeToMSL(v.type)) \(v.name);\n"
        }
        msl += "};\n\n"

        // Uniforms buffer struct
        msl += "struct Frag_\(name)_Uniforms {\n"
        msl += "    float g_Time;\n"
        msl += "    float g_Daytime;\n"
        msl += "    float2 g_PointerPosition;\n"
        msl += "    float2 g_TexelSize;\n"
        msl += "    float2 g_TexelSizeHalf;\n"
        for u in valueUniforms {
            if ["g_Time", "g_Daytime"].contains(u.name) { continue }
            msl += "    \(glslTypeToMSL(u.type)) \(u.name);\n"
        }
        msl += "};\n\n"

        // Extract main() body
        let mainBody = extractMainBody(src)

        // Fragment function
        msl += "fragment float4 frag_\(name)(\n"
        msl += "    Frag_\(name)_In in [[stage_in]],\n"
        msl += "    constant Frag_\(name)_Uniforms &u [[buffer(0)]],\n"
        for (i, su) in samplerUniforms.enumerated() {
            msl += "    texture2d<float> \(su.name) [[texture(\(i))]],\n"
        }
        msl += "    sampler s [[sampler(0)]])\n{\n"

        // Declare locals from varyings
        for v in varyings {
            msl += "    \(glslTypeToMSL(v.type)) \(v.name) = in.\(v.name);\n"
        }
        // Declare uniform access shortcuts
        msl += "    float g_Time = u.g_Time;\n"
        for u2 in valueUniforms {
            if u2.name == "g_Time" { continue }
            msl += "    \(glslTypeToMSL(u2.type)) \(u2.name) = u.\(u2.name);\n"
        }
        msl += "    float4 _fragColor = float4(0);\n"
        msl += mainBody
        msl += "    return _fragColor;\n"
        msl += "}\n"

        return msl
    }

    /// Translate a WE vertex shader to MSL (effect pass — fullscreen quad)
    static func translateVertex(source: String, name: String, includes: [String: String] = [:]) -> String {
        var src = resolveIncludes(source, includes: includes)
        src = stripComments(src)

        let varyings = parseDeclarations(src, keyword: "varying")
        let uniforms = parseUniforms(src)
        let valueUniforms = uniforms.filter { $0.type != "sampler2D" }

        src = removeLines(src, containing: ["varying ", "uniform ", "attribute ", "#version", "#include", "#extension"])
        src = removeLines(src, containing: ["// [COMBO", "// [OFF_COMBO"])
        src = applyMacros(src)

        // Replace gl_Position and a_Position/a_TexCoord
        src = src.replacingOccurrences(of: "gl_Position", with: "_position")
        src = src.replacingOccurrences(of: "a_Position", with: "_aPos")
        src = src.replacingOccurrences(of: "a_TexCoord", with: "_aUV")

        var msl = "#include <metal_stdlib>\nusing namespace metal;\n\n"

        // Output struct
        msl += "struct Vert_\(name)_Out {\n"
        msl += "    float4 position [[position]];\n"
        for v in varyings {
            msl += "    \(glslTypeToMSL(v.type)) \(v.name);\n"
        }
        msl += "};\n\n"

        // Uniforms
        msl += "struct Vert_\(name)_Uniforms {\n"
        msl += "    float g_Time;\n"
        msl += "    float g_Daytime;\n"
        msl += "    float2 g_PointerPosition;\n"
        msl += "    float2 g_TexelSize;\n"
        msl += "    float2 g_TexelSizeHalf;\n"
        for u in valueUniforms {
            if ["g_Time", "g_Daytime", "g_ModelViewProjectionMatrix"].contains(u.name) { continue }
            msl += "    \(glslTypeToMSL(u.type)) \(u.name);\n"
        }
        msl += "};\n\n"

        let mainBody = extractMainBody(src)

        msl += "vertex Vert_\(name)_Out vert_\(name)(\n"
        msl += "    uint vid [[vertex_id]],\n"
        msl += "    constant Vert_\(name)_Uniforms &u [[buffer(0)]])\n{\n"
        msl += "    float2 quadPos[4] = { {-1,-1}, {1,-1}, {-1,1}, {1,1} };\n"
        msl += "    float2 quadUV[4] = { {0,1}, {1,1}, {0,0}, {1,0} };\n"
        msl += "    float3 _aPos = float3(quadPos[vid], 0);\n"
        msl += "    float2 _aUV = quadUV[vid];\n"
        msl += "    float4x4 g_ModelViewProjectionMatrix = float4x4(1);\n"
        msl += "    float g_Time = u.g_Time;\n"
        for u2 in valueUniforms {
            if ["g_Time", "g_ModelViewProjectionMatrix"].contains(u2.name) { continue }
            msl += "    \(glslTypeToMSL(u2.type)) \(u2.name) = u.\(u2.name);\n"
        }

        // Declare varyings as locals
        for v in varyings {
            msl += "    \(glslTypeToMSL(v.type)) \(v.name);\n"
        }
        msl += "    float4 _position;\n"
        msl += mainBody

        // Build output
        msl += "    Vert_\(name)_Out out;\n"
        msl += "    out.position = float4(quadPos[vid], 0, 1);\n"
        for v in varyings {
            msl += "    out.\(v.name) = \(v.name);\n"
        }
        msl += "    return out;\n"
        msl += "}\n"

        return msl
    }

    // MARK: - Helpers

    struct Decl { let type: String; let name: String }

    private static func parseDeclarations(_ src: String, keyword: String) -> [Decl] {
        var result: [Decl] = []
        for line in src.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(keyword + " ") else { continue }
            let parts = trimmed.replacingOccurrences(of: ";", with: "")
                .split(separator: " ").map(String.init)
            if parts.count >= 3 {
                result.append(Decl(type: parts[1], name: parts[2]))
            }
        }
        return result
    }

    private static func parseUniforms(_ src: String) -> [Decl] {
        var result: [Decl] = []
        for line in src.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("uniform ") else { continue }
            let cleaned = trimmed.replacingOccurrences(of: ";", with: "")
            // Remove trailing // comments
            let noComment = cleaned.split(separator: "/").first.map(String.init) ?? cleaned
            let parts = noComment.trimmingCharacters(in: .whitespaces)
                .split(separator: " ").map(String.init)
            if parts.count >= 3 {
                result.append(Decl(type: parts[1], name: parts[2]))
            }
        }
        return result
    }

    private static func resolveIncludes(_ src: String, includes: [String: String]) -> String {
        var result = src
        // Simple #include "filename" resolution
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        var output: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#include") {
                // Extract filename
                if let start = trimmed.firstIndex(of: "\""),
                   let end = trimmed[trimmed.index(after: start)...].firstIndex(of: "\"") {
                    let filename = String(trimmed[trimmed.index(after: start)..<end])
                    let key = filename.hasSuffix(".h") ? filename : filename + ".h"
                    if let content = includes[key] ?? includes["shaders/" + key] {
                        output.append(content)
                    }
                }
            } else {
                output.append(String(line))
            }
        }
        return output.joined(separator: "\n")
    }

    private static func stripComments(_ src: String) -> String {
        src.replacing(/\/\*[\s\S]*?\*\//, with: "")
    }

    private static func removeLines(_ src: String, containing keywords: [String]) -> String {
        src.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !keywords.contains(where: { trimmed.hasPrefix($0) })
            }
            .joined(separator: "\n")
    }

    private static func applyMacros(_ src: String) -> String {
        var s = src
        // WE macro expansions
        s = s.replacingOccurrences(of: "lerp", with: "mix")
        s = s.replacingOccurrences(of: "frac(", with: "fract(")
        s = s.replacingOccurrences(of: "CAST2(", with: "float2(")
        s = s.replacingOccurrences(of: "CAST3(", with: "float3(")
        s = s.replacingOccurrences(of: "CAST4(", with: "float4(")
        s = s.replacingOccurrences(of: "CAST3X3(", with: "float3x3(")
        s = s.replacingOccurrences(of: "ddx(", with: "dfdx(")
        // Type replacements
        s = s.replacingOccurrences(of: "vec2", with: "float2")
        s = s.replacingOccurrences(of: "vec3", with: "float3")
        s = s.replacingOccurrences(of: "vec4", with: "float4")
        s = s.replacingOccurrences(of: "mat2", with: "float2x2")
        s = s.replacingOccurrences(of: "mat3", with: "float3x3")
        s = s.replacingOccurrences(of: "mat4", with: "float4x4")
        // Function replacements
        s = s.replacingOccurrences(of: "dFdx(", with: "dfdx(")
        s = s.replacingOccurrences(of: "dFdy(", with: "dfdy(")
        // mul(a, b) → ((b) * (a)) — WE reverses matrix multiply order
        // Handle nested parens by finding balanced match
        while let mulRange = s.range(of: "mul(") {
            let start = mulRange.upperBound
            var depth = 1; var pos = start; var commaPos: String.Index?
            while pos < s.endIndex && depth > 0 {
                if s[pos] == "(" { depth += 1 }
                else if s[pos] == ")" { depth -= 1 }
                else if s[pos] == "," && depth == 1 && commaPos == nil { commaPos = pos }
                if depth > 0 { pos = s.index(after: pos) }
            }
            guard let cp = commaPos, depth == 0 else { break }
            let arg1 = String(s[start..<cp]).trimmingCharacters(in: .whitespaces)
            let arg2 = String(s[s.index(after: cp)..<pos]).trimmingCharacters(in: .whitespaces)
            s.replaceSubrange(mulRange.lowerBound...pos, with: "((\(arg2)) * (\(arg1)))")
        }
        return s
    }

    private static func replaceTextureSampling(_ src: String, samplerName: String) -> String {
        var s = src
        // texSample2D(g_TextureN, uv) → g_TextureN.sample(s, uv)
        let pattern = "texSample2D(\\s*\(samplerName)\\s*,"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range,
                                                withTemplate: "\(samplerName).sample(s,")
        }
        // texSample2DLod(g_TextureN, uv, lod) → g_TextureN.sample(s, uv, level(lod))
        let lodPattern = "texSample2DLod(\\s*\(samplerName)\\s*,"
        if let regex = try? NSRegularExpression(pattern: lodPattern) {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range,
                                                withTemplate: "\(samplerName).sample(s,")
        }
        return s
    }

    private static func glslTypeToMSL(_ type: String) -> String {
        switch type {
        case "vec2": return "float2"
        case "vec3": return "float3"
        case "vec4": return "float4"
        case "mat2": return "float2x2"
        case "mat3": return "float3x3"
        case "mat4": return "float4x4"
        case "sampler2D": return "texture2d<float>"
        default: return type
        }
    }

    private static func extractMainBody(_ src: String) -> String {
        // Find void main() { ... } and extract the body
        guard let mainRange = src.range(of: "void main()") ??
              src.range(of: "void main ()") else { return "" }
        let afterMain = src[mainRange.upperBound...]
        guard let braceStart = afterMain.firstIndex(of: "{") else { return "" }

        var depth = 0
        var bodyStart = src.index(after: braceStart)
        var bodyEnd = bodyStart
        for i in src[braceStart...].indices {
            if src[i] == "{" { depth += 1 }
            if src[i] == "}" { depth -= 1; if depth == 0 { bodyEnd = i; break } }
        }
        return String(src[bodyStart..<bodyEnd])
    }
}

// MARK: - Convenience for common.h

/// Build a minimal common.h that WE shaders expect
let weCommonH = """
float2 rotateVec2(float2 v, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return float2(v.x * c - v.y * s, v.x * s + v.y * c);
}
"""
