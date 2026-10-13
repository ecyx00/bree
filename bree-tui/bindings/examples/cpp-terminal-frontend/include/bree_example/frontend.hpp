#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "bree/client.hpp"

namespace bree_example {

struct ScreenBuffer {
    std::optional<bree::TerminalId> terminal;
    bree::Size size{};
    bree::RenderCursor cursor{};
    std::string default_foreground;
    std::string default_background;
    std::uint32_t scrollback_rows = 0;
    std::uint64_t scroll_offset = 0;
    bool at_bottom = true;
    bool has_snapshot = false;
    std::vector<bree::RenderRow> rows;

    void clear() noexcept;
    [[nodiscard]] bree::Result<void> apply(
        const bree::TerminalAttachSnapshot& item);
    [[nodiscard]] bree::Result<void> apply(
        const bree::TerminalAttachPatch& item);
    [[nodiscard]] bree::Result<void> apply(
        const bree::TerminalAttachScroll& item);
    [[nodiscard]] std::string plain_text() const;
};

struct LaunchRequest {
    LaunchRequest(
        bree::RunCommand command_value,
        std::string correlation_key_value,
        std::string idempotency_key_value)
        : command(std::move(command_value)),
          correlation_key(std::move(correlation_key_value)),
          idempotency_key(std::move(idempotency_key_value)) {}

    bree::RunCommand command;
    std::optional<bree::WorkspaceId> workspace;
    std::optional<std::string> cwd;
    std::optional<std::string> name;
    std::string correlation_key;
    std::string idempotency_key;
};

struct FrontendConfig {
    bree::ClientOptions client_options{};
    std::optional<bree::TerminalId> preferred_terminal;
    std::optional<LaunchRequest> launch;
    std::uint16_t columns = 100;
    std::uint16_t rows = 30;
    std::chrono::milliseconds stream_poll_timeout{100};
};

struct FrontendStats {
    std::size_t snapshots = 0;
    std::size_t patches = 0;
    std::size_t scroll_updates = 0;
    std::size_t unknown_items = 0;
    std::size_t poll_timeouts = 0;
    std::size_t cancellations = 0;
};

[[nodiscard]] bree::Result<bree::TerminalId> select_terminal(
    const bree::ResourceSnapshot& snapshot);

[[nodiscard]] std::string plain_text(
    const bree::TerminalHistoryResult& history);

class TerminalFrontend {
public:
    using StopRequested = std::function<bool()>;
    using FrameCallback = std::function<void(const ScreenBuffer&)>;

    explicit TerminalFrontend(FrontendConfig config);

    [[nodiscard]] bree::Result<void> run(
        StopRequested stop_requested,
        FrameCallback on_frame = {});

    [[nodiscard]] const ScreenBuffer& screen() const noexcept { return screen_; }
    [[nodiscard]] const FrontendStats& stats() const noexcept { return stats_; }
    [[nodiscard]] const std::optional<bree::TerminalId>& selected_terminal()
        const noexcept {
        return selected_terminal_;
    }
    [[nodiscard]] bool recovered_launch() const noexcept {
        return recovered_launch_;
    }
    [[nodiscard]] const std::optional<bree::TerminalScreenResult>&
    initial_screen() const noexcept {
        return initial_screen_;
    }
    [[nodiscard]] const std::optional<bree::TerminalHistoryResult>&
    initial_history() const noexcept {
        return initial_history_;
    }
    [[nodiscard]] const std::optional<bree::TerminalSnapshot>&
    initial_terminal() const noexcept {
        return initial_terminal_;
    }
    [[nodiscard]] const std::optional<bree::TerminalWaitExitResult>&
    exit_wait() const noexcept {
        return exit_wait_;
    }
    [[nodiscard]] const std::optional<bree::TerminalSnapshot>& final_terminal()
        const noexcept {
        return final_terminal_;
    }
    [[nodiscard]] const std::optional<bree::StreamEnd>& stream_end()
        const noexcept {
        return stream_end_;
    }

private:
    FrontendConfig config_;
    ScreenBuffer screen_;
    FrontendStats stats_;
    std::optional<bree::TerminalId> selected_terminal_;
    bool recovered_launch_ = false;
    std::optional<bree::TerminalScreenResult> initial_screen_;
    std::optional<bree::TerminalHistoryResult> initial_history_;
    std::optional<bree::TerminalSnapshot> initial_terminal_;
    std::optional<bree::TerminalWaitExitResult> exit_wait_;
    std::optional<bree::TerminalSnapshot> final_terminal_;
    std::optional<bree::StreamEnd> stream_end_;
};

}  // namespace bree_example
