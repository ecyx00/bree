//! This integration crate intentionally uses only installed public paths.

use bree::{
    Browser, BrowserAttachment, BrowserViewerResizeResult, Client, Config, CreateScreenOptions,
    CreationResolution, Error, Machine, Pane, PixelSize, Screen, Selector, Session, Size, Tab,
    Terminal, TerminalAttachment, TerminalWaitExitResult, UndoLayoutOptions, ViewerReleaseResult,
    ViewerResizeResult, Workspace, WorkspaceId,
};

#[test]
fn clean_consumer_imports_high_level_and_raw_namespaces_together() {
    type PublicHandles = (
        Option<Client>,
        Option<Machine>,
        Option<Session>,
        Option<Workspace>,
        Option<Screen>,
        Option<Pane>,
        Option<Tab>,
        Option<Terminal>,
        Option<Browser>,
    );
    fn high_level_types(_: PublicHandles) {}
    fn raw_types(_: bree::raw::PingRequest, _: Option<bree::raw::Client>) {}

    let selector = Selector::<WorkspaceId>::name("same name");
    assert_eq!(selector.exact_name(), Some("same name"));
    high_level_types((None, None, None, None, None, None, None, None, None));
    raw_types(bree::raw::PingRequest::default(), None);
    let _config = Config::from_env_or_default_session("consumer");

    fn typed_recovery_reads(session: &Session, terminal: &Terminal) {
        let _: bree::Result<CreationResolution> =
            session.creation().resolve("consumer-correlation");
        let _: bree::Result<TerminalWaitExitResult> = terminal.wait_exit(Some(0));
    }
    let _ = typed_recovery_reads as fn(&Session, &Terminal);
    let _: fn(&mut TerminalAttachment, Size) -> bree::Result<ViewerResizeResult> =
        TerminalAttachment::resize;
    let _: fn(&mut TerminalAttachment) -> bree::Result<ViewerReleaseResult> =
        TerminalAttachment::release;
    let _: fn(&mut BrowserAttachment, PixelSize) -> bree::Result<BrowserViewerResizeResult> =
        BrowserAttachment::resize;
    let _: fn(&mut BrowserAttachment) -> bree::Result<ViewerReleaseResult> =
        BrowserAttachment::release;
    let _undo = UndoLayoutOptions {
        confirm_close: true,
        confirmation_token: Some("preview-token".to_string()),
    };
    let _creation = CreateScreenOptions::default().correlation_key("consumer-correlation").unwrap();
    fn typed_confirmation(error: Error) -> Option<bree::ConfirmationRequiredDetails> {
        match error {
            Error::ConfirmationRequired { details, .. } => Some(details),
            _ => None,
        }
    }
    let _ = typed_confirmation as fn(Error) -> Option<bree::ConfirmationRequiredDetails>;
}

#[test]
fn newly_cataloged_raw_commands_are_public() {
    let _: fn(
        &mut bree::raw::Client,
        bree::raw::BrowserFramePresentedRequest,
    ) -> bree::raw::Result<bree::raw::BrowserFramePresentedResult> =
        bree::raw::Client::browser_frame_presented;
    let _: fn(
        &mut bree::raw::Client,
        bree::raw::BrowserKeyPressRequest,
    ) -> bree::raw::Result<bree::raw::BrowserKeyPressResult> = bree::raw::Client::browser_key_press;
    let _: fn(
        &mut bree::raw::Client,
        bree::raw::BrowserMouseGuardedRequest,
    ) -> bree::raw::Result<bree::raw::BrowserMouseGuardedResult> =
        bree::raw::Client::browser_mouse_guarded;
    let _: fn(
        &mut bree::raw::Client,
        bree::raw::BrowserWheelGuardedRequest,
    ) -> bree::raw::Result<bree::raw::BrowserWheelGuardedResult> =
        bree::raw::Client::browser_wheel_guarded;
    let _: fn(
        &mut bree::raw::Client,
        bree::raw::ClearHistoryRequest,
    ) -> bree::raw::Result<bree::raw::ClearHistoryResult> = bree::raw::Client::clear_history;
    let _: fn(
        &mut bree::raw::Client,
        bree::raw::NewPaneRightRequest,
    ) -> bree::raw::Result<bree::raw::NewPaneRightResult> = bree::raw::Client::new_pane_right;
    let _: fn(
        &mut bree::raw::Client,
        bree::raw::SetViewportPaneWidthRequest,
    ) -> bree::raw::Result<bree::raw::SetViewportPaneWidthResult> =
        bree::raw::Client::set_viewport_pane_width;
    let _: fn(
        &mut bree::raw::Client,
        bree::raw::UndoLayoutRequest,
    ) -> bree::raw::Result<bree::raw::UndoLayoutResult> = bree::raw::Client::undo_layout;

    assert_eq!(
        [
            bree::raw::BROWSER_FRAME_PRESENTED_METADATA.name,
            bree::raw::BROWSER_KEY_PRESS_METADATA.name,
            bree::raw::BROWSER_MOUSE_GUARDED_METADATA.name,
            bree::raw::BROWSER_WHEEL_GUARDED_METADATA.name,
            bree::raw::CLEAR_HISTORY_METADATA.name,
            bree::raw::NEW_PANE_RIGHT_METADATA.name,
            bree::raw::SET_VIEWPORT_PANE_WIDTH_METADATA.name,
            bree::raw::UNDO_LAYOUT_METADATA.name,
        ],
        [
            "browser-frame-presented",
            "browser-key-press",
            "browser-mouse-guarded",
            "browser-wheel-guarded",
            "clear-history",
            "new-pane-right",
            "set-viewport-pane-width",
            "undo-layout",
        ]
    );
}
