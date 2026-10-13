#include <cstdlib>
#include <deque>
#include <functional>
#include <iostream>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "bree/json.hpp"
#include "bree/transport.hpp"
#include "bree_example/frontend.hpp"

namespace {

constexpr std::string_view hex = "0123456789abcdef0123456789abcdef";
const std::string workspace_id = "ws_" + std::string(hex);
const std::string screen_id = "screen_" + std::string(hex);
const std::string pane_id = "pane_" + std::string(hex);
const std::string tab_id = "tab_" + std::string(hex);
const std::string terminal_id = "term_" + std::string(hex);
const std::string correlation_key = "cpp-frontend-test-run";
const std::string idempotency_key = "cpp-frontend-test-run-attempt-1";

class TestFailure final : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

#define CHECK(condition)                                                          \
    do {                                                                          \
        if (!(condition)) {                                                        \
            throw TestFailure(                                                     \
                std::string("CHECK failed at line ") + std::to_string(__LINE__) + \
                ": " #condition);                                                 \
        }                                                                         \
    } while (false)

template <typename Id>
Id parsed_id(const std::string& value) {
    auto parsed = Id::parse(value);
    CHECK(parsed);
    return std::move(parsed).value();
}

bree::RenderCursor cursor(std::uint16_t x = 0, std::uint16_t y = 0) {
    bree::RenderCursor value;
    value.x = x;
    value.y = y;
    value.style = bree::RenderCursorStyle::block;
    value.visible = true;
    return value;
}

bree::RenderRow row(std::uint16_t index, std::string text) {
    bree::RenderRun run;
    run.text = std::move(text);
    return bree::RenderRow{index, {std::move(run)}};
}

struct FakeEndpoint;
using SendHandler =
    std::function<bree::Result<void>(const bree::Json&, FakeEndpoint&)>;

struct FakeEndpoint {
    std::deque<std::string> incoming;
    std::vector<std::string> outgoing;
    SendHandler on_send;
    bool closed = false;
};

class FakeTransport final : public bree::Transport {
public:
    explicit FakeTransport(std::shared_ptr<FakeEndpoint> endpoint)
        : endpoint_(std::move(endpoint)) {}

    bree::Result<void> send(
        std::string_view message,
        bree::Timeout) override {
        if (endpoint_->closed) {
            return bree::make_error(
                bree::ErrorCode::closed,
                "fake transport is closed");
        }
        endpoint_->outgoing.emplace_back(message);
        auto parsed = bree::Json::parse(message);
        if (!parsed) {
            return std::move(parsed).error();
        }
        return endpoint_->on_send
            ? endpoint_->on_send(parsed.value(), *endpoint_)
            : bree::Result<void>{};
    }

    bree::Result<std::string> receive(bree::Timeout) override {
        if (endpoint_->closed) {
            return bree::make_error(
                bree::ErrorCode::closed,
                "fake transport is closed");
        }
        if (endpoint_->incoming.empty()) {
            return bree::make_error(
                bree::ErrorCode::timeout,
                "fake response intentionally absent");
        }
        std::string value = std::move(endpoint_->incoming.front());
        endpoint_->incoming.pop_front();
        return value;
    }

    void close() noexcept override {
        endpoint_->closed = true;
    }

private:
    std::shared_ptr<FakeEndpoint> endpoint_;
};

bree::TransportFactory factory_for(
    const std::shared_ptr<FakeEndpoint>& endpoint) {
    auto used = std::make_shared<bool>(false);
    return [endpoint, used]()
        -> bree::Result<std::unique_ptr<bree::Transport>> {
        if (*used) {
            return bree::make_error(
                bree::ErrorCode::connection,
                "fake transport factory was reused");
        }
        *used = true;
        return std::unique_ptr<bree::Transport>(
            new FakeTransport(endpoint));
    };
}

std::string request_id(const bree::Json& request) {
    const bree::Json* value = request.find("id");
    CHECK(value != nullptr);
    auto text = value->as_string();
    CHECK(text);
    return std::string(text.value());
}

std::string operation(const bree::Json& request) {
    const bree::Json* value = request.find("operation");
    CHECK(value != nullptr);
    auto text = value->as_string();
    CHECK(text);
    return std::string(text.value());
}

const bree::Json::Object& params(const bree::Json& request) {
    const bree::Json* value = request.find("params");
    CHECK(value != nullptr);
    auto object = value->as_object();
    CHECK(object);
    return *object.value();
}

std::string string_field(
    const bree::Json::Object& object,
    std::string_view key) {
    const auto found = object.find(key);
    CHECK(found != object.end());
    auto value = found->second.as_string();
    CHECK(value);
    return std::string(value.value());
}

std::uint64_t uint_field(
    const bree::Json::Object& object,
    std::string_view key) {
    const auto found = object.find(key);
    CHECK(found != object.end());
    auto value = found->second.as_uint64();
    CHECK(value);
    return value.value();
}

void respond(
    FakeEndpoint& endpoint,
    const bree::Json& request,
    std::string result = "{}") {
    endpoint.incoming.push_back(
        "{\"protocol\":\"bree.protocol/2\",\"type\":\"response\","
        "\"id\":\"" +
        request_id(request) +
        "\",\"ok\":true,\"result\":" + std::move(result) + "}");
}

std::string render_row_json(std::uint16_t index, std::string_view text) {
    return "{\"row\":" + std::to_string(index) +
           ",\"runs\":[{\"text\":\"" + std::string(text) +
           "\",\"fg\":null,\"bg\":null,\"attrs\":0}]}";
}

std::string cursor_json(std::uint16_t x, std::uint16_t y) {
    return "{\"x\":" + std::to_string(x) +
           ",\"y\":" + std::to_string(y) +
           ",\"style\":\"block\",\"blink\":false,"
           "\"visible\":true,\"color\":null}";
}

std::string stream_item(
    const std::string& stream_id,
    std::uint64_t sequence,
    std::string item) {
    return "{\"protocol\":\"bree.protocol/2\",\"type\":\"stream_item\","
           "\"stream_id\":\"" +
           stream_id + "\",\"sequence\":\"" +
           std::to_string(sequence) + "\",\"item\":" +
           std::move(item) + "}";
}

struct FakeScenario {
    std::shared_ptr<FakeEndpoint> control =
        std::make_shared<FakeEndpoint>();
    std::shared_ptr<FakeEndpoint> stream =
        std::make_shared<FakeEndpoint>();
    std::vector<std::string> control_operations;
    std::vector<std::string> stream_operations;
    std::size_t terminal_gets = 0;
    bool dropped_run = false;
};

std::shared_ptr<FakeScenario> make_scenario() {
    auto scenario = std::make_shared<FakeScenario>();
    std::weak_ptr<FakeScenario> weak = scenario;
    scenario->control->on_send =
        [weak](const bree::Json& request, FakeEndpoint& endpoint)
        -> bree::Result<void> {
        auto state = weak.lock();
        CHECK(state != nullptr);
        const std::string op = operation(request);
        state->control_operations.push_back(op);
        const auto& input = params(request);

        if (op == "workspace.run") {
            CHECK(string_field(input, "workspace") == workspace_id);
            CHECK(string_field(input, "shell") == "printf 'hello\\n'");
            CHECK(
                string_field(input, "correlation_key") ==
                correlation_key);
            const bree::Json* key = request.find("idempotency_key");
            CHECK(key != nullptr);
            CHECK(key->as_string().value() == idempotency_key);
            state->dropped_run = true;
            return {};
        }
        if (op == "session.creation.resolve") {
            CHECK(state->dropped_run);
            CHECK(
                string_field(input, "correlation_key") ==
                correlation_key);
            respond(
                endpoint,
                request,
                "{\"correlation_key\":\"" + correlation_key +
                    "\",\"state\":\"created\",\"recovery\":\"none\","
                    "\"operation\":\"workspace.run\","
                    "\"idempotency_key\":\"" + idempotency_key +
                    "\",\"created_path\":{\"kind\":\"terminal\","
                    "\"workspace_id\":\"" + workspace_id +
                    "\",\"screen_id\":\"" + screen_id +
                    "\",\"pane_id\":\"" + pane_id +
                    "\",\"tab_id\":\"" + tab_id +
                    "\",\"terminal_id\":\"" + terminal_id +
                    "\"},\"generation\":\"g\",\"revision\":\"3\"}");
            return {};
        }
        if (op == "terminal.get") {
            CHECK(string_field(input, "terminal") == terminal_id);
            ++state->terminal_gets;
            if (state->terminal_gets == 1) {
                respond(
                    endpoint,
                    request,
                    "{\"id\":\"" + terminal_id +
                        "\",\"tab_ids\":[\"" + tab_id + "\"]" +
                        ",\"title\":\"build\",\"cols\":80,\"rows\":24,"
                        "\"running\":true,\"lifecycle\":\"running\"}");
            } else {
                respond(
                    endpoint,
                    request,
                    "{\"id\":\"" + terminal_id +
                        "\",\"tab_ids\":[\"" + tab_id + "\"]" +
                        ",\"title\":\"build\",\"cols\":100,\"rows\":30,"
                        "\"running\":false,\"lifecycle\":\"exited\","
                        "\"exit\":{\"outcome\":{\"kind\":\"exit\","
                        "\"code\":17},\"exited_at\":\"1000\","
                        "\"revision\":\"9\"}}");
            }
            return {};
        }
        if (op == "terminal.screen.read") {
            respond(
                endpoint,
                request,
                "{\"text\":\"initial screen\",\"cols\":80,\"rows\":24,"
                "\"cursor_row\":1,\"cursor_col\":0,"
                "\"cursor_visible\":true}");
            return {};
        }
        if (op == "terminal.history.read") {
            CHECK(uint_field(input, "limit") == 10'000);
            CHECK(input.at("styled").as_bool().value());
            CHECK(input.find("before") == input.end());
            respond(
                endpoint,
                request,
                "{\"start\":\"0\",\"next\":null,\"rows\":[" +
                    render_row_json(0, "history one") + "," +
                    render_row_json(1, "history two") + "]}");
            return {};
        }
        if (op == "terminal.wait_exit") {
            CHECK(string_field(input, "timeout_ms") == "0");
            respond(
                endpoint,
                request,
                "{\"state\":\"exited\",\"terminal_id\":\"" +
                    terminal_id +
                    "\",\"lifecycle\":\"exited\","
                    "\"outcome\":{\"kind\":\"exit\",\"code\":17},"
                    "\"exited_at\":\"1000\",\"revision\":\"9\"}");
            return {};
        }
        return bree::make_error(
            bree::ErrorCode::protocol,
            "unexpected control operation " + op);
    };

    scenario->stream->on_send =
        [weak](const bree::Json& request, FakeEndpoint& endpoint)
        -> bree::Result<void> {
        auto state = weak.lock();
        CHECK(state != nullptr);
        const std::string op = operation(request);
        state->stream_operations.push_back(op);
        const auto& input = params(request);

        if (op == "terminal.attach") {
            CHECK(string_field(input, "terminal") == terminal_id);
            CHECK(input.at("read_only").as_bool().value());
            CHECK(input.find("cols") == input.end());
            CHECK(input.find("rows") == input.end());
            const std::string id = string_field(input, "stream_id");
            endpoint.incoming.push_back(stream_item(
                id,
                1,
                "{\"kind\":\"snapshot\",\"terminal_id\":\"" +
                    terminal_id +
                    "\",\"render\":{\"size\":{\"cols\":12,\"rows\":2},"
                    "\"cursor\":" + cursor_json(0, 0) +
                    ",\"default_fg\":\"#ffffff\","
                    "\"default_bg\":\"#000000\","
                    "\"scrollback_rows\":2,\"rows\":[" +
                    render_row_json(0, "boot") + "," +
                    render_row_json(1, "running") + "]}}"));
            respond(
                endpoint,
                request,
                "{\"stream_id\":\"" + id +
                    "\",\"attachment_lease\":\"terminal-lease\"}");
            endpoint.incoming.push_back(stream_item(
                id,
                2,
                "{\"kind\":\"future.render\",\"terminal_id\":\"" +
                    terminal_id + "\",\"payload\":true}"));
            endpoint.incoming.push_back(stream_item(
                id,
                3,
                "{\"kind\":\"patch\",\"terminal_id\":\"" +
                    terminal_id +
                    "\",\"render\":{\"cursor\":" + cursor_json(0, 1) +
                    ",\"full_reset\":false,\"rows\":[" +
                    render_row_json(1, "complete") + "]}}"));
            return {};
        }
        if (op == "terminal.viewer.resize") {
            CHECK(string_field(input, "attachment_lease") == "terminal-lease");
            CHECK(uint_field(input, "cols") == 100);
            CHECK(uint_field(input, "rows") == 30);
            respond(
                endpoint,
                request,
                "{\"accepted\":true,\"size\":{\"cols\":100,\"rows\":30},"
                "\"outcome\":\"applied\"}");
            return {};
        }
        if (op == "terminal.viewer.release") {
            CHECK(string_field(input, "attachment_lease") == "terminal-lease");
            respond(endpoint, request, "{\"outcome\":\"applied\"}");
            return {};
        }
        if (op == "stream.cancel") {
            const std::string id = string_field(input, "stream");
            endpoint.incoming.push_back(
                "{\"protocol\":\"bree.protocol/2\","
                "\"type\":\"stream_end\",\"stream_id\":\"" + id +
                "\",\"reason\":\"canceled\"}");
            respond(endpoint, request);
            return {};
        }
        return bree::make_error(
            bree::ErrorCode::protocol,
            "unexpected stream operation " + op);
    };
    return scenario;
}

void test_screen_reducer_uses_typed_attachment_items() {
    const auto terminal = parsed_id<bree::TerminalId>(terminal_id);
    bree::RenderSnapshot render;
    render.size = {12, 2};
    render.cursor = cursor();
    render.default_fg = "#ffffff";
    render.default_bg = "#000000";
    render.rows = {row(0, "old"), row(1, "running")};

    bree_example::ScreenBuffer screen;
    auto initial = screen.apply(
        bree::TerminalAttachSnapshot{terminal, std::move(render)});
    CHECK(initial);
    CHECK(screen.plain_text() == "old\nrunning");

    bree::RenderPatch patch;
    patch.cursor = cursor(0, 1);
    patch.rows = {row(1, "done")};
    auto updated = screen.apply(
        bree::TerminalAttachPatch{terminal, std::move(patch)});
    CHECK(updated);
    CHECK(screen.plain_text() == "old\ndone");

    auto scrolled = screen.apply(
        bree::TerminalAttachScroll{
            terminal,
            bree::RenderScroll{9, false},
        });
    CHECK(scrolled);
    CHECK(screen.scroll_offset == 9);
    CHECK(!screen.at_bottom);
}

void test_terminal_selection_prefers_focused_opaque_tab() {
    const auto focused = parsed_id<bree::TerminalId>(terminal_id);
    const auto other = parsed_id<bree::TerminalId>(
        "term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

    bree::ResourceSnapshot snapshot;
    bree::TerminalSnapshot other_terminal;
    other_terminal.id = other;
    other_terminal.tab_ids = {parsed_id<bree::TabId>(
        "tab_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")};
    other_terminal.title = "other";
    other_terminal.cols = 80;
    other_terminal.rows = 24;
    other_terminal.running = true;
    other_terminal.lifecycle = bree::TerminalLifecycle::running;
    snapshot.terminals.push_back(other_terminal);

    bree::TerminalSnapshot focused_terminal = other_terminal;
    focused_terminal.id = focused;
    focused_terminal.tab_ids = {parsed_id<bree::TabId>(tab_id)};
    snapshot.terminals.push_back(focused_terminal);

    bree::TabSnapshot tab;
    tab.id = parsed_id<bree::TabId>(tab_id);
    tab.pane_id = parsed_id<bree::PaneId>(pane_id);
    tab.focused = true;
    tab.content_id = focused;
    snapshot.tabs.push_back(tab);

    auto selected = bree_example::select_terminal(snapshot);
    CHECK(selected);
    CHECK(selected.value() == focused);
}

void test_recovery_typed_reads_exit_and_cancellation() {
    auto scenario = make_scenario();
    bree_example::FrontendConfig config;
    config.client_options.timeout = std::chrono::milliseconds(1);
    config.client_options.transport_factory =
        factory_for(scenario->control);
    config.client_options.stream_transport_factory =
        factory_for(scenario->stream);
    config.stream_poll_timeout = std::chrono::milliseconds(1);

    auto command = bree::RunCommand::shell("printf 'hello\\n'");
    CHECK(command);
    bree_example::LaunchRequest launch(
        std::move(command).value(),
        correlation_key,
        idempotency_key);
    launch.workspace = parsed_id<bree::WorkspaceId>(workspace_id);
    launch.name = "build";
    config.launch = std::move(launch);

    bool stop = false;
    bree_example::TerminalFrontend frontend(std::move(config));
    auto result = frontend.run(
        [&] { return stop; },
        [&](const bree_example::ScreenBuffer& screen) {
            if (screen.plain_text() == "boot\ncomplete") {
                stop = true;
            }
        });
    CHECK(result);
    CHECK(frontend.recovered_launch());
    CHECK(frontend.selected_terminal());
    CHECK(frontend.selected_terminal()->value() == terminal_id);
    CHECK(frontend.initial_terminal());
    CHECK(
        frontend.initial_terminal()->lifecycle ==
        bree::TerminalLifecycle::running);
    CHECK(frontend.initial_screen());
    CHECK(frontend.initial_screen()->text == "initial screen");
    CHECK(frontend.initial_history());
    CHECK(
        bree_example::plain_text(*frontend.initial_history()) ==
        "history one\nhistory two");
    CHECK(frontend.screen().plain_text() == "boot\ncomplete");
    CHECK(frontend.stats().snapshots == 1);
    CHECK(frontend.stats().patches == 1);
    CHECK(frontend.stats().unknown_items == 1);
    CHECK(frontend.stats().cancellations == 1);
    CHECK(frontend.stream_end());
    CHECK(
        frontend.stream_end()->reason ==
        bree::StreamEndReason::canceled);
    CHECK(frontend.exit_wait());
    const auto* exited = std::get_if<bree::TerminalWaitExitExited>(
        &*frontend.exit_wait());
    CHECK(exited != nullptr);
    const auto* code =
        std::get_if<bree::TerminalExitCode>(&exited->outcome);
    CHECK(code != nullptr);
    CHECK(code->code == 17);
    CHECK(frontend.final_terminal());
    CHECK(
        frontend.final_terminal()->lifecycle ==
        bree::TerminalLifecycle::exited);
    CHECK(frontend.final_terminal()->exit.has_value());
    CHECK(
        scenario->control_operations ==
        std::vector<std::string>({
            "workspace.run",
            "session.creation.resolve",
            "terminal.get",
            "terminal.screen.read",
            "terminal.history.read",
            "terminal.wait_exit",
            "terminal.get",
        }));
    CHECK(
        scenario->stream_operations ==
        std::vector<std::string>({
            "terminal.attach",
            "terminal.viewer.resize",
            "terminal.viewer.release",
            "stream.cancel",
        }));
}

void run_test(std::string_view name, const std::function<void()>& test) {
    try {
        test();
        std::cout << "ok: " << name << '\n';
    } catch (const std::exception& error) {
        std::cerr << "FAILED: " << name << ": " << error.what() << '\n';
        throw;
    }
}

}  // namespace

int main() {
    try {
        run_test(
            "typed attachment reducer",
            test_screen_reducer_uses_typed_attachment_items);
        run_test(
            "opaque terminal selection",
            test_terminal_selection_prefers_focused_opaque_tab);
        run_test(
            "correlation recovery, typed reads, exit, and cancellation",
            test_recovery_typed_reads_exit_and_cancellation);
    } catch (...) {
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
