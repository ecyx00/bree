#include <bree/client.hpp>
#include <bree/raw/client.hpp>
#include <bree/version.hpp>

#include <cstdint>
#include <optional>
#include <type_traits>
#include <utility>

static_assert(std::is_same_v<
              decltype(std::declval<bree::Workspace&>().refresh()),
              bree::Result<bree::WorkspaceSnapshot>>);
static_assert(std::is_same_v<
              decltype(std::declval<bree::Terminal&>().wait_exit()),
              bree::Result<bree::TerminalWaitExitResult>>);
static_assert(std::is_same_v<
              decltype(std::declval<bree::Terminal&>().read_history(
                  std::declval<bree::TerminalHistoryOptions>())),
              bree::Result<bree::TerminalHistoryResult>>);
static_assert(std::is_same_v<
              decltype(std::declval<bree::Terminal&>().attach(
                  std::declval<bree::TerminalAttachOptions>(),
                  std::declval<bree::CallOptions>())),
              bree::Result<bree::TerminalAttachmentStream>>);
static_assert(std::is_same_v<
              decltype(std::declval<bree::BrowserAttachFrame>()
                           .pointer_frame_seq),
              std::optional<std::uint64_t>>);
static_assert(std::is_same_v<
              decltype(std::declval<bree::Browser&>().mouse(
                  std::declval<bree::Json::Object>(),
                  std::declval<std::uint64_t>(),
                  std::declval<bree::MutationOptions>())),
              bree::Result<bree::MutationResult<bree::EmptyResult>>>);
static_assert(std::is_same_v<
              decltype(std::declval<bree::Browser&>().wheel(
                  std::declval<double>(),
                  std::declval<double>(),
                  std::declval<double>(),
                  std::declval<double>(),
                  std::declval<std::uint64_t>(),
                  std::declval<bree::MutationOptions>())),
              bree::Result<bree::MutationResult<bree::EmptyResult>>>);
static_assert(std::is_same_v<
              decltype(std::declval<bree::Workspace&>().run(
                  std::declval<bree::RunOptions>(),
                  std::declval<bree::MutationOptions>(),
                  std::declval<bree::CallOptions>())),
              bree::Result<
                  bree::MutationResult<bree::CreatedTerminalPath>>>);
static_assert(std::is_same_v<
              decltype(std::declval<bree::Session&>().notifications()),
              bree::Result<std::vector<bree::NotificationSnapshot>>>);
static_assert(std::is_same_v<
              decltype(std::declval<bree::Session&>().create_notification(
                  std::declval<bree::NotificationCreateOptions>(),
                  std::declval<bree::MutationOptions>())),
              bree::Result<
                  bree::MutationResult<bree::NotificationSnapshot>>>);
static_assert(std::is_same_v<
              decltype(std::declval<bree::Session&>().report_agent(
                  std::declval<bree::AgentReportOptions>(),
                  std::declval<bree::MutationOptions>())),
              bree::Result<bree::MutationResult<bree::AgentSnapshot>>>);
static_assert(std::is_same_v<
              decltype(std::declval<bree::raw::Client&>().identify()),
              bree::Result<bree::raw::IdentifyResult>>);
static_assert(!std::is_copy_constructible_v<bree::SessionEventStream>);
static_assert(std::is_nothrow_move_constructible_v<bree::SessionEventStream>);

int main() {
    auto id = bree::WorkspaceId::parse(
        "ws_0123456789abcdef0123456789abcdef");
    if (!id) {
        return 1;
    }
    const auto selector =
        bree::Selector<bree::WorkspaceId>::exact_name("current");
    auto command = bree::RunCommand::exact({"cargo", "test"});
    if (!command || command.value().argv().size() != 2) {
        return 1;
    }

    bree::CreateWorkspaceOptions workspace_create;
    workspace_create.correlation_key = "consumer-workspace";
    auto workspace_params = workspace_create.to_params();

    bree::RunOptions run(std::move(command).value());
    run.correlation_key = "consumer-run";
    auto run_params = run.to_params();

    bree::CreateScreenOptions screen_create;
    screen_create.correlation_key = "consumer-screen";
    auto screen_params = screen_create.to_params();

    bree::CreatePaneOptions pane_create;
    pane_create.correlation_key = "consumer-pane";
    auto pane_params = pane_create.to_params();

    bree::SplitPaneOptions pane_split(bree::PaneDirection::right);
    pane_split.correlation_key = "consumer-split";
    pane_split.viewport_width = 0.5;
    auto split_params = pane_split.to_params();

    bree::CreateTerminalTabOptions terminal_create;
    terminal_create.correlation_key = "consumer-terminal";
    auto terminal_params = terminal_create.to_params();

    bree::CreateBrowserTabOptions browser_create("https://example.com");
    browser_create.correlation_key = "consumer-browser";
    auto browser_params = browser_create.to_params();

    bree::TerminalHistoryOptions history;
    history.before = 50;
    history.limit = 100;
    history.styled = true;
    auto history_params = history.to_params();

    bree::TerminalAttachOptions attach;
    attach.cols = 120;
    attach.rows = 40;
    attach.read_only = true;
    auto attach_params = attach.to_params();

    auto terminal_id = bree::TerminalId::parse(
        "term_0123456789abcdef0123456789abcdef");
    if (!terminal_id) {
        return 1;
    }
    bree::NotificationCreateOptions notification("build", "complete");
    notification.level = bree::NotificationLevel::info;
    notification.terminal_id = terminal_id.value();
    auto notification_params = notification.to_params();

    bree::AgentReportOptions agent(
        terminal_id.value(),
        bree::AgentState::working,
        bree::AgentReportSource::socket);
    agent.source_session = "consumer";
    auto agent_params = agent.to_params();

    bree::raw::IdentifyRequest raw_request;
    return selector.wire() != "name:current" ||
                   !workspace_params || !run_params || !screen_params ||
                   !pane_params || !split_params || !terminal_params ||
                   !browser_params || !history_params || !attach_params ||
                   !notification_params || !agent_params ||
                   workspace_params.value()
                           .at("correlation_key")
                           .as_string()
                           .value() != "consumer-workspace" ||
                   run_params.value()
                           .at("correlation_key")
                           .as_string()
                           .value() != "consumer-run" ||
                   screen_params.value()
                           .at("correlation_key")
                           .as_string()
                           .value() != "consumer-screen" ||
                   pane_params.value()
                           .at("correlation_key")
                           .as_string()
                           .value() != "consumer-pane" ||
                   split_params.value()
                           .at("correlation_key")
                           .as_string()
                           .value() != "consumer-split" ||
                   terminal_params.value()
                           .at("correlation_key")
                           .as_string()
                           .value() != "consumer-terminal" ||
                   browser_params.value()
                           .at("correlation_key")
                           .as_string()
                           .value() != "consumer-browser" ||
                   history_params.value()
                           .at("before")
                           .as_string()
                           .value() != "50" ||
                   history_params.value()
                           .at("limit")
                           .as_uint64()
                           .value() != 100 ||
                   attach_params.value()
                           .at("cols")
                           .as_uint64()
                           .value() != 120 ||
                   !attach_params.value()
                            .at("read_only")
                            .as_bool()
                            .value() ||
                   notification_params.value()
                           .at("level")
                           .as_string()
                           .value() != "info" ||
                   agent_params.value()
                           .at("source")
                           .as_string()
                           .value() != "socket" ||
                   !(raw_request == bree::raw::IdentifyRequest{}) ||
                   bree::kSdkVersion != "1.0.0"
               ? 1
               : 0;
}
