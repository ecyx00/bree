/// Compatibility JavaScript generation for browser keyboard events.
extension BrowserControlService {
    /// Builds the fallback script for one keyboard automation action.
    ///
    /// The macOS host normally replays canonical keys through WebKit's native
    /// input boundary so browser default actions receive trusted events. This
    /// script remains for opaque key tokens that cannot be represented by a
    /// platform key event and for callers that only need page-level handlers.
    ///
    /// - Parameters:
    ///   - action: Whether to press, hold down, or release the key.
    ///   - event: Canonical DOM fields resolved by ``BrowserKeyboardEvent``.
    /// - Returns: A self-invoking JavaScript expression.
    public func keyboardScript(action: BrowserKeyboardAction, event: BrowserKeyboardEvent) -> String {
        let actionBody: String
        switch action {
        case .press:
            actionBody = """
              const __breeKeyDownNotPrevented = __breeDispatchKey(target, 'keydown');
              let __breeKeyPressNotPrevented = true;
              if (__breeKeyValue.length === 1 || __breeKeyValue === 'Enter') {
                __breeKeyPressNotPrevented = __breeDispatchKey(target, 'keypress');
              }
              const __breeKeyUpNotPrevented = __breeDispatchKey(target, 'keyup');

              // Synthetic keyboard events do not invoke WebKit's activation behavior. A DOM click
              // reproduces keyboard activation (detail === 0) for controls that natively activate
              // on Space, while honoring handlers that canceled any part of the key sequence.
              if (__breeKeyValue === ' ' && __breeKeyDownNotPrevented && __breeKeyPressNotPrevented && __breeKeyUpNotPrevented && __breeSpaceActivates(target)) {
                try { target.click(); } catch (_) {}
              }

              // Synthetic Enter events also do not run WebKit's implicit form-submission default.
              // Preserve the existing behavior for a focused single-line text-like form field.
              if (__breeKeyValue === 'Enter' && __breeKeyDownNotPrevented && __breeKeyPressNotPrevented && target && target.tagName === 'INPUT' && target.form) {
                const submitTypes = ['text','search','email','url','tel','password','number','date','datetime-local','month','week','time'];
                if (submitTypes.indexOf((target.type || 'text').toLowerCase()) !== -1) {
                  const hasSubmit = !!target.form.querySelector('input[type=submit],input[type=image],button[type=submit],button:not([type])');
                  const textFields = target.form.querySelectorAll('input[type=text],input[type=search],input[type=email],input[type=url],input[type=tel],input[type=password],input[type=number],input[type=date],input[type=datetime-local],input[type=month],input[type=week],input[type=time],input:not([type])');
                  if (hasSubmit || textFields.length === 1) {
                    try { if (target.form.requestSubmit) { target.form.requestSubmit(); } else { target.form.submit(); } } catch (_) {}
                  }
                }
              }
            """
        case .keyDown:
            actionBody = "__breeDispatchKey(target, 'keydown');"
        case .keyUp:
            actionBody = "__breeDispatchKey(target, 'keyup');"
        }

        let keyLiteral = jsonLiteral(event.key)
        let codeLiteral = jsonLiteral(event.code)
        return """
        (() => {
          const __breeKeyValue = \(keyLiteral);
          const __breeCodeValue = \(codeLiteral);
          const __breeLegacyKeyCode = \(event.legacyKeyCode);
          const __breeLocation = \(event.location);
          const __breeDispatchKey = (target, type) => {
            const keyboardEvent = new KeyboardEvent(type, {
              key: __breeKeyValue,
              code: __breeCodeValue,
              location: __breeLocation,
              repeat: false,
              isComposing: false,
              bubbles: true,
              cancelable: true,
              composed: true,
              view: window
            });
            try { Object.defineProperty(keyboardEvent, 'keyCode', { get() { return __breeLegacyKeyCode; } }); } catch (_) {}
            try { Object.defineProperty(keyboardEvent, 'which', { get() { return __breeLegacyKeyCode; } }); } catch (_) {}
            return target.dispatchEvent(keyboardEvent);
          };
          const __breeSpaceActivates = (target) => {
            if (!target || typeof target.matches !== 'function') return false;
            return target.matches('button,input[type=button],input[type=submit],input[type=reset],input[type=checkbox],input[type=radio]');
          };
          const target = document.activeElement || document.body || document.documentElement;
          if (!target) return { ok: false, error: 'not_found' };
        \(actionBody)
          return { ok: true };
        })()
        """
    }
}
