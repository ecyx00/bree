#include <bree/client.hpp>

#include <algorithm>
#include <charconv>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <map>
#include <optional>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <variant>
#include <vector>

namespace {

class AdapterError final : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

[[nodiscard]] std::string describe(const bree::Error& error) {
    std::string result = error.protocol_code.empty()
        ? error.code_name()
        : error.protocol_code;
    result += ": ";
    result += error.message;
    return result;
}

template <typename T>
[[nodiscard]] T take(bree::Result<T> result) {
    if (!result) {
        throw AdapterError(describe(result.error()));
    }
    return std::move(result).value();
}

[[nodiscard]] const bree::Json& field(
    const bree::Json& value,
    std::string_view name) {
    const auto* result = value.find(name);
    if (!result) {
        throw AdapterError("missing JSON field: " + std::string(name));
    }
    return *result;
}

[[nodiscard]] std::string string_value(const bree::Json& value) {
    auto text = value.as_string();
    if (!text) {
        throw AdapterError("expected a JSON string");
    }
    return std::string(text.value());
}

[[nodiscard]] std::string string_field(
    const bree::Json& value,
    std::string_view name) {
    return string_value(field(value, name));
}

[[nodiscard]] std::uint64_t decimal(std::string_view text) {
    std::uint64_t value = 0;
    const auto [end, error] =
        std::from_chars(text.data(), text.data() + text.size(), value);
    if (error != std::errc{} || end != text.data() + text.size()) {
        throw AdapterError("invalid unsigned decimal: " + std::string(text));
    }
    return value;
}

template <typename Id>
[[nodiscard]] Id opaque_id(std::string_view value) {
    auto parsed = Id::parse(value);
    if (!parsed) {
        throw AdapterError(describe(parsed.error()));
    }
    return std::move(parsed).value();
}

[[nodiscard]] const bree::Json& constants(const bree::Json& request) {
    return field(request, "constants");
}

[[nodiscard]] bree::MutationOptions mutation_options(
    const bree::Json& request,
    std::string_view key_name = "idempotency_key") {
    const auto& values = constants(request);
    auto options = take(bree::MutationOptions::with_key(
        string_field(values, key_name)));
    return options.expecting(decimal(string_field(values, "revision")));
}

[[nodiscard]] bree::Client connect(
    const bree::Json& request,
    std::string session_selector) {
    bree::ClientOptions options;
    options.socket_path = string_field(request, "socket_path");
    options.machine_selector = "current";
    options.session_selector = std::move(session_selector);
    options.timeout = std::chrono::seconds(15);
    return take(bree::Client::connect(std::move(options)));
}

[[nodiscard]] bree::Session session(
    bree::Client& client,
    const bree::Json& request) {
    return client.session(opaque_id<bree::SessionId>(
        string_field(constants(request), "session")));
}

[[nodiscard]] bree::Workspace workspace(
    bree::Client& client,
    const bree::Json& request) {
    return client.workspace(opaque_id<bree::WorkspaceId>(
        string_field(constants(request), "workspace")));
}

[[nodiscard]] std::string end_name(bree::StreamEndReason reason) {
    switch (reason) {
        case bree::StreamEndReason::completed:
            return "completed";
        case bree::StreamEndReason::canceled:
            return "canceled";
        case bree::StreamEndReason::closed:
            return "closed";
        case bree::StreamEndReason::gap:
            return "gap";
        case bree::StreamEndReason::error:
            return "error";
    }
    throw AdapterError("unknown stream end reason");
}

[[nodiscard]] const bree::StreamEnd& require_end(
    const bree::SessionEventStream& stream) {
    if (!stream.end()) {
        throw AdapterError("stream ended without terminal metadata");
    }
    return *stream.end();
}

[[nodiscard]] bree::Json cursor_json(const bree::Cursor& cursor) {
    return bree::Json(bree::Json::Object{
        {"generation", bree::Json(cursor.generation)},
        {"revision", bree::Json(std::to_string(cursor.revision))},
    });
}

[[nodiscard]] bree::Json mutation_json(
    const bree::MutationResult<bree::WorkspaceSnapshot>& result) {
    return bree::Json(bree::Json::Object{
        {"workspace_id", bree::Json(result.value.id.value())},
        {"name", bree::Json(result.value.name)},
        {"generation", bree::Json(result.generation)},
        {"revision", bree::Json(std::to_string(result.revision))},
        {"replayed", bree::Json(result.replayed)},
    });
}

[[nodiscard]] bree::Json error_json(const bree::Error& error) {
    return bree::Json(bree::Json::Object{
        {"code", bree::Json(error.protocol_code)},
        {"message", bree::Json(error.message)},
        {"details",
         error.details ? *error.details : bree::Json(bree::Json::Object{})},
        {"retryable", bree::Json(error.retryable)},
    });
}

[[nodiscard]] bree::Json created_path_json(const bree::CreatedPath& path) {
    if (const auto* value =
            std::get_if<bree::CreatedWorkspaceOnly>(&path)) {
        return bree::Json(bree::Json::Object{
            {"kind", bree::Json("workspace")},
            {"workspace_id", bree::Json(value->workspace_id.value())},
        });
    }
    if (const auto* value =
            std::get_if<bree::CreatedTerminalPath>(&path)) {
        return bree::Json(bree::Json::Object{
            {"kind", bree::Json("terminal")},
            {"workspace_id", bree::Json(value->workspace_id.value())},
            {"screen_id", bree::Json(value->screen_id.value())},
            {"pane_id", bree::Json(value->pane_id.value())},
            {"tab_id", bree::Json(value->tab_id.value())},
            {"terminal_id", bree::Json(value->terminal_id.value())},
        });
    }
    const auto& value = std::get<bree::CreatedBrowserPath>(path);
    return bree::Json(bree::Json::Object{
        {"kind", bree::Json("browser")},
        {"workspace_id", bree::Json(value.workspace_id.value())},
        {"screen_id", bree::Json(value.screen_id.value())},
        {"pane_id", bree::Json(value.pane_id.value())},
        {"tab_id", bree::Json(value.tab_id.value())},
        {"browser_id", bree::Json(value.browser_id.value())},
    });
}

[[nodiscard]] std::string creation_state_name(bree::CreationState state) {
    switch (state) {
        case bree::CreationState::pending:
            return "pending";
        case bree::CreationState::created:
            return "created";
        case bree::CreationState::not_applied:
            return "not_applied";
        case bree::CreationState::indeterminate:
            return "indeterminate";
    }
    throw AdapterError("unknown creation state");
}

[[nodiscard]] std::string creation_recovery_name(
    bree::CreationRecovery recovery) {
    switch (recovery) {
        case bree::CreationRecovery::retry_same_idempotency_key:
            return "retry_same_idempotency_key";
        case bree::CreationRecovery::retry_new_idempotency_key:
            return "retry_new_idempotency_key";
        case bree::CreationRecovery::wait:
            return "wait";
        case bree::CreationRecovery::none:
            return "none";
        case bree::CreationRecovery::do_not_retry:
            return "do_not_retry";
    }
    throw AdapterError("unknown creation recovery");
}

[[nodiscard]] bree::Json creation_resolution_json(
    const bree::CreationResolution& resolution) {
    bree::Json::Object result{
        {"correlation_key", bree::Json(resolution.correlation_key)},
        {"state", bree::Json(creation_state_name(resolution.state))},
        {"recovery", bree::Json(creation_recovery_name(resolution.recovery))},
    };
    if (resolution.operation) {
        result.emplace("operation", bree::Json(*resolution.operation));
    }
    if (resolution.idempotency_key) {
        result.emplace(
            "idempotency_key",
            bree::Json(*resolution.idempotency_key));
    }
    if (resolution.created_path) {
        result.emplace(
            "created_path",
            created_path_json(*resolution.created_path));
    }
    if (resolution.generation) {
        result.emplace("generation", bree::Json(*resolution.generation));
    }
    if (resolution.revision) {
        result.emplace(
            "revision",
            bree::Json(std::to_string(*resolution.revision)));
    }
    return bree::Json(std::move(result));
}

[[nodiscard]] bree::Json exit_outcome_json(
    const bree::TerminalExitOutcome& outcome) {
    if (const auto* value = std::get_if<bree::TerminalExitCode>(&outcome)) {
        return bree::Json(bree::Json::Object{
            {"kind", bree::Json("exit")},
            {"code", bree::Json(std::int64_t{value->code})},
        });
    }
    if (const auto* value =
            std::get_if<bree::TerminalExitSignal>(&outcome)) {
        return bree::Json(bree::Json::Object{
            {"kind", bree::Json("signal")},
            {"signal", bree::Json(std::int64_t{value->signal})},
            {"core_dumped", bree::Json(value->core_dumped)},
        });
    }
    const auto& value = std::get<bree::TerminalExitUnknown>(outcome);
    return bree::Json(bree::Json::Object{
        {"kind", bree::Json("unknown")},
        {"reason", bree::Json(value.reason)},
    });
}

[[nodiscard]] bree::Json terminal_wait_exit_json(
    const bree::TerminalWaitExitResult& result) {
    if (const auto* value =
            std::get_if<bree::TerminalWaitExitPending>(&result)) {
        return bree::Json(bree::Json::Object{
            {"state", bree::Json("pending")},
            {"terminal_id", bree::Json(value->terminal_id.value())},
            {"lifecycle", bree::Json(value->lifecycle)},
            {"revision", bree::Json(std::to_string(value->revision))},
        });
    }
    const auto& value = std::get<bree::TerminalWaitExitExited>(result);
    return bree::Json(bree::Json::Object{
        {"state", bree::Json("exited")},
        {"terminal_id", bree::Json(value.terminal_id.value())},
        {"lifecycle", bree::Json("exited")},
        {"outcome", exit_outcome_json(value.outcome)},
        {"exited_at", bree::Json(std::to_string(value.exited_at))},
        {"revision", bree::Json(std::to_string(value.revision))},
    });
}

[[nodiscard]] bree::Json run_read(const bree::Json& request) {
    auto client = connect(
        request, string_field(constants(request), "session"));
    const auto result = take(session(client, request).ping());
    return bree::Json(bree::Json::Object{
        {"alive", bree::Json(result.alive)},
        {"cursor", cursor_json(result.cursor)},
    });
}

[[nodiscard]] bree::Json run_creation_resolve(
    const bree::Json& request) {
    auto client = connect(
        request, string_field(constants(request), "session"));
    const auto result = take(session(client, request).resolve_creation(
        string_field(constants(request), "correlation_key")));
    return creation_resolution_json(result);
}

[[nodiscard]] bree::Json run_creation_conflict(
    const bree::Json& request) {
    auto client = connect(
        request, string_field(constants(request), "session"));
    bree::CreateWorkspaceOptions create;
    create.name = string_field(constants(request), "name");
    create.initial_content = bree::InitialContent::empty;
    create.correlation_key =
        string_field(constants(request), "correlation_key");
    auto result = session(client, request).create_workspace(
        std::move(create),
        take(bree::MutationOptions::with_key(
            string_field(constants(request), "idempotency_key"))));
    if (result) {
        throw AdapterError("creation conflict unexpectedly succeeded");
    }
    return error_json(result.error());
}

[[nodiscard]] bree::Json run_terminal_wait_exit(
    const bree::Json& request) {
    auto client = connect(
        request, string_field(constants(request), "session"));
    auto terminal = client.terminal(opaque_id<bree::TerminalId>(
        string_field(constants(request), "terminal")));
    const auto timeout = decimal(string_field(request, "timeout_ms"));
    return terminal_wait_exit_json(take(terminal.wait_exit(timeout)));
}

[[nodiscard]] bree::Json run_mutation_replay(const bree::Json& request) {
    auto client = connect(
        request, string_field(constants(request), "session"));
    auto target = workspace(client, request);
    const auto name = string_field(constants(request), "name");
    const auto options = mutation_options(request);
    const auto first = take(target.rename(name, options));
    const auto second = take(target.rename(name, options));
    return bree::Json(bree::Json::Object{
        {"first", mutation_json(first)},
        {"second", mutation_json(second)},
    });
}

[[nodiscard]] bree::Json run_mutation_error(const bree::Json& request) {
    auto client = connect(
        request, string_field(constants(request), "session"));
    auto result = workspace(client, request).rename(
        string_field(constants(request), "name"),
        mutation_options(request));
    if (result) {
        throw AdapterError("mutation unexpectedly succeeded");
    }
    return error_json(result.error());
}

[[nodiscard]] bree::Json run_stream_unknown(const bree::Json& request) {
    auto client = connect(
        request, string_field(constants(request), "session"));
    auto stream = take(session(client, request).events());
    auto next = take(stream.next());
    if (!next) {
        throw AdapterError("unknown stream ended before its item");
    }
    if (!next->cursor) {
        throw AdapterError("unknown stream item omitted its cursor");
    }
    auto terminal = take(stream.next());
    if (terminal) {
        throw AdapterError("unknown stream produced an unexpected second item");
    }
    const auto* unknown = std::get_if<bree::Unknown>(&next->value);
    if (!unknown) {
        throw AdapterError(
            "session event was not the public Unknown variant");
    }
    return bree::Json(bree::Json::Object{
        {"sequence", bree::Json(std::to_string(next->sequence))},
        {"cursor", cursor_json(*next->cursor)},
        {"kind", bree::Json(unknown->kind)},
        {"raw", unknown->raw},
        {"end", bree::Json(end_name(require_end(stream).reason))},
    });
}

[[nodiscard]] bree::Json run_stream_cancel(const bree::Json& request) {
    auto client = connect(
        request, string_field(constants(request), "session"));
    auto stream = take(session(client, request).events());
    const auto first = take(stream.cancel());
    const auto second = take(stream.cancel());
    std::uint64_t after = 0;
    while (take(stream.next())) {
        ++after;
    }
    if (first.reason != second.reason) {
        throw AdapterError("repeated cancel changed the terminal reason");
    }
    return bree::Json(bree::Json::Object{
        {"end", bree::Json(end_name(second.reason))},
        {"items_after_cancel", bree::Json(after)},
        {"cancel_calls", bree::Json(std::uint64_t{2})},
    });
}

[[nodiscard]] std::string drain(bree::SessionEventStream& stream) {
    while (take(stream.next())) {
    }
    return end_name(require_end(stream).reason);
}

[[nodiscard]] bree::Json run_stream_overflow(const bree::Json& request) {
    auto client = connect(
        request, string_field(constants(request), "session"));
    auto current_session = session(client, request);
    auto first = take(current_session.events());
    const auto first_end = drain(first);

    auto second = take(current_session.events());
    auto item = take(second.next());
    if (!item) {
        throw AdapterError("independent stream ended before its item");
    }
    const auto* unknown = std::get_if<bree::Unknown>(&item->value);
    if (!unknown) {
        throw AdapterError(
            "independent stream item was not the public Unknown variant");
    }
    const auto second_kind = unknown->kind;
    if (take(second.next())) {
        throw AdapterError("independent stream produced an extra item");
    }
    const auto control = take(current_session.ping());
    return bree::Json(bree::Json::Object{
        {"first_end", bree::Json(first_end)},
        {"second_kind", bree::Json(second_kind)},
        {"control_alive", bree::Json(control.alive)},
    });
}

[[nodiscard]] bree::Json run_redaction() {
    constexpr std::string_view specifier_secret =
        "provider://conformance-secret";
    constexpr std::string_view renderer_secret =
        "renderer-conformance-secret";
    bree::SensitiveString specifier{std::string(specifier_secret)};
    bree::RendererGrant grant{
        "unix:///tmp/renderer",
        opaque_id<bree::TerminalId>(
            "term_66666666666666666666666666666666"),
        bree::SensitiveString(std::string(renderer_secret)),
        {"render"},
        1000,
    };
    std::ostringstream specifier_text;
    specifier_text << specifier;
    std::ostringstream grant_text;
    grant_text << grant;
    return bree::Json(bree::Json::Object{
        {"specifier_redacted",
         bree::Json(
             specifier_text.str().find(specifier_secret) == std::string::npos)},
        {"renderer_token_redacted",
         bree::Json(
             grant_text.str().find(renderer_secret) == std::string::npos)},
    });
}

[[nodiscard]] bree::MutationOptions key(
    std::string_view prefix,
    std::string_view suffix) {
    return take(bree::MutationOptions::with_key(
        std::string(prefix) + "-" + std::string(suffix)));
}

[[nodiscard]] bree::WorkspaceId create_empty_workspace(
    bree::Session& session,
    std::string name,
    bree::MutationOptions mutation) {
    bree::CreateWorkspaceOptions create;
    create.name = std::move(name);
    create.initial_content = bree::InitialContent::empty;
    auto created = take(session.create_workspace(
        std::move(create), std::move(mutation)));
    return std::visit(
        [](const auto& value) { return value.workspace_id; },
        created.value);
}

[[nodiscard]] std::map<std::string, std::string> workspace_rows(
    bree::Session& session) {
    const auto listed = take(session.workspaces());
    std::map<std::string, std::string> rows;
    for (const auto& item : listed) {
        rows.emplace(item.id.value(), item.name);
    }
    return rows;
}

[[nodiscard]] std::vector<std::string> string_array_field(
    const bree::Json& value,
    std::string_view name) {
    auto array = field(value, name).as_array();
    if (!array) {
        throw AdapterError(
            "expected a JSON string array: " + std::string(name));
    }
    std::vector<std::string> result;
    result.reserve(array.value()->size());
    for (const auto& item : *array.value()) {
        result.push_back(string_value(item));
    }
    return result;
}

[[nodiscard]] bree::Json string_array_json(
    const std::vector<std::string>& values) {
    bree::Json::Array result;
    result.reserve(values.size());
    for (const auto& value : values) {
        result.emplace_back(value);
    }
    return bree::Json(std::move(result));
}

[[nodiscard]] bree::Json run_live_setup(const bree::Json& request) {
    auto client = connect(request, "current");
    auto current =
        client.session(bree::Selector<bree::SessionId>::current());
    const auto pinged = take(current.ping()).alive;
    const auto base = string_field(request, "workspace_name");
    const auto key_prefix = string_field(request, "key_prefix");

    const auto stable_id = create_empty_workspace(
        current, base, key(key_prefix, "stable-create"));
    const auto renamed_name = base + "-renamed";
    const auto renamed = take(
        current.workspace(stable_id).rename(
            renamed_name,
            key(key_prefix, "stable-rename")));
    const auto stable_renamed = renamed.value.name == renamed_name;

    const auto duplicate_name = base + "-duplicate";
    std::vector<std::string> duplicate_ids;
    duplicate_ids.reserve(2);
    for (const auto suffix : {"duplicate-a", "duplicate-b"}) {
        duplicate_ids.push_back(
            create_empty_workspace(
                current,
                duplicate_name,
                key(key_prefix, suffix))
                .value());
    }

    auto ambiguity =
        current.workspace(
                   bree::Selector<bree::WorkspaceId>::exact_name(
                       duplicate_name))
            .rename(
                base + "-must-not-apply",
                key(key_prefix, "ambiguous-rename"));
    if (ambiguity) {
        throw AdapterError(
            "duplicate workspace selector unexpectedly mutated");
    }
    const auto ambiguity_code = ambiguity.error().protocol_code;
    std::vector<std::string> ambiguity_candidates;
    if (ambiguity.error().details) {
        if (const auto* candidates =
                ambiguity.error().details->find("candidates")) {
            auto array = candidates->as_array();
            if (array) {
                ambiguity_candidates.reserve(array.value()->size());
                for (const auto& candidate : *array.value()) {
                    ambiguity_candidates.push_back(string_value(candidate));
                }
            }
        }
    }
    const std::set<std::string> expected_candidates(
        duplicate_ids.begin(), duplicate_ids.end());
    const std::set<std::string> observed_candidates(
        ambiguity_candidates.begin(), ambiguity_candidates.end());
    const auto candidates_preserved =
        ambiguity_candidates.size() == duplicate_ids.size() &&
        observed_candidates == expected_candidates;

    const auto rows = workspace_rows(current);
    const auto no_mutation =
        rows.contains(stable_id.value()) &&
        rows.at(stable_id.value()) == renamed_name &&
        std::ranges::all_of(
            duplicate_ids,
            [&rows, &duplicate_name](const auto& identifier) {
                const auto found = rows.find(identifier);
                return found != rows.end() &&
                       found->second == duplicate_name;
            }) &&
        std::ranges::none_of(
            rows,
            [&base](const auto& entry) {
                return entry.second == base + "-must-not-apply";
            });

    return bree::Json(bree::Json::Object{
        {"pinged", bree::Json(pinged)},
        {"stable_id", bree::Json(stable_id.value())},
        {"stable_renamed", bree::Json(stable_renamed)},
        {"duplicate_ids", string_array_json(duplicate_ids)},
        {"ambiguity_code", bree::Json(ambiguity_code)},
        {"ambiguity_preserved_all_candidates",
         bree::Json(candidates_preserved)},
        {"no_mutation", bree::Json(no_mutation)},
    });
}

[[nodiscard]] const bree::TerminalWaitExitPending& require_pending(
    const bree::TerminalWaitExitResult& result) {
    const auto* value =
        std::get_if<bree::TerminalWaitExitPending>(&result);
    if (!value) {
        throw AdapterError("terminal wait did not return pending");
    }
    return *value;
}

[[nodiscard]] const bree::TerminalWaitExitExited& require_exited(
    const bree::TerminalWaitExitResult& result) {
    const auto* value =
        std::get_if<bree::TerminalWaitExitExited>(&result);
    if (!value) {
        throw AdapterError("terminal wait did not return an exit");
    }
    return *value;
}

[[nodiscard]] const bree::TerminalExitCode& require_exit_code(
    const bree::TerminalExitOutcome& outcome) {
    const auto* value = std::get_if<bree::TerminalExitCode>(&outcome);
    if (!value) {
        throw AdapterError("terminal did not exit with an exit code");
    }
    return *value;
}

[[nodiscard]] bree::Json run_live_creation_exit(
    const bree::Json& request) {
    auto client = connect(request, "current");
    auto current =
        client.session(bree::Selector<bree::SessionId>::current());
    auto workspace = current.workspace(opaque_id<bree::WorkspaceId>(
        string_field(request, "expected_stable_id")));
    const auto key_prefix = string_field(request, "key_prefix");
    const auto screen_created = take(workspace.create_screen(
        {},
        key(key_prefix, "runtime-screen")));
    const auto& screen_path = screen_created.value;
    auto pane = workspace.screen(screen_path.screen_id)
        .pane(screen_path.pane_id);

    const auto correlation_key =
        key_prefix + "-terminal-correlation";
    bree::RunOptions run(take(bree::RunCommand::shell(
        string_field(request, "exit_shell"))));
    run.correlation_key = correlation_key;
    const auto run_result = take(pane.run(
        std::move(run),
        key(key_prefix, "terminal-run")));
    const auto& path = run_result.value;
    auto terminal = client.terminal(path.terminal_id);

    const auto pending_result = take(terminal.wait_exit(decimal(
        string_field(request, "pending_timeout_ms"))));
    const auto& pending = require_pending(pending_result);
    const auto resolution =
        take(current.resolve_creation(correlation_key));
    if (!resolution.created_path) {
        throw AdapterError("creation resolution omitted its terminal path");
    }
    const auto* resolved =
        std::get_if<bree::CreatedTerminalPath>(
            &*resolution.created_path);
    if (!resolved ||
        resolved->workspace_id != path.workspace_id ||
        resolved->screen_id != path.screen_id ||
        resolved->pane_id != path.pane_id ||
        resolved->tab_id != path.tab_id ||
        resolved->terminal_id != path.terminal_id) {
        throw AdapterError(
            "creation resolution returned a different terminal path");
    }
    if (!resolution.generation || !resolution.revision) {
        throw AdapterError(
            "created resolution omitted generation or revision");
    }

    const auto exit_result = take(terminal.wait_exit(decimal(
        string_field(request, "exit_timeout_ms"))));
    const auto& exited = require_exited(exit_result);
    const auto& exit_code = require_exit_code(exited.outcome);
    bree::CreatedPath created_path = path;
    return bree::Json(bree::Json::Object{
        {"correlation_key", bree::Json(correlation_key)},
        {"created_path", created_path_json(created_path)},
        {"pending_terminal_id",
         bree::Json(pending.terminal_id.value())},
        {"pending_state", bree::Json("pending")},
        {"pending_lifecycle", bree::Json(pending.lifecycle)},
        {"creation_state",
         bree::Json(creation_state_name(resolution.state))},
        {"creation_recovery",
         bree::Json(creation_recovery_name(resolution.recovery))},
        {"creation_generation", bree::Json(*resolution.generation)},
        {"creation_revision",
         bree::Json(std::to_string(*resolution.revision))},
        {"exit_state", bree::Json("exited")},
        {"exit_terminal_id", bree::Json(exited.terminal_id.value())},
        {"exit_lifecycle", bree::Json("exited")},
        {"exit_kind", bree::Json("exit")},
        {"exit_code", bree::Json(std::int64_t{exit_code.code})},
        {"exited_at", bree::Json(std::to_string(exited.exited_at))},
        {"exit_revision", bree::Json(std::to_string(exited.revision))},
    });
}

[[nodiscard]] bree::Json run_live_exit_restart(
    const bree::Json& request) {
    auto client = connect(request, "current");
    auto current =
        client.session(bree::Selector<bree::SessionId>::current());
    const auto correlation_key =
        string_field(request, "expected_correlation_key");
    const auto resolution =
        take(current.resolve_creation(correlation_key));
    if (!resolution.created_path ||
        !resolution.generation ||
        !resolution.revision) {
        throw AdapterError(
            "durable creation resolution omitted required evidence");
    }
    const auto& expected_path = field(request, "expected_created_path");
    auto terminal = client.terminal(opaque_id<bree::TerminalId>(
        string_field(expected_path, "terminal_id")));
    const auto exit_result = take(terminal.wait_exit(decimal(
        string_field(request, "exit_timeout_ms"))));
    const auto& exited = require_exited(exit_result);
    const auto& exit_code = require_exit_code(exited.outcome);
    return bree::Json(bree::Json::Object{
        {"correlation_key", bree::Json(resolution.correlation_key)},
        {"created_path", created_path_json(*resolution.created_path)},
        {"creation_state",
         bree::Json(creation_state_name(resolution.state))},
        {"creation_recovery",
         bree::Json(creation_recovery_name(resolution.recovery))},
        {"creation_generation", bree::Json(*resolution.generation)},
        {"creation_revision",
         bree::Json(std::to_string(*resolution.revision))},
        {"exit_state", bree::Json("exited")},
        {"exit_terminal_id", bree::Json(exited.terminal_id.value())},
        {"exit_lifecycle", bree::Json("exited")},
        {"exit_kind", bree::Json("exit")},
        {"exit_code", bree::Json(std::int64_t{exit_code.code})},
        {"exited_at", bree::Json(std::to_string(exited.exited_at))},
        {"exit_revision", bree::Json(std::to_string(exited.revision))},
    });
}

[[nodiscard]] bree::Json run_live_restart(const bree::Json& request) {
    auto client = connect(request, "current");
    auto current =
        client.session(bree::Selector<bree::SessionId>::current());
    const auto base = string_field(request, "workspace_name");
    const auto key_prefix = string_field(request, "key_prefix");
    const auto stable_text = string_field(request, "expected_stable_id");
    const auto duplicate_text =
        string_array_field(request, "expected_duplicate_ids");
    if (duplicate_text.size() != 2) {
        throw AdapterError(
            "expected_duplicate_ids must contain exactly two IDs");
    }
    const auto stable_id =
        opaque_id<bree::WorkspaceId>(stable_text);
    std::vector<bree::WorkspaceId> duplicate_ids;
    duplicate_ids.reserve(2);
    for (const auto& identifier : duplicate_text) {
        duplicate_ids.push_back(
            opaque_id<bree::WorkspaceId>(identifier));
    }

    const auto rows = workspace_rows(current);
    const auto same_ids =
        rows.contains(stable_text) &&
        std::ranges::all_of(
            duplicate_text,
            [&rows](const auto& identifier) {
                return rows.contains(identifier);
            });
    const auto stable_name_preserved =
        rows.contains(stable_text) &&
        rows.at(stable_text) == base + "-renamed";
    const auto duplicate_name = base + "-duplicate";
    const auto duplicates_preserved =
        std::ranges::all_of(
            duplicate_text,
            [&rows, &duplicate_name](const auto& identifier) {
                const auto found = rows.find(identifier);
                return found != rows.end() &&
                       found->second == duplicate_name;
            });

    static_cast<void>(take(
        current.workspace(stable_id).close(
            key(key_prefix, "close-stable"))));
    for (std::size_t index = 0; index < duplicate_ids.size(); ++index) {
        static_cast<void>(take(
            current.workspace(duplicate_ids[index]).close(
                key(
                    key_prefix,
                    index == 0 ? "close-a" : "close-b"))));
    }
    const auto remaining = workspace_rows(current);
    const auto disappeared =
        !remaining.contains(stable_text) &&
        std::ranges::none_of(
            duplicate_text,
            [&remaining](const auto& identifier) {
                return remaining.contains(identifier);
            });

    return bree::Json(bree::Json::Object{
        {"same_ids", bree::Json(same_ids)},
        {"stable_name_preserved", bree::Json(stable_name_preserved)},
        {"duplicates_preserved", bree::Json(duplicates_preserved)},
        {"closed", bree::Json(true)},
        {"disappeared", bree::Json(disappeared)},
    });
}

[[nodiscard]] bree::Json run_live(const bree::Json& request) {
    auto client = connect(request, "current");
    const auto available_sessions = take(client.sessions());
    if (available_sessions.empty()) {
        throw AdapterError("session.list omitted an opaque session id");
    }
    auto current_session = client.session(available_sessions.front().id);
    const auto ping = take(current_session.ping());
    const auto pinged = ping.alive;

    const auto name = string_field(request, "workspace_name");
    bree::CreateWorkspaceOptions create;
    create.name = name;
    create.initial_content = bree::InitialContent::empty;
    auto created = take(current_session.create_workspace(
        std::move(create),
        take(bree::MutationOptions::with_key("live-create"))));
    const auto workspace_id = std::visit(
        [](const auto& value) { return value.workspace_id; },
        created.value);
    auto target = client.workspace(workspace_id);
    const auto renamed_result = take(target.rename(
        name + "-renamed",
        take(bree::MutationOptions::with_key("live-rename"))));
    const auto renamed = renamed_result.value.name == name + "-renamed";
    const auto listed_workspaces = take(current_session.workspaces());
    const auto listed = std::ranges::any_of(
        listed_workspaces,
        [&workspace_id](const auto& item) {
            return item.id == workspace_id;
        });
    static_cast<void>(take(target.close(
        take(bree::MutationOptions::with_key("live-close")))));
    const auto remaining = take(current_session.workspaces());
    const auto disappeared = std::ranges::none_of(
        remaining,
        [&workspace_id](const auto& item) {
            return item.id == workspace_id;
        });

    return bree::Json(bree::Json::Object{
        {"pinged", bree::Json(pinged)},
        {"created", bree::Json(true)},
        {"renamed", bree::Json(renamed)},
        {"listed", bree::Json(listed)},
        {"closed", bree::Json(true)},
        {"disappeared", bree::Json(disappeared)},
    });
}

[[nodiscard]] bree::Json run(const bree::Json& request) {
    const auto operation = string_field(request, "op");
    if (operation == "read") {
        return run_read(request);
    }
    if (operation == "mutation-replay") {
        return run_mutation_replay(request);
    }
    if (operation == "mutation-error") {
        return run_mutation_error(request);
    }
    if (operation == "creation-resolve") {
        return run_creation_resolve(request);
    }
    if (operation == "creation-conflict") {
        return run_creation_conflict(request);
    }
    if (operation == "terminal-wait-exit") {
        return run_terminal_wait_exit(request);
    }
    if (operation == "stream-unknown") {
        return run_stream_unknown(request);
    }
    if (operation == "stream-cancel") {
        return run_stream_cancel(request);
    }
    if (operation == "stream-overflow") {
        return run_stream_overflow(request);
    }
    if (operation == "redaction") {
        return run_redaction();
    }
    if (operation == "live-setup") {
        return run_live_setup(request);
    }
    if (operation == "live-creation-exit") {
        return run_live_creation_exit(request);
    }
    if (operation == "live-exit-restart") {
        return run_live_exit_restart(request);
    }
    if (operation == "live-restart") {
        return run_live_restart(request);
    }
    if (operation == "live-flow") {
        return run_live(request);
    }
    throw AdapterError("unknown adapter operation: " + operation);
}

[[nodiscard]] bree::Json success(
    std::string identifier,
    bree::Json value) {
    return bree::Json(bree::Json::Object{
        {"contract_version", bree::Json(std::uint64_t{2})},
        {"id", bree::Json(std::move(identifier))},
        {"ok", bree::Json(true)},
        {"value", std::move(value)},
    });
}

[[nodiscard]] bree::Json failure(
    std::string identifier,
    std::string message) {
    return bree::Json(bree::Json::Object{
        {"contract_version", bree::Json(std::uint64_t{2})},
        {"id", bree::Json(std::move(identifier))},
        {"ok", bree::Json(false)},
        {"error",
         bree::Json(bree::Json::Object{
             {"kind", bree::Json("adapter")},
             {"message", bree::Json(std::move(message))},
         })},
    });
}

}  // namespace

int main() {
    std::string input;
    std::getline(std::cin, input);
    std::string identifier;
    bree::Json response;
    try {
        const auto request = take(bree::Json::parse(input));
        identifier = string_field(request, "id");
        response = success(identifier, run(request));
    } catch (const std::exception& error) {
        response = failure(identifier, error.what());
    }
    auto encoded = response.encode();
    if (!encoded) {
        std::cerr << describe(encoded.error()) << '\n';
        return 1;
    }
    std::cout << encoded.value() << '\n';
    return 0;
}
