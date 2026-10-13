import Foundation

extension BrowserControlService {
    /// Builds the async function body used by browser automation and user evals.
    ///
    /// DOM rectangles must become plain geometry objects in the web process:
    /// WebKit on macOS 15 can crash the host while deserializing a native DOMRect,
    /// before Swift-side normalization gets a chance to run.
    ///
    /// - Parameters:
    ///   - script: JavaScript to execute.
    ///   - useEval: Whether to evaluate a script string or insert a trusted expression.
    ///   - frameSelector: Optional same-origin frame supplying `document`.
    /// - Returns: A function body that awaits and wraps a bridge-safe result.
    public func evaluationScript(
        script: String,
        useEval: Bool,
        frameSelector: String?
    ) -> String {
        let framePrelude: String
        if let frameSelector {
            framePrelude = """
            let __breeDoc = document;
            try {
              const __breeFrame = document.querySelector(\(jsonLiteral(frameSelector)));
              if (__breeFrame && __breeFrame.contentDocument) {
                __breeDoc = __breeFrame.contentDocument;
              }
            } catch (_) {}
            """
        } else {
            framePrelude = "const __breeDoc = document;"
        }

        let executionBlock = useEval
            ? "const __r = eval(\(jsonLiteral(script)));"
            : "const __r = \(script);"
        let circularReferenceMessage = jsonLiteral(String(
            localized: "cli.browser.error.circularEvaluationResult",
            defaultValue: "Browser evaluation result contains a circular reference"
        ))

        return """
        \(framePrelude)

        const __breeMaybeAwait = async (__r) => {
          if (__r !== null && (typeof __r === 'object' || typeof __r === 'function') && typeof __r.then === 'function') {
            return await __r;
          }
          return __r;
        };

        const __breeAncestors = new WeakSet();
        const __breeCopies = new WeakMap();
        const __breeBridgeSafeValue = (__value) => {
          if (__value === null || typeof __value !== 'object') {
            return __value;
          }
          if (__breeAncestors.has(__value)) {
            throw new Error(\(circularReferenceMessage));
          }
          if (__breeCopies.has(__value)) {
            return __breeCopies.get(__value);
          }

          // Brand checks also recognize rectangles and containers from iframes.
          const __tag = Object.prototype.toString.call(__value);
          const __isRect =
            (typeof DOMRectReadOnly !== 'undefined' && __value instanceof DOMRectReadOnly) ||
            __tag === '[object DOMRect]' || __tag === '[object DOMRectReadOnly]';
          const __isArray = Array.isArray(__value);
          if (!__isRect && !__isArray && __tag !== '[object Object]') {
            return __value;
          }

          __breeAncestors.add(__value);
          try {
            const __copy = __isArray ? [] : {};
            __breeCopies.set(__value, __copy);
            const __keys = __isRect
              ? ['x', 'y', 'width', 'height', 'top', 'right', 'bottom', 'left']
              : Object.keys(__value);
            if (__isArray) {
              __copy.length = __value.length;
            }
            for (const __key of __keys) {
              // Define own properties so a literal "__proto__" key stays data.
              Object.defineProperty(__copy, __key, {
                value: __breeBridgeSafeValue(__value[__key]),
                enumerable: true,
                configurable: true,
                writable: true
              });
            }
            return __copy;
          } finally {
            __breeAncestors.delete(__value);
          }
        };

        const __breeEvalInFrame = async function() {
          const document = __breeDoc;
          \(executionBlock)
          const __value = await __breeMaybeAwait(__r);
          return {
            [\(jsonLiteral(evalEnvelope.typeKey))]: (typeof __value === 'undefined')
              ? \(jsonLiteral(evalEnvelope.typeUndefined)) : \(jsonLiteral(evalEnvelope.typeValue)),
            [\(jsonLiteral(evalEnvelope.valueKey))]: __breeBridgeSafeValue(__value)
          };
        };

        return await __breeEvalInFrame();
        """
    }
}
