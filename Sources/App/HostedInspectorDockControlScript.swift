struct HostedInspectorDockControlScript {
    let allowSideDock: Bool
    let detachedFromHostWindow: Bool

    var source: String {
        let allowSideDockLiteral = allowSideDock ? "true" : "false"
        let detachedFromHostWindowLiteral = detachedFromHostWindow ? "true" : "false"
        return """
        (() => {
            if (typeof WI === "undefined")
                return null;
            const allowSideDock = \(allowSideDockLiteral);
            const detachedFromHostWindow = \(detachedFromHostWindowLiteral);
            function callOriginal(fn, event) {
                return typeof fn === "function" ? fn.call(WI, event) : null;
            }
            function installWrapper(methodName, originalName, wrapper) {
                if (typeof WI[originalName] !== "function") {
                    if (typeof WI[methodName] !== "function")
                        return false;
                    WI[originalName] = WI[methodName];
                }
                WI[methodName] = wrapper;
                return true;
            }
            function updateButton(button, hidden) {
                if (!button)
                    return;
                button.hidden = hidden;
                if (button.element) {
                    button.element.style.display = hidden ? "none" : "";
                    button.element.style.pointerEvents = hidden ? "none" : "";
                }
            }
            function updateButtons(buttons, hidden) {
                for (const button of buttons)
                    updateButton(button, hidden);
            }
            function dockMatches(enumValue, literal) {
                const configuration = WI.dockConfiguration;
                if (configuration === enumValue)
                    return true;
                return String(configuration).toLowerCase() === literal;
            }
            function enforceDockControls() {
                const disallowSideDock = !WI.__breeAllowSideDock;
                const dockConfiguration = WI.DockConfiguration || {};
                const dockedLeft = dockMatches(dockConfiguration.Left, "left");
                const dockedRight = dockMatches(dockConfiguration.Right, "right");
                const dockedBottom = !WI.__breeDetachedFromHostWindow &&
                    dockMatches(dockConfiguration.Bottom, "bottom");
                const detached = WI.__breeDetachedFromHostWindow ||
                    dockMatches(dockConfiguration.Detached, "detached") ||
                    dockMatches(dockConfiguration.Undocked, "undocked");
                updateButton(WI._dockLeftTabBarButton, disallowSideDock || (!detached && dockedLeft));
                updateButton(WI._dockRightTabBarButton, disallowSideDock || (!detached && dockedRight));
                updateButtons([
                    WI._dockBottomTabBarButton,
                    WI._dockBottomNavigationItem,
                    WI._dockBottomButton,
                ], !detached && dockedBottom);
                updateButtons([
                    WI._detachTabBarButton,
                    WI._detachNavigationItem,
                    WI._undockTabBarButton,
                    WI._undockButton,
                ], detached);
            }
            WI.__breeAllowSideDock = allowSideDock;
            WI.__breeDetachedFromHostWindow = detachedFromHostWindow;
            installWrapper("_dockLeft", "__breeOriginalDockLeft", function(event) {
                if (!WI.__breeAllowSideDock)
                    return callOriginal(WI._dockBottom, event);
                return callOriginal(WI.__breeOriginalDockLeft, event);
            });
            installWrapper("_dockRight", "__breeOriginalDockRight", function(event) {
                if (!WI.__breeAllowSideDock)
                    return callOriginal(WI._dockBottom, event);
                return callOriginal(WI.__breeOriginalDockRight, event);
            });
            installWrapper("_togglePreviousDockConfiguration", "__breeOriginalTogglePreviousDockConfiguration", function(event) {
                const dockConfiguration = WI.DockConfiguration || {};
                const previousSideDock = WI._previousDockConfiguration === dockConfiguration.Left ||
                    WI._previousDockConfiguration === dockConfiguration.Right;
                if (!WI.__breeAllowSideDock && previousSideDock)
                    return callOriginal(WI._dockBottom, event);
                return callOriginal(WI.__breeOriginalTogglePreviousDockConfiguration, event);
            });
            installWrapper("_updateDockNavigationItems", "__breeOriginalUpdateDockNavigationItems", function(...args) {
                if (typeof WI.__breeOriginalUpdateDockNavigationItems === "function")
                    WI.__breeOriginalUpdateDockNavigationItems.apply(WI, args);
                enforceDockControls();
            });
            if (typeof WI._updateDockNavigationItems === "function")
                WI._updateDockNavigationItems();
            else
                enforceDockControls();
            return WI.__breeAllowSideDock;
        })();
        """
    }
}
